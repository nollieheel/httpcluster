-module(httpcluster_sec).
-behaviour(gen_server).

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").

%% API
-export([
    start_link/1
%    set_role_sec/1,
%    set_role_disc/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    % this_node :: Name of this node.
    % nodes     :: All member nodes of the cluster.
    this_node      :: 'undefined' | mnode_name(),
    nodes     = [] :: [mnode()],

    % prim      :: Name of node being currently treated as primary.
    % prim_exs  :: Nodes exempted from being primary.
    prim           :: 'undefined' | mnode_name(),
    prim_exs  = [] :: [{mnode_name(), ttd_type()}],

    % evts      :: Events that have been applied to the network (history list).
    % evts_wait :: Raw events on wait-list (not applied yet).
    evts      = [] :: [evt()],
    evts_wait = [] :: [evt_raw()],

    % pinger    :: Ref of timer that triggers the ping procedures.
    % ping_wait :: Number of times nodes have been pinged without reply yet.
    %              Should only contain 1 element (1 attempt) if ping attempts
    %              (to the primary node) are being continuously replied to.
    pinger         :: 'undefined' | reference(),
    ping_wait = [] :: [{mnode_name(), integer()}]
}).
-type state() :: #state{}.

-define(SERVER, ?MODULE).

%NOTES:
% on init, create a sec_msg, but bypass evts_wait: ping immediately.

% TODO IMPORTANT TODO: another module should do cluster init...: httpcluster_init,
%which can then streamline the init process. The results will then be plugged into this module.

