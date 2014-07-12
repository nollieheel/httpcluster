-module(httpcluster_ping).
-behaviour(gen_server).

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").

%% API
-export([
    start_link/1, 
    set_role_sec/1,
    set_role_disc/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    role = ?ROLE_DISC :: node_role(),
    ping_ref          :: 'undefined' | reference()
}).

-define(SERVER, ?MODULE).


%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).


-spec set_role_sec(integer()) -> {ok, 'already_set' | node_role()}.
%% @doc Turn on regular ping actions as secondary node role. The argument
%%      is this node's ping time value in seconds.
%%      Returns the old role upon success.
set_role_sec(Ping) ->
    gen_server:call(?SERVER, {'set_role_sec', Ping}).


-spec set_role_disc() -> {ok, 'already_set' | node_role()}.
%% @doc Turns off all ping routine tasks.
set_role_disc() ->
    gen_server:call(?SERVER, 'set_role_disc').


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Opts]) ->
    {ok, #state{}}.

handle_call({'set_role_sec', Seconds}, _From, 
            #state{role=Role, ping_ref=Ref}=S) ->
    {Reply, Role1, Ref1} = case {Role, Ref} of
        {?ROLE_SEC, 'undefined'} -> {Role, Role, ping_later(Seconds)};
        {?ROLE_SEC, _Ref}        -> {'already_set', Role, Ref};
        {_Role, 'undefined'}     -> {Role, ?ROLE_SEC, ping_later(Seconds)};
        {_Role, _Ref}            -> {Role, ?ROLE_SEC, Ref}
    end,
    {reply, {ok, Reply}, S#state{role = Role1, ping_ref = Ref1}};

handle_call('set_role_disc', _From, #state{role=Role}=S) ->
    Reply = case Role of
        ?ROLE_DISC -> 'already_set';
        _          -> Role
    end,
    {reply, {ok, Reply}, S#state{role = ?ROLE_DISC}};

handle_call(_Msg, _From, State) ->
    {reply, 'undefined', State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'$sec_ping', Ref}, #state{ping_ref=Ref, role=?ROLE_SEC}=S) ->
    Seconds = ping_primary(),
    {noreply, S#state{ping_ref = ping_later(Seconds)}};

handle_info({'$sec_ping', Ref}, #state{ping_ref=Ref}=State) ->
    {noreply, State#state{ping_ref = 'undefined'}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Internal functions
%%====================================================================

%% === Utility funs ====

%prop_val(Prop, Ls) ->
%    case lists:keyfind(Prop, 1, Ls) of
%        {_, Val} -> Val;
%        false    -> 'undefined'
%    end.





%% === Ping routine for secondary node role ====

-spec ping_later(integer()) -> reference().
ping_later(Seconds) ->
    Seconds1 = case Seconds of
        0 -> httpcluster:get_app_var(?DEF_PING, ?DEF_DEF_PING);
        _ -> Seconds
    end,
    Ref = make_ref(),
    erlang:send_after(Seconds1 * 1000, self(), {'$sec_ping', Ref}),
    Ref.

-spec ping_primary() -> integer().
%% Ping the primary node. Tolerate all errors.
ping_primary() ->
    Res = {_, _, Ping} = do_ping_primary(),
    case Res of
        {ok, Evts, _} ->
            httpcluster:new_evts(Evts);
        {error, {Mname, TTD, Type, Details}, _} ->
            httpcluster_timer:start(Mname, TTD, Type, Details);
        {error, _, _} ->
            ok
    end,
    Ping.

do_ping_primary() ->
    case httpcluster:get_sec_ping_details() of
        {ok, {ThisNode, PrimNode, _}}
            when (ThisNode =:= 'undefined')
            or (PrimNode =:= 'undefined') -> 
            lager:warning("Secondary node ping details not defined"),
            {error, 'node_undefined', 0};
        {ok, {#mnode{ping=Ping}=ThisNode, 
              #mnode{mname=Prim}=PrimNode, LastRef}} ->
            try ping2node(ThisNode, PrimNode, LastRef) of
                {ok, {Evts, #mnode{mname=Prim}}} ->
                    {ok, Evts, Ping};
                {ok, {Evts, Node}} -> 
                    lager:warning("Ping redirected to ~p", [Node]),
                    {ok, Evts, Ping};
                {error, {TTD, Type, Details}} -> 
                    {error, {Prim, TTD, Type, Details}, Ping}
            catch Class:Error ->
                Trace = erlang:get_stacktrace(),
                lager:error("Error when pinging node:~n~p", [Trace]),
                {error, {Class, Error}, 0}
            end
    end.

-spec ping2node(mnode(), mnode(), evt_ref() | 'undefined') ->
    {ok, {[evt()], mnode()}} | {error, {integer(), ttd_type(), term()}}.
%% Try to ping a primary node (ToNode).
%%
%% On success, return the event list and the node that replied success.
%% This is usually, but not always, the ToNode.
%%
%% The error returned contains details for the ttd timer to be triggered.
%% Said timer will always refer to ToNode.
ping2node(ThisNode, ToNode, LastHistRef) ->
    Proplist = [
        {"last_ref", LastHistRef},
        {"node", httpcluster:mnode2proplist(ThisNode)}
    ],
    Data = mochijson2:encode(
        httpcluster:apply_handler_fun(
            ?HANDLER_CREATE_PINGDATA,
            [ThisNode, Proplist]
        )
    ),
    ping2node_seq(ThisNode, ToNode, Data, false).

-spec ping2node_seq(mnode(), mnode(), term(), boolean()) ->
    {ok, {[evt()], mnode()}} | {error, {integer(), ttd_type(), term()}}.
ping2node_seq(ThisNode, ToNode, Data, IsRedir) ->
    case httpcluster:apply_handler_fun(
        ?HANDLER_PING_TO_NODE,
        [ThisNode, ToNode, Data]
    ) of
        {ok, Bin} ->
            case httpcluster:apply_handler_fun(
                ?HANDLER_TRANSLATE_PING_REPLY,
                [ThisNode, mochijson2:decode(Bin)]
            ) of
                {ok, Evts} ->
                    {ok, {Evts, ToNode}};
                {'redir', _ReNode} when IsRedir->
                    {error, {ToNode#mnode.ttd, ?TTD_PRIM_REDIR, ToNode}};
                {'redir', ReNode} ->
                    ping2node_seq(ThisNode, ReNode, Data, true);
                {error, _Error} when IsRedir->
                    {error, {ToNode#mnode.ttd, ?TTD_PRIM_REDIR, ToNode}};
                {error, Error} ->
                    {error, {ToNode#mnode.ttd, ?TTD_PRIM_DISC, Error}}
            end;
        {error, _Error} when IsRedir ->
            {error, {ToNode#mnode.ttd, ?TTD_PRIM_REDIR, ToNode}};
        {error, Error} ->
            {error, {ToNode#mnode.ttd, ?TTD_PRIM_DISC, Error}}
    end.