%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Opts]) ->
    {ok, #state{}}.

handle_call('wipe_state', _From, _S) ->
    {reply, ok, #state{}};

%% Res :: {ok, prim_res()} | {'redir', mnode()} | {error, any()}
handle_call({'ping_reply', {_DestNode, _Res}=Reply}, From, S) ->
    gen_server:reply(From, ok),
    {Bool, #state{this_node=Na, nodes=Ns}=S1} = handle_ping_reply(Reply, S),
    Ref1 = case Bool of
        true  -> ping_later(httpcluster:get_node(Na, Ns));
        false -> 'undefined'
    end,
    {noreply, S1#state{pinger = Ref1}};

handle_call(_Msg, _From, State) ->
    {reply, 'undefined', State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'$routine_ping', R}, #state{this_node='undefined', pinger=R}=S) ->
    lager:info("Abort routine ping: this node undefined."),
    {noreply, S#state{pinger = 'undefined'}};

handle_info({'$routine_ping', R}, #state{prim='undefined', pinger=R}=S) ->
    lager:info("Abort routine ping: primary node undefined."),
    {noreply, S#state{pinger = 'undefined'}};

handle_info({'$routine_ping', R}, #state{pinger=R}=S) ->
    {Res, #state{this_node=Na, nodes=Ns}=S1} = ping_primary_node(S),
    Ref1 = case Res of
        ok ->
            lager:debug("Routine ping attempt ok."),
            'undefined';
        {error, _}=Err ->
            lager:warn("Skip routine ping attempt: ~p", [Err]),
            ping_later(httpcluster:get_node(Na, Ns))
    end,
    {noreply, S1#state{pinger = Ref1}};

handle_info({'$routine_ping', _}, S) ->
    {noreply, S#state{pinger = 'undefined'}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% -----------------
-spec ping_later(mnode()) -> reference().
%% Schedule a routine later according to node's ping value.
ping_later(#mnode{ping=Seconds}) ->
    Ref = make_ref(),
    erlang:send_after(Seconds * 1000, self(), {'$routine_ping', Ref}),
    Ref.

ping_primary_node(#state{prim=PrimName, nodes=Nodes}=State) -> 
    ping_remote_node(PrimName, Nodes, State).

%% -----------------
-spec ping_remote_node(mnode_name(), [mnode()], state()) -> 
    {ok | {error, 'origin_node_down' | 'dest_node_undefined'}, state()}.
%% Use the client comms module to ping a destination node.
%% Use the current evts and evts_wait lists in composing the ping message. 
%% Origin node can only be this node.
%%
%% Must not wait for a reply, but instead, return immediately.
ping_remote_node(
    ToName,
    Nodes,
    #state{
        this_node=FromName, evts=Evts, 
        evts_wait=Raws, ping_wait=Pwait
    }=State
) ->
    case get_from_and_to_nodes(FromName, ToName, Nodes) of
        {FromNode, ToNode, OtherNodes} ->
            Pwait1 = incr_ping_wait(ToName, Pwait),
            LastEvtTime = get_last_evttime(Evts),
            ping_remote_node(FromNode, ToNode, OtherNodes, Raws, LastEvtTime),
            {ok, State#state{ping_wait = Pwait1}};
        {error, _}=Err ->
            {Err, State}
    end.

ping_remote_node(FromNode, ToNode, OtherNodes, Raws, LastEvtTime) ->
    Mod = httpcluster:get_app_var(?MOD_COMS),
    Msg = new_sec_msg(FromNode, Raws, LastEvtTime, false),
    Mod:?HANDLER_PING_TO_NODE(
        Mod:?HANDLER_CREATE_PINGDATA(Msg, FromNode, OtherNodes), 
        FromNode, 
        ToNode
    ).

get_from_and_to_nodes(From, To, Nodes) ->
    case httpcluster:take_node(From, Nodes) of
        {#mnode{con=true}=FromNode, OtherNodes} ->
            case httpcluster:get_node(To, Nodes) of
                #mnode{}=ToNode ->
                    {FromNode, ToNode, OtherNodes};
                'undefined' ->
                    {error, 'dest_node_undefined'}
            end;
        {#mnode{con=false}, _} ->
            {error, 'origin_node_down'}
    end.

get_last_evttime([])               -> 0;
get_last_evttime([#evt{time=T}|_]) -> T.

new_sec_msg(#mnode{name=From}, Raws, LastEvtTime, GetNodes) ->
    #sec_msg{
        from      = From,
        raws      = Raws,
        last_evt  = LastEvtTime,
        get_nodes = GetNodes
    }.

incr_ping_wait(NodeName, PingWait) ->
    case lists:keytake(NodeName, 1, PingWait) of
        {'value', {_, N}, PingWait1} -> [{NodeName, N + 1}|PingWait1];
        false                        -> [{NodeName, 1}|PingWait]
    end.

decr_ping_wait(NodeName, PingWait) ->
    case lists:keytake(NodeName, 1, PingWait) of
        {'value', {_, 1}, PingWait1} -> 
            PingWait1;
        {'value', {_, N}, PingWait1} when N > 1 -> 
            [{NodeName, N - 1}|PingWait1];
        false -> 
            PingWait
    end.

%% -----------------
-spec handle_ping_reply(tuple(), state()) -> {boolean(), state()}.
%% Handles the ping replies from client coms module. 
%%
%% This function handles immediately attempting ping redirects if valid, 
%% triggering ttd timers on attempt/response errors, and ultimately calling
%% fun handle_prim_res/2 on successful ping responses.
%%
%% Also returns a boolean for whether to schedule another routine ping or not.
handle_ping_reply({#mnode{name=Name}, _}=Reply, State) ->
    case handle_ping_reply_2(Reply, State) of
        {_Bool, _State1}=Return -> 
            Return;
        {true, {TTD, Type, Details}, State1} -> 
            httpcluster_timer:start(Name, TTD, Type, Details),
            {true, State1}
    end.

-spec handle_ping_reply_2
    ({mnode(), {ok, prim_res()}}, state()) -> 
        {true, state()};
    ({mnode(), {'redir', mnode()}}, state()) -> 
        {boolean, state()} | {true, {_,_,_}, state()};
    ({mnode(), {error, any()}}, state()) ->
        {true, {_,_,_}, state()}.
%% An {ok, prim_res()} reply.
handle_ping_reply_2(
    {#mnode{name=Dname}, {ok, PrimRes}}, 
    #state{ping_wait=Pwait}=State
) -> 
    {_, State1} = handle_prim_res(
        PrimRes, 
        State#state{ping_wait = decr_ping_wait(Dname, Pwait)}
    ),
    {true, State1};

%% A {'redir', mnode()} reply.
handle_ping_reply_2(
    {#mnode{name=Dname}=DNode, {'redir', #mnode{name=Rname}=RNode}}, 
    #state{ping_wait=Pwait, nodes=Nodes}=State
) ->
    case decr_ping_wait(Dname, Pwait) of
        [] ->
            lager:debug("Ping redirected to node: ~p", [RNode]),
            case ping_remote_node(
                Rname, 
                lists:keystore(Rname, #mnode.name, Nodes, RNode), 
                State#state{ping_wait = []}
            ) of
                {ok, State1} ->
                    lager:debug("Redirect ping attempt ok."),
                    {false, State1};
                {{error, _}=Err, State1} ->
                    lager:debug("Skip redirect ping attempt: ~p", [Err]),
                    {true, State1}
            end;
        Pwait1 -> 
            {
                true, 
                {DNode#mnode.ttd, ?TTD_PRIM_REDIR, DNode}, 
                State#state{ping_wait = Pwait1}
            }
    end;

%% An {error, any()} reply.
handle_ping_reply_2(
    {#mnode{name=Dname}=DNode, {error, Error}},
    #state{ping_wait=Pwait}=State
) ->
    {Type, Details, Pwait1} = case decr_ping_wait(Dname, Pwait) of
        []     -> {?TTD_PRIM_DISC, Error, []};
        Pwaitx -> {?TTD_PRIM_REDIR, DNode, Pwaitx}
    end,
    {
        true, 
        {DNode#mnode.ttd, Type, Details}, 
        State#state{ping_wait = Pwait1}
    }.

%% -----------------
-spec handle_prim_res(prim_res(), state()) -> 
    {ok | {error, 'does_not_match'}, state()}.
%% A prim_res() is a ping response coming from the primary node. It contains
%% recent cluster changes that should be applied by the secondary node to its
%% own cluster record.
%%
%% This function takes care of that application, along with triggering the
%% proper role changes, and broadcasting the events over to 3rd party 
%% client processes if they subscribed to httpcluster.
handle_prim_res(
    #prim_res{nodes=ResNodes, evts=ResEvts}=Res, 
    #state{nodes=Nodes}=State
) ->
    case Res#prim_res.to == State#state.this_node of
        true ->
            lager:debug("Begin processing #prim_res{}."),
            State1 = State#state{nodes = assume_nodes_list(ResNodes, Nodes)},
            {ok, handle_res_evts(ResEvts, State1)};
        false ->
            lager:warn("#prim_res{} does not match this_node: ~p", [Res]),
            {{error, 'does_not_match'}, State}
    end.

%% Use the nodes list that came along with prim_res() if it is not undefined.
assume_nodes_list('undefined', StateNodes) ->
    StateNodes;
assume_nodes_list(ResNodes, _) ->
    lager:info("Assuming new nodes list from #prim_res{}"),
    ResNodes.

handle_res_evts(ResEvts, State) ->
    lists:foldr(
        fun
            (#evt{}=Evt, State1)     -> handle_evt(Evt, State1);
            (#evt_err{}=Err, State1) -> handle_evt_err(Err, State1)
        end,
        State, 
        ResEvts
    ).

-spec handle_evt_err(evt_err(), state()) -> state().
%% Can do nothing on evt errors, except to just log them.
handle_evt_err(
    #evt_err{id=Id, type=Ty, time=Ti, reason=Re}, 
    #state{evts_wait=Raws}=State
) ->
    case lists:keytake(Id, #evt_raw.id, Raws) of
        {'value', #evt_raw{node=No}, OtherRaws} ->
            St = "{id=~p, type=~p, time=~p, reason=~p, node=~p}",
            lager:error("Evt error: " ++ St, [Id, Ty, Ti, Re, No]),
            State#state{evts_wait = OtherRaws};
        false ->
            St = "{id=~p, type=~p, time=~p, reason=~p}",
            lager:warn("Unknown evt error: " ++ St, [Id, Ty, Ti, Re]),
            State
    end.

-spec handle_evt(evt(), state()) -> state().
%% Assimilate evt into state variables, refresh this node's role,
%% and broadcast to subscriber/client processes about the new cluster evt.
handle_evt(
    Evt, 
    #state{this_node=ThisName, prim=OldPrim, nodes=OldNodes}=State
) ->
    #state{prim=NewPrim, nodes=NewNodes}=State1 = update_state_vars(Evt, State),
    trigger_role(ThisName, NewPrim, NewNodes),
    httpcluster_subs:broadcast(Evt, {OldPrim, NewPrim, OldNodes}),
    %TODO require: client-provided process can intercept this procedure
    %TODO this should be a CAST on httpcluster_subs, too.
    State1.

update_state_vars(
    Evt,
    #state{
        this_node=ThisName, nodes=Nodes, evts=Hist, 
        prim_exs=PrimEx, evts_wait=Raws
    }=State
) ->
    Raws1 = update_raws(Evt, Raws),
    Nodes1 = httpcluster:apply_evt_to_nodes(Evt, Nodes),
    Hist1 = httpcluster:apply_evt_to_hist(Evt, Hist),
    Prim1 = refresh_prim(ThisName, Nodes1, PrimEx),
    State#state{nodes = Nodes1, evts = Hist1, prim = Prim1, evts_wait = Raws1}.

update_raws(#evt{id=Id, type=Ty, time=Ti, org_name=Na, node=No}, Raws) ->
    St = "{id=~p, type=~p, time=~p, org_name=~p, node=~p}",
    {St1, Raws1} = case lists:keytake(Id, #evt_raw.id, Raws) of
        {'value', #evt_raw{}, OtherRaws} ->
            {"Applying cluster evt from this node: ", OtherRaws};
        false ->
            {"Applying cluster evt: ", Raws}
    end,
    lager:info(St1 ++ St, [Id, Ty, Ti, Na, No]),
    Raws1.

%% Recalculate primary node.
refresh_prim(ThisName, Nodes, PrimEx) ->
    case httpcluster:get_node(ThisName, Nodes) of
        #mnode{con=true}  ->
            #mnode{name=Prim} = do_refresh_prim('undefined', Nodes, PrimEx),
            Prim;
        #mnode{con=false} ->
            'undefined'
    end.

do_refresh_prim(Prim, [], _Ex) ->
    Prim;
do_refresh_prim(Prim, [#mnode{con=false}|L], Ex) ->
    do_refresh_prim(Prim, L, Ex);
do_refresh_prim('undefined', [Node|L], Ex) ->
    do_refresh_prim(new_if_not_ex('undefined', Node, Ex), L, Ex);
do_refresh_prim(#mnode{prio=P}=Prim, [#mnode{prio=N}|L], Ex) when N > P ->
    do_refresh_prim(Prim, L, Ex);
do_refresh_prim(#mnode{prio=P}=Prim, [#mnode{prio=N}=Node|L], Ex) when N < P ->
    do_refresh_prim(new_if_not_ex(Prim, Node, Ex), L, Ex);
do_refresh_prim(#mnode{rank=P}=Prim, [#mnode{rank=N}|L], Ex) when N > P ->
    do_refresh_prim(Prim, L, Ex);
do_refresh_prim(#mnode{rank=P}=Prim, [#mnode{rank=N}=Node|L], Ex) when N < P ->
    do_refresh_prim(new_if_not_ex(Prim, Node, Ex), L, Ex).

new_if_not_ex(Old, New, PrimEx) ->
    case lists:keymember(New#mnode.name, 1, PrimEx) of
        true  -> Old;
        false -> New
    end.

% placeholder function
trigger_role(_ThisName, _PrimName, _Nodes) ->
    %TODO procedures here must be idempotent.
    ok.

