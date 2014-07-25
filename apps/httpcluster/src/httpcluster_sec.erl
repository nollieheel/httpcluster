%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc The main module handling secondary-node functions.
%%%      This is the entry point into the application. It is also
%%%      where the function {@link httpcluster:activate/3} is automatically
%%%      called whenever this node switches to primary role.

-module(httpcluster_sec).
-behaviour(gen_fsm).

-include("httpcluster_int.hrl").
-include("../include/httpcluster.hrl").

%% API
-export([
    start_link/1,
    init_cluster/3,
    ping_reply/2,
    pong_cast/1,
    evt_raw/1,
    is_connected/0
]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% gen_fsm internal states
-export([
    'connected_idle'/3,
    'connected_pinging'/3,
    'connected_retrying'/3,
    'connected_stalled'/3,
    'disconnected'/3,
    'initializing'/3
]).

%% Module internal
-export([
    'apply_ping_funs'/3
]).

-define(SERVER, ?MODULE).
-define(ROLE_PRIM, 'primary').
-define(ROLE_SEC,  'secondary').
-define(ROLE_DISC, 'disconnected').

%%====================================================================
%% Types
%%====================================================================

-type evts_list() :: [hc_evt:evt() | hc_evt:evt_err()].

-record(ping_arg, {
    ref       :: reference(),
    type      :: ?PING_ROUTINE | ?PING_RETRY | ?PING_SYNC,
    node_ping :: hc_evt:node_ping()
}).
-type ping_arg() :: #ping_arg{}.

-record(sd, {
    this_name :: 'undefined' | hc_node:name(),
    this_ping :: 'undefined' | pos_integer(),
    % this_name :: Name of this node.
    % this_ping :: This node's ping frequency in milliseconds. Cannot be zero.

    prim          :: 'undefined' | hc_node:name(),
    prim_exs = [] :: [{hc_node:name(), term()}],
    % prim     :: Name of node being currently treated as primary.
    % prim_exs :: Nodes exempted from being primary.

    nodes          :: hc_node:cnodes(),
    evts      = [] :: evts_list(),
    evts_wait = [] :: evts_list(),
    evt_raws  = [] :: [hc_evt:evt_raw()],
    % nodes     :: All member nodes of the cluster, including this node.
    % evts      :: Events that have been applied to history list.
    % evts_wait :: Events waiting to be applied to history list.
    % evt_raws  :: Raw events that have not been forwarded to the primary yet.

    timers             :: hc_timer:timers(),
    ping_timer         :: 'undefined' | hc_timer:timer(),
    ping_attempts = [] :: [ping_arg()]
    % timers        :: Active timers for non-responding primary nodes.
    % ping_timer    :: Timer that triggers the routine/retry ping procedures.
    % ping_attempts :: Most recent, unresolved ping attempts.
}).
-type sd() :: #sd{}.

%%====================================================================
%% API
%%====================================================================

%% @private
start_link(Opts) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [Opts], []).

%% @doc Try to connect to the cluster using the given nodes/hosts list. 
%%
%%      `ThisName' is the designated name of this node. Its details must
%%      also be present in the given nodes list.
%%
%%      `Ping' is the time (in milliseconds) to wait before each heartbeat
%%      ping is made to the primary node.
%%
%%      This function returns immediately, but establishing cluster
%%      connection might take a while.
-spec init_cluster(ThisName, ThisPing, Nodes) -> ok | {error, Error}
    when
        ThisName :: hc_node:name(),
        ThisPing :: pos_integer(),
        Nodes    :: hc_node:cnodes(),
        Error    :: any().
init_cluster(ThisName, ThisPing, Nodes) ->
    Tuple = {'init_cluster', ThisName, ThisPing, Nodes},
    gen_fsm:sync_send_all_state_event(?SERVER, Tuple).

%% @doc Used by client comm module to send ping replies back to httpcluster.
-spec ping_reply(PingRef, PingReply) -> ok | {error, Error}
    when 
        PingRef   :: reference(),
        PingReply :: Reply | {error, Err} | Err,
        Reply     :: hc_evt:node_pong() | hc_evt:node_reply(),
        Err       :: any(),
        Error     :: any().
ping_reply(PingRef, PingReply) ->
    gen_fsm:sync_send_event(?SERVER, {'ping_reply', PingRef, PingReply}).

%% @doc Used by client comm module to send cluster casts to httpcluster.
-spec pong_cast(NodePong) -> ok | {error, Error}
    when NodePong :: hc_evt:node_pong(), Error:: any().
pong_cast(NodePong) ->
    gen_fsm:sync_send_all_state_event(?SERVER, {'pong_cast', NodePong}).

%% @doc Manually send a raw event to the cluster. The event <em>must</em> be
%%      about this node. It may take some time before the event propagates.
-spec evt_raw(Raw) -> ok | {error, Error}
    when Raw :: hc_evt:evt_raw(), Error :: any().
evt_raw(Raw) ->
    gen_fsm:sync_send_all_state_event(?SERVER, {'evt_raw', Raw}).

%% @doc Check if currently connected to the cluster or not.
-spec is_connected() -> boolean().
is_connected() ->
    gen_fsm:sync_send_all_state_event(?SERVER, 'is_connected').

%%====================================================================
%% gen_fsm callbacks and internal states
%%====================================================================

%% @private
init([_Opts]) ->
    process_flag('trap_exit', true),
    {ok, 'disconnected', #sd{
        nodes  = hc_node:empty(),
        timers = hc_timer:empty()
    }}.

%% @private
%% Doing nothing; waiting for a scheduled ping timeout,
%% or a new event request from user.
'connected_idle'({'ping_reply', _,_}, _From, Sd) ->
    {reply, {error, 'not_pinging'}, 'connected_idle', Sd};

'connected_idle'(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, 'connected_idle', Sd}.

%% @private
%% Ping attempt ok, waiting for the ping reply/result.
'connected_pinging'({'ping_reply', PingRef, Reply}, From, Sd) ->
    case lists:keyfind(PingRef, #ping_arg.ref, Sd#sd.ping_attempts) of
        #ping_arg{}=PingArg ->
            {Next, Sd1} = handle_defined_ping_reply(
                PingRef, PingArg, Reply, From, Sd
            ),
            {next_state, Next, Sd1};
        false ->
            {reply, {error, 'ping_ref_undefined'}, 'connected_pinging', Sd}
    end;

'connected_pinging'(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, 'connected_pinging', Sd}.

%% @private
%% Previous ping needs a retry: waiting a moment before doing it
%% (technically waiting for the retry timer timeout).
'connected_retrying'({'ping_reply', _,_}, _From, Sd) ->
    {reply, {error, 'not_pinging'}, 'connected_retrying', Sd};

'connected_retrying'(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, 'connected_retrying', Sd}.

%% @private
%% Hard-transitioning to a new primary node. Waiting for acknowledgement.
'connected_stalled'({'ping_reply', PingRef, Reply}, From, Sd) ->
    case lists:keyfind(PingRef, #ping_arg.ref, Sd#sd.ping_attempts) of
        #ping_arg{}=PingArg ->
            {Next, Sd1} = handle_defined_ping_reply(
                PingRef, PingArg, Reply, From, Sd
            ),
            {next_state, Next, Sd1};
        false ->
            {reply, {error, 'ping_ref_undefined'}, 'connected_stalled', Sd}
    end;

'connected_stalled'(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, 'connected_stalled', Sd}.

%% @private
'disconnected'({'ping_reply', Pref, _}, _From, #sd{ping_attempts=Pargs}=Sd) ->
    Sd1 = Sd#sd{ping_attempts = del_parg(Pref, Pargs)},
    {reply, {error, 'disconnected'}, 'disconnected', Sd1};

'disconnected'(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, 'disconnected', Sd}.

%% @private
%% Attempting to connect to the httpcluster (syncing).
'initializing'(
    {'ping_reply', PingRef, Reply}, From, Sd
) ->
    case lists:keyfind(PingRef, #ping_arg.ref, Sd#sd.ping_attempts) of
        #ping_arg{}=Parg ->
            ?log_debug("Sync ping reply received for PingRef: ~p", [PingRef]),
            % Sync pings accept at most one redirect.
            {Next, Sd1} = case filter_sync_reply(Reply, Parg, Sd, 1) of
                {ok, NodePong} ->
                    gen_fsm:reply(From, ok),
                    next_on_nodepong_response(NodePong, Sd);
                {'redir', Rnode} ->
                    gen_fsm:reply(From, ok),
                    go_init_auto(
                        hc_evt:node_com_destination(Parg#ping_arg.node_ping), 
                        Sd#sd{nodes = hc_node:store_first(Rnode, Sd#sd.nodes)}
                    );
                {_, Error} ->
                    ?log_warning("Sync reply error: ~p", [Error]),
                    gen_fsm:reply(From, {error, Error}),
                    go_init_auto(Parg, Sd)
            end,
            {next_state, Next, Sd1};
        false ->
            {reply, {error, 'ping_ref_undefined'}, 'initializing', Sd}
    end;

'initializing'(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, 'initializing', Sd}.

%% @private
handle_sync_event({'init_cluster', ThisName, ThisPing, Nodes}, From, State, Sd)
    when State =:= 'disconnected' ->
    case hc_node:take_node(ThisName, Nodes) of
        {'undefined', _} ->
            {reply, {error, 'this_node_not_found'}, State, Sd};
        {ThisNode, OtherNodes} ->
            gen_fsm:reply(From, ok),
            random:seed(now()),
            Raw = hc_evt:new_raw(
                new_raw_name(?EVT_NODE_UP, ThisName), ?EVT_NODE_UP, ThisNode
            ),
            NewSd = #sd{
                this_name = ThisName,
                this_ping = ThisPing,
                nodes     = hc_node:store_last(ThisNode, OtherNodes),
                evt_raws  = [Raw],
                timers    = hc_timer:empty()
            },
            {Next, NewSd1} = go_init_auto(NewSd),
            {next_state, Next, NewSd1}
    end;

handle_sync_event({'init_cluster', _,_,_}, _From, State, Sd) ->
    Error = case State =:= 'initializing' of
        true  -> 'initializing';
        false -> 'already_connected'
    end,
    {reply, {error, Error}, State, Sd};

handle_sync_event({'evt_raw', Raw}, From, State, #sd{evt_raws=Raws}=Sd)
    when 
        State =:= 'connected_idle';
        State =:= 'connected_pinging';
        State =:= 'connected_retrying';
        State =:= 'connected_stalled' ->
    Raws1 = [Raw|Raws],
    case State =:= 'connected_idle' of
        true ->
            gen_fsm:reply(From, ok),
            {Next, Sd1} = go_con_auto('undefined', Sd#sd{evt_raws = Raws1}),
            {next_state, Next, Sd1};
        false ->
            {reply, ok, State, Sd#sd{evt_raws = Raws1}}
    end;

handle_sync_event({'evt_raw', _}, _From, State, Sd) ->
    {reply, {error, 'disconnected'}, State, Sd};

handle_sync_event(
    {'pong_cast', NodePong}, From, State, #sd{this_name=This, nodes=Nodes}=Sd
)
    when 
        State =:= 'connected_idle';
        State =:= 'connected_pinging';
        State =:= 'connected_retrying';
        State =:= 'connected_stalled' ->
    gen_fsm:reply(From, ok),
    ?log_debug("Pong cast received (while on state ~p): ~p", [State, NodePong]),
    % Pong casts will always be node_pong()s with defined evt() values.
    %
    % The node only receives casts when it is connected. 
    {Next, Sd1} = case validate_node_response(NodePong, This, Nodes) of
        {ok, true} when State =:= 'connected_stalled' ->
            next_on_nodepong_ack(NodePong, Sd);
        {ok, true} ->
            next_on_nodepong_cast(NodePong, State, Sd);
        {error, Error} ->
            ?log_error("Pong cast validation error: ~p", [Error]),
            {State, Sd}
    end,
    {next_state, Next, Sd1};

handle_sync_event({'pong_cast', _}, _From, State, Sd) ->
    {reply, {error, 'disconnected'}, State, Sd};

handle_sync_event('is_connected', _From, State, Sd) ->
    {reply, current_role(Sd) =/= ?ROLE_DISC, State, Sd};

handle_sync_event(_Msg, _From, State, Sd) ->
    {reply, {error, 'undefined'}, State, Sd}.

%% @private
handle_event(_Msg, State, Sd) ->
    {next_state, State, Sd}.

%% @private
handle_info({'$ttd_timeout', T1}, State, Sd)
    when
        State =:= 'connected_idle';
        State =:= 'connected_retrying';
        State =:= 'connected_pinging';
        State =:= 'connected_stalled' ->
    {Next, Sd1} = next_on_ttd_timeout(T1, State, Sd),
    {next_state, Next, Sd1};

handle_info(
    {'$ttd_timeout', T}, 'disconnected', #sd{timers=Ts, ping_timer=Pt}=Sd
) ->
    {_, Ts1} = hc_timer:del_if_exists(T, Ts),
    Pt1 = case hc_timer:is_equal(T, Pt) of
        true  -> 'undefined';
        false -> Pt
    end,
    {next_state, 'disconnected', Sd#sd{timers = Ts1, ping_timer = Pt1}};

handle_info({'EXIT', Pid, Reason}, State, Sd) ->
    case Reason of
        'normal'        -> ok;
        'shutdown'      -> ok;
        {'shutdown', _} -> ok;
        _               -> ?log_warning("Pid ~p terminated: ~p", [Pid, Reason])
    end,
    {next_state, State, Sd};

handle_info(_Info, State, Sd) ->
    {next_state, State, Sd}.

%% @private
terminate(_Reason, _State, _Sd) ->
    ok.

%% @private
code_change(_OldVsn, State, Sd, _Extra) ->
    {ok, State, Sd}.

%%====================================================================
%% Internal functions
%%====================================================================

%% Handler function helpers

handle_defined_ping_reply(PingRef, PingArg, Reply, From, Sd) ->
    ?log_debug("Ping reply received for PingRef: ~p", [PingRef]),
    % Regular ping doesn't accept redirects.
    case filter_ping_reply(Reply, PingArg, Sd) of
        {ok, NodePong} ->
            %
            % Response is cool.
            gen_fsm:reply(From, ok),
            next_on_nodepong_response(NodePong, Sd);
        {error, {_,_, Error}=Tuple} ->
            %
            % If needed, keep retrying. Otherwise, just stay on
            % connected_idle and respond only to new raws or a timeout.
            ?log_debug("Ping reply error: ~p", [Tuple]),
            gen_fsm:reply(From, {error, Error}),
            case handle_node_reply_error(Tuple, Sd) of
                {true, Sd2} ->
                    go_con_retry(PingRef, Sd2);
                {false, Sd2} ->
                    go_con_idle(Sd2#sd{ping_attempts = []})
            end;
        {ignore, Error} ->
            %
            % Just act as if the last ping attempt did not exist:
            % either do another routine ping, or retry a recent one.
            ?log_error("Ping reply validation error: ~p", [Error]),
            gen_fsm:reply(From, {error, Error}),
            Pargs1 = del_parg(PingArg, Sd#sd.ping_attempts),
            Sd2 = Sd#sd{ping_attempts = Pargs1},
            case {PingArg#ping_arg.type, Pargs1} of
                {?PING_ROUTINE, _} -> 
                    go_con_idle(Sd2);
                {?PING_RETRY, [PrevArg|_]}->
                    go_con_retry(PrevArg#ping_arg.ref, Sd2)
            end
    end.

next_on_nodepong_response(NodePong, Sd) ->
    next_on_nodepong(NodePong, Sd, [], true).

next_on_nodepong_cast(NodePong, State, #sd{ping_attempts=L}=Sd) ->
    case next_on_nodepong(NodePong, Sd, L, false) of
        #sd{}=Sd1 -> {State, Sd1};
        {_,_}=Res -> Res
    end.

next_on_nodepong_ack(NodePong, #sd{ping_attempts=L}=Sd) ->
    next_on_nodepong(NodePong, Sd, L, true).

next_on_nodepong(NodePong, Sd, Attempts, Switch) ->
    Sd1 = handle_node_pong(NodePong, Sd),
    % Contact with prim made, clear prim trackers
    Sd2 = Sd1#sd{
        prim_exs      = [],
        ping_attempts = Attempts,
        timers        = hc_timer:all_off(Sd1#sd.timers)
    },
    % Switch state based on role if needed
    case current_role(Sd2) of
        ?ROLE_PRIM when Switch -> go_con_auto('undefined', Sd2);
        ?ROLE_SEC  when Switch -> go_con_auto('undefined', Sd2);
        ?ROLE_DISC             -> go_disc(Sd2);
        _      when not Switch -> Sd2
    end.

current_role(#sd{prim='undefined'})          -> ?ROLE_DISC;
current_role(#sd{this_name=This, prim=This}) -> ?ROLE_PRIM;
current_role(#sd{})                          -> ?ROLE_SEC.

next_on_ttd_timeout(T1, State, #sd{timers=Ts}=Sd) ->
    case hc_timer:del_if_exists(T1, Ts) of
        {true, Ts1} ->
            next_on_prim_timeout(
                hc_timer:ident(T1), hc_timer:details(T1), 
                Sd#sd{timers = Ts1}, "Contact TTD"
            );
        {false, _} ->
            next_on_ttd_timeout_2(T1, State, Sd)
    end.

next_on_ttd_timeout_2(T1, State, #sd{prim=Prim, ping_timer=Pt}=Sd) ->
    case hc_timer:is_equal(T1, Pt) of
        true when State =:= 'connected_idle'; 
                  State =:= 'connected_retrying'->
            go_con_auto(T1, Sd);
        true when State =:= 'connected_stalled' ->
            next_on_prim_timeout(Prim, 'transition_timeout', Sd, "Transition");
        false ->
            {State, Sd}
    end.

next_on_prim_timeout(Name, Details, Sd, Str) ->
    #sd{prim=Prim1} = Sd1 = handle_prim_timeout(Name, Details, Sd),
    ?log_info(
        Str ++ " timeout for primary node:~p. Switched to ~p", [Name, Prim1]
    ),
    case Prim1 of
        'undefined' -> go_disc(Sd1);
        _           -> go_stall(Name, Sd)
    end.
%% -----------------

%% Internal state switchers

%% If there is no timer given, try to ping if Raws is empty.
%% If there is a timer given, try to ping whether Raws is empty or not.
%% Give next appropriate gen_fsm state if successful.
go_con_auto('undefined', #sd{evt_raws=[]}=Sd) ->
    go_con_idle(Sd);
go_con_auto('undefined', #sd{evt_raws=[_|_]}=Sd) ->
    case handle_do_ping('undefined', Sd) of
        {ok, Sd1} ->
            ?log_debug("Ping attempt ok. Awaiting response."),
            {'connected_pinging', Sd1};
        {error, {Error, Sd1}} ->
            ?log_error("Error on ping attempt: ~p", [Error]),
            go_con_auto('undefined', Sd1)
    end;
go_con_auto(Timer, #sd{}=Sd) ->
    case handle_do_ping(Timer, Sd) of
        {ok, Sd1} ->
            ?log_debug("Scheduled ping attempt ok. Awaiting response."),
            {'connected_pinging', Sd1};
        {error, {Error, Sd1}} ->
            ?log_error("Error on scheduled ping attempt: ~p", [Error]),
            go_con_auto('undefined', Sd1)
    end.

%% No need to ping immediately. Just schedule next ping and go idle.
go_con_idle(#sd{this_ping=Time}=Sd) ->
    Timer = hc_timer:ping_routine_timer(make_ref(), Time),
    {'connected_idle', Sd#sd{ping_timer = Timer}}.

%% Schedule a ping retry and go retrying (do not act on any new ping requests).
go_con_retry(PingRef, Sd) ->
    Timer = hc_timer:ping_retry_timer(
        make_ref(), ?get_env(?PING_RETRY_TIME), PingRef
    ),
    {'connected_retrying', Sd#sd{ping_timer = Timer}}.

%% Go to stalling state for a while (do not act on any new ping requests).
go_stall(OldPrim, #sd{prim=NewPrim, nodes=Nodes}=Sd) ->
    Time = hc_node:ttd(OldPrim, Nodes) + hc_node:ttd(NewPrim, Nodes),
    Timer = hc_timer:ping_stall_timer(make_ref(), Time),
    {'connected_stalled', Sd#sd{ping_timer = Timer}}.

%% Clear all pending raw events and disconnect.
go_disc(#sd{}=Sd) ->
    {'disconnected', Sd#sd{evt_raws = []}}.

%% Begin/continue the cluster init cycle. 
%% The last element of the nodelist should be this node. If the sync
%% process reaches that, and this node's priority value is 0, then the
%% sync process fails and the state becomes disconnected.
go_init_auto(#ping_arg{node_ping=Ping}=Parg, #sd{ping_attempts=Pargs}=Sd) ->
    Name = hc_evt:node_com_destination(Ping),
    go_init_auto(Name, Sd#sd{ping_attempts = del_parg(Parg, Pargs)});
go_init_auto(Name, #sd{nodes=Nodes}=Sd) ->
    {_, Nodes1} = hc_node:take_node(Name, Nodes),
    go_init_auto(Sd#sd{nodes = Nodes1}).

go_init_auto(Sd) ->
    case handle_do_sync_ping(Sd) of
        {ok, {Node, Sd1}} ->
            ?log_debug(
                "Sync attempt ok on node ~p. Awaiting response.", [Node]
            ),
            {'initializing', Sd1};
        {error, 'nodelist_empty'} ->
            ?log_warning("Node list now empty. Cluster init stopped."),
            go_disc(Sd);
        {error, {Error, Node, Sd1}} ->
            ?log_error(
                "Error on sync attempt for node ~p: ~p", [Node, Error]
            ),
            go_init_auto(hc_node:name(Node), Sd1)
    end.

del_parg(#ping_arg{ref=Ref}, Pargs) -> 
    del_parg(Ref, Pargs);
del_parg(Ref, Pargs) ->
    lists:keydelete(Ref, #ping_arg.ref, Pargs).
%% -----------------

%% Check and validate the ping reply, and modify it accordingly. 
-spec filter_ping_reply(Data, PingArg, Sd) ->
    {ok, NodePong} | {error, tuple()} | {ignore, atom()}
    when 
        Data     :: Reply | {error, term()} | term(),
        Reply    :: hc_evt:node_pong() | hc_evt:node_reply(),
        PingArg  :: ping_arg(),
        Sd       :: sd(),
        NodePong :: hc_evt:node_pong().
filter_ping_reply(Data, Parg, Sd) ->
    ValFun = fun(D, S) -> 
        validate_node_response(D, S#sd.this_name, S#sd.nodes)
    end,
    filter_reply(Data, ValFun, Parg, Sd, 0).

%% Check and validate the sync reply, and modify it according 
%% to the current state of ping redirection.
-spec filter_sync_reply(Data, PingArg, Sd, Allowed) ->
    {ok, NodePong} | {'redir', Node} | {error, term()} | {ignore, atom()}
    when 
        Data     :: Reply | {error, term()} | term(),
        Reply    :: hc_evt:node_pong() | hc_evt:node_reply(),
        PingArg  :: ping_arg(),
        Sd       :: sd(),
        Allowed  :: non_neg_integer(),
        NodePong :: hc_evt:node_pong(),
        Node     :: hc_node:cnode().
filter_sync_reply(Data, Parg, Sd, Allowed) ->
    ValFun = fun(D, S) -> validate_sync_response(D, S#sd.this_name) end,
    filter_reply(Data, ValFun, Parg, Sd, Allowed).

filter_reply({error, Error}, _, Parg, Sd, _) ->
    Name = hc_evt:node_com_destination(Parg#ping_arg.node_ping),
    {error, {Name, hc_node:ttd(Name, Sd#sd.nodes), Error}};
filter_reply(Data, Validate, _, #sd{nodes=Nodes}=Sd, Allowed) ->
    case Validate(Data, Sd) of
        {ok, true} ->
            {ok, Data};
        {ok, false} ->
            RedirExceeded = length(Sd#sd.ping_attempts) > Allowed,
            case hc_evt:node_reply_val(Data) of
                {'redir', _Node}=Redir when not RedirExceeded ->
                    Redir;
                {'redir', _Node} when RedirExceeded ->
                    {error, tuple4timer(Data, Nodes, 'redir')};
                {error, Error} ->
                    {error, tuple4timer(Data, Nodes, Error)};
                Other ->
                    {error, tuple4timer(Data, Nodes, Other)}
            end;
        {error, Ignore} ->
            {ignore, Ignore}
    end.

tuple4timer(Data, Nodes, Error) ->
    Name = hc_evt:node_com_source(Data),
    {Name, hc_node:ttd(Name, Nodes), Error}.

%% Make sure a node_ping reply or node_pong cast is good, comes from 
%% a live node, and is meant for this node. Also indicate whether 
%% Com is a node_pong or not.
-spec validate_node_response(Com, ThisName, Nodes) -> 
    {ok, IsPong} | {error, Error}
    when
        Com      :: hc_evt:node_pong() | hc_evt:node_reply() | term(),
        ThisName :: hc_node:name(),
        Nodes    :: hc_node:cnodes(),
        IsPong   :: boolean(),
        Error    :: atom().
validate_node_response(Com, ThisName, Nodes) ->
    case validate_sync_response(Com, ThisName) of
        {ok, IsPong} ->
            From = hc_node:get_node(hc_evt:node_com_source(Com), Nodes),
            case hc_node:is_connected(From) of
                true  -> {ok, IsPong};
                false -> {error, 'source_node_down'}
            end;
        {error, _}=Error ->
            Error
    end.

%% Make sure a sync node_ping reply is good, and is meant for this node. 
%% Also indicate whether Com is a node_pong or not.
-spec validate_sync_response(Com, ThisName) -> 
    {ok, IsPong} | {error, Error}
    when
        Com      :: hc_evt:node_pong() | hc_evt:node_reply() | term(),
        ThisName :: hc_node:name(),
        IsPong   :: boolean(),
        Error    :: atom().
validate_sync_response(Com, ThisName) ->
    case hc_evt:is_node_pong(Com) of
        true ->
            validate_sync_response(Com, ThisName, true);
        false ->
            case hc_evt:is_node_reply(Com) of
                true  -> validate_sync_response(Com, ThisName, false);
                false -> {error, 'invalid_response'}
            end
    end.

validate_sync_response(Com, ThisName, IsPong) ->
    case hc_evt:node_com_destination(Com) =:= ThisName of
        true  -> {ok, IsPong};
        false -> {error, 'invalid_destination'}
    end.
%% -----------------

%% Does the things needed to be done if a proper node_pong() is received,
%% whether as a response to a node_ping(), or just a forward cast by the 
%% primary node. 
%%
%% This will update the following values in the internal state data:
%%   this_name
%%   prim
%%   nodes
%%   evts
%%   evts_wait
%%   evt_raws
-spec handle_node_pong(NodePong, Sd1) -> Sd2
    when
        NodePong :: hc_evt:node_pong(),
        Sd1      :: sd(),
        Sd2      :: sd().
handle_node_pong(Pong, Sd) ->
    {Nodes, Evts, EvtsWait} = update_if_sync(
        Pong, Sd#sd.nodes, Sd#sd.evts, Sd#sd.evts_wait
    ),
    do_handle_and_update(Pong, Nodes, Evts, EvtsWait, Sd).

update_if_sync(Pong, Nodes, Evts, EvtsWait) ->
    case hc_evt:node_pong_nodes(Pong) of
        'undefined' ->
            {Nodes, Evts, EvtsWait};
        NewNodes ->
            ?log_info("Syncing nodes list with primary, and clearing history."),
            {NewNodes, [], []}
    end.

do_handle_and_update(
    Pong, Nodes, Evts, EvtsWaitNew,
    #sd{
        this_name=ThisName, prim=PrimName, prim_exs=PrimExs,
        evts_wait=EvtsWaitOld, evt_raws=EvtRaws
    }=Sd
) ->
    case hc_evt:node_pong_evt(Pong) of
        'undefined' ->
            update_sd({Nodes, Evts, EvtsWaitNew}, Sd);
        Evt ->
            ?log_info("Processing incoming event: ~p", [Evt]),
            Sender = hc_evt:node_com_source(Pong),
            update_sd(
                store_and_process_evt(
                    {Sender, Evt}, ThisName, {PrimName, PrimExs}, 
                    Nodes, Evts, EvtsWaitOld, EvtRaws
                ),
                Sd
            )
    end.

update_sd({Nodes, Evts, EvtsWait}, Sd) ->
    Sd#sd{nodes = Nodes, evts = Evts, evts_wait = EvtsWait};
update_sd({ThisName, PrimName, Nodes, Evts, EvtsWait, EvtRaws}, Sd) ->
    Sd#sd{
        this_name = ThisName,
        prim      = PrimName,
        nodes     = Nodes,
        evts      = Evts,
        evts_wait = EvtsWait,
        evt_raws  = EvtRaws
    }.
%% -----------------

%% Things to be done assuming the Evt is defined.
%% Either process the event, store it for later processing, or discard it.
-spec store_and_process_evt(
    {Sender, Evt}, ThisName, {PrimName, PrimExs}, Nodes, Evts, EvtsWait, EvtRaws
) ->
    {ThisName1, PrimName1, Nodes1, Evts1, EvtsWait1, EvtRaws1}
    when
        Sender   :: hc_node:name(),
        Evt      :: hc_evt:evt() | hc_evt:evt_err(),
        PrimExs  :: [{hc_node:name(), term()}],
        ThisName :: hc_node:name(),     ThisName1 :: hc_node:name(), 
        PrimName :: hc_node:name(),     PrimName1 :: hc_node:name(), 
        Nodes    :: hc_node:cnodes(),   Nodes1    :: hc_node:cnodes(),
        Evts     :: evts_list(),        Evts1     :: evts_list(), 
        EvtsWait :: evts_list(),        EvtsWait1 :: evts_list(),
        EvtRaws  :: [hc_evt:evt_raw()], EvtRaws1  :: [hc_evt:evt_raw()].
store_and_process_evt(
    {Sender, Evt}, ThisName, {PrimName, Exs}, Nodes, Evts, EvtsWait, EvtRaws
) ->
    EvtRaws1 = del_from_raws(Evt, EvtRaws),
    case check_id_succession(Evt, Evts) of
        %
        % If Evt follows the latest one in Evts, cool.
        % Start by setting the primary node name to sender of node_pong().
        ok ->
            {ThisName1, PrimName1, Nodes1, Evts1, EvtsWait1} = process_all_evts(
                Evt, ThisName, {Sender, Exs}, Nodes, Evts, EvtsWait
            ),
            {ThisName1, PrimName1, Nodes1, Evts1, EvtsWait1, EvtRaws1};
        %
        % If it's an event that happens in the future, store it.
        error ->
            {ThisName, PrimName, Nodes, Evts, [Evt|EvtsWait], EvtRaws1};
        %
        % If it's an event that happened in the past, discard.
        ignore ->
            {ThisName, PrimName, Nodes, Evts, EvtsWait, EvtRaws1}
    end.

del_from_raws(Evt, Raws) ->
    del_from_raws(hc_evt:name(Evt), Raws, []).

del_from_raws(_Name, [], Acc) ->
    lists:reverse(Acc);
del_from_raws(Name, [Raw|Raws], Acc) ->
    case hc_evt:name(Raw) of
        Name -> lists:reverse(Acc) ++ Raws;
        _    -> del_from_raws(Name, Raws, [Raw|Acc])
    end.

%% Make sure the incoming event follows the latest one in the 
%% history list (Evts), i.e. its event id is just 1 increment of the last.
%%
%% If the history list (Evts) is empty, the Evt is automatically accepted.
%% Note that history will always be cleared once a sync is received.
check_id_succession(_Evt, [])   -> ok;
check_id_succession(Evt, [E|_]) -> check_id_succession_2(Evt, hc_evt:id(E)).

check_id_succession_2(Evt, N) ->
    N1 = N + 1,
    case hc_evt:id(Evt) of
        N1            -> ok;
        M when M > N1 -> error;
        M when M < N1 -> ignore
    end.
%% -----------------

%% Things to be done assuming the Evt is defined, and its id 
%% immediately follows the last one in the history list (Evts).
%% Basically just update different state data values and broadcast events.
-spec process_all_evts(Evt, ThisName, {PrimName, Exs}, Nodes, Evts, EvtsWait) ->
    {ThisName1, PrimName1, Nodes1, Evts1, EvtsWait1}
    when
        Evt      :: hc_evt:evt() | hc_evt:evt_err(),
        Exs      :: [{hc_node:name(), term()}],
        ThisName :: hc_node:name(),   ThisName1 :: hc_node:name(), 
        PrimName :: hc_node:name(),   PrimName1 :: hc_node:name(), 
        Nodes    :: hc_node:cnodes(), Nodes1    :: hc_node:cnodes(),
        Evts     :: evts_list(),      Evts1     :: evts_list(), 
        EvtsWait :: evts_list(),      EvtsWait1 :: evts_list().
process_all_evts(Evt, ThisName, {PrimName, PrimExs}, Nodes, Evts, EvtsWait) ->
    {ToBeProcessed, EvtsWait1} = get_consecutive_evts(
        [Evt], drop_earlier_ids(Evt, EvtsWait)
    ),
    {ThisName1, PrimName1, Nodes1, Evts1} = lists:foldr(
        fun(EvtArg, Tuple) -> process_evt(EvtArg, PrimExs, Tuple) end,
        {ThisName, PrimName, Nodes, Evts},
        ToBeProcessed
    ),
    {ThisName1, PrimName1, Nodes1, Evts1, EvtsWait1}.

%% This step should have no effect on regular node_pongs. However, if the 
%% node_pong was a sync, i.e. it brought an entire copy of the nodes list
%% with it, then this process is necessary.
drop_earlier_ids(Evt, EvtsWait) ->
    Id = hc_evt:id(Evt),
    [E || E <- EvtsWait, hc_evt:id(E) > Id].

%% Process not just the incoming Evt, but also all other evts sitting
%% in evts_wait that follow this Evt, and each other, consecutively.
get_consecutive_evts([Evt|_]=Acc, EvtsWait) ->
    case take_evt_with_id(hc_evt:id(Evt) + 1, EvtsWait, []) of
        {Evt1, EvtsWait1} -> get_consecutive_evts([Evt1|Acc], EvtsWait1);
        false             -> {Acc, EvtsWait}
    end.

take_evt_with_id(_Id, [], _Acc) ->
    false;
take_evt_with_id(Id, [Evt|Rest], Acc) ->
    case hc_evt:id(Evt) of
        Id -> {Evt, Acc ++ Rest};
        _  -> take_evt_with_id(Id, Rest, [Evt|Acc])
    end.

%% Update some internal state variables, and broadcast valid events to
%% client process subscribers (via client comms module).
process_evt(Evt, PrimExs, {ThisName, PrimName, Nodes, Evts}) ->
    Evts1 = update_evts(Evt, Evts),
    case hc_evt:is_evt(Evt) of
        %
        % Evt :: hc_evt:evt()
        true ->
            OrgName = hc_evt:org_name(Evt),
            EvtNode = hc_evt:cnode(Evt),
            {ThisName1, PrimName1, Nodes1} = update_nodes(
                ThisName, PrimName, OrgName, EvtNode, Nodes, PrimExs
            ),
            trigger_role_changes(ThisName1, PrimName1, Nodes1, Evts1),
            do_broadcast(OrgName, Nodes, EvtNode, Nodes1, hc_evt:type(Evt)),
            {ThisName1, PrimName1, Nodes1, Evts1};
        %
        % Evt :: hc_evt:evt_err()
        false ->
            PrimName1 = update_prim_name(ThisName, PrimName, Nodes),
            {ThisName, PrimName1, Nodes, Evts1}
    end.

update_evts(Evt, Evts) ->
    hc_evt:truncate_evts([Evt|Evts]).

update_nodes(This, Prim, EvtOrgName, EvtNode, Nodes, PrimExs) ->
    Nodes1 = update_nodes(EvtOrgName, EvtNode, Nodes),
    case hc_node:is_connected(EvtNode) of
        true ->
            {This1, Prim1} = updates_4_con_evtnode(
                This, Prim, EvtOrgName, EvtNode
            ),
            {This1, Prim1, Nodes1};
        false ->
            updates_4_disc_evtnode(
                This, Prim, EvtOrgName, EvtNode, Nodes, PrimExs
            )
    end.

update_nodes('undefined', Node, Nodes) -> 
    hc_node:store_node(Node, Nodes);
update_nodes(OrgName, Node, Nodes) -> 
    hc_node:store_node(OrgName, Node, Nodes).

updates_4_con_evtnode(Name, Name, Name, EvtNode) ->
    Name1 = hc_node:name(EvtNode),
    {Name1, Name1};
updates_4_con_evtnode(This, Prim, This, EvtNode) ->
    {hc_node:name(EvtNode), Prim};
updates_4_con_evtnode(This, Prim, Prim, EvtNode) ->
    {This, hc_node:name(EvtNode)};
updates_4_con_evtnode(This, Prim, _EvtOrgName, _EvtNode) ->
    {This, Prim}.

updates_4_disc_evtnode(Name, Name, Name, EvtNode, Nodes, _PrimExs) ->
    {hc_node:name(EvtNode), 'undefined', Nodes};
updates_4_disc_evtnode(This, _Prim, This, EvtNode, Nodes, _PrimExs) ->
    {hc_node:name(EvtNode), 'undefined', Nodes};
updates_4_disc_evtnode(This, Prim, Prim, _EvtNode, Nodes, PrimExs) ->
    case refresh_prim_name(Nodes, PrimExs) of
        'undefined' -> {This, 'undefined', disc_node(This, Nodes)};
        Prim1       -> {This, Prim1, Nodes}
    end;
updates_4_disc_evtnode(This, Prim, _EvtOrgName, _EvtNode, Nodes, _PrimExs) ->
    {This, Prim, Nodes}.

update_prim_name(ThisName, PrimName, Nodes) ->
    case hc_node:is_connected(hc_node:get_node(ThisName, Nodes)) of
        true  -> PrimName;
        false -> 'undefined'
    end.

disc_node(Name, Nodes) ->
    hc_node:store_node(
        hc_node:disconnect(hc_node:get_node(Name, Nodes)), Nodes
    ).

%% Refresh the primary node name, or undefined if there is
%% currently no eligible primary node.
refresh_prim_name(Nodes, PrimExs) ->
    do_refresh_prim('undefined', hc_node:cnodes_to_list(Nodes), PrimExs).

do_refresh_prim(Prim, [], _Ex) ->
    case Prim of
        'undefined' -> 'undefined';
        _           -> hc_node:name(Prim)
    end;
do_refresh_prim(Prim, [Node|Rest], Ex) ->
    case {hc_node:is_connected(Node), hc_node:priority(Node)} of
        {_, 0} ->
            do_refresh_prim(Prim, Rest, Ex);
        {false, _} ->
            do_refresh_prim(Prim, Rest, Ex);
        {true, _Pn} when Prim =:= 'undefined' ->
            do_refresh_prim(Prim, Node, Rest, Ex);
        {true, Pn} ->
            case hc_node:priority(Prim) of
                Pp when Pp > Pn   -> do_refresh_prim(Prim, Rest, Ex);
                Pp when Pp < Pn   -> do_refresh_prim(Prim, Node, Rest, Ex);
                Pp when Pp =:= Pn ->
                    case hc_node:rank(Prim) > hc_node:rank(Node) of
                        true  -> do_refresh_prim(Prim, Node, Rest, Ex);
                        false -> do_refresh_prim(Prim, Rest, Ex)
                    end
            end
    end.

do_refresh_prim(Prim, Node, Rest, Ex) ->
    do_refresh_prim(new_if_not_ex(Prim, Node, Ex), Rest, Ex).

new_if_not_ex(Old, New, PrimExs) ->
    case lists:keymember(hc_node:name(New), 1, PrimExs) of
        true  -> Old;
        false -> New
    end.

do_broadcast(OldName, OldNodes, NewNode, NewNodes, EvtType) ->
    % httpcluster_subs:broadcast/4 should be non-blocking.
    % httpcluster_subs:broadcast/4 should be customizable via coms module
    OldNode = case OldName of
        'undefined' -> 'undefined';
        OldName     -> hc_node:get_node(OldName, OldNodes)
    end,
    ?apply_coms_fun(
        ?HANDLER_CLUSTER_EVT,
        [EvtType, OldNode, NewNode, hc_node:cnodes_to_list(NewNodes)]
    ).
%% -----------------

%% Call other module functions based on role.
-spec trigger_role_changes(This, Prim, Nodes, Evts) -> _
    when
        This  :: hc_node:name(),
        Prim  :: 'undefined' | hc_node:name(),
        Nodes :: hc_node:cnodes(),
        Evts  :: evts_list().
trigger_role_changes(This, Prim, Nodes, Evts) ->
    case Prim of
        'undefined' -> httpcluster:deactivate();
        This        -> httpcluster:hard_activate(This, Nodes, Evts);
        _           -> httpcluster:deactivate()
    end,
    ok.
%% -----------------

%% Handle an error/invalid reply from the client comms module in
%% response to a ping attempt.
%%
%% Fire the necessary TTD timer, then determine if a retry is needed or not.
-spec handle_node_reply_error({Name, Ttd, Details}, Sd1) -> {IsRetry, Sd2}
    when
        Name    :: hc_node:name(),
        Ttd     :: hc_node:ttd(),
        Details :: term(),
        Sd1     :: sd(),
        IsRetry :: boolean(),
        Sd2     :: sd().
handle_node_reply_error({Name, Ttd, Details}, #sd{timers=Timers}=Sd) ->
    ?log_warning("Ping reply error on node ~p: ~p", [Name, Details]),
    Sd1 = Sd#sd{timers = hc_timer:prim_disc_on(Name, Ttd, Details, Timers)},
    {is_retry(Sd1), Sd1}.

is_retry(#sd{ping_attempts=Attempts}) ->
    length(lists:takewhile(
        fun(#ping_arg{type=?PING_RETRY}) -> true; (_) -> false end, Attempts
    )) < ?get_env(?PING_RETRY_FREQ).
%% -----------------

%% Do the ping procedure, either from a timer timeout, or a voluntary ping.
%% If the attempt (not the response) failed, abort the process
%% and delete the subject evt_raw(), if there was one.
-spec handle_do_ping(Timer, Sd1) -> {ok, Sd2} | {error, {Error, Sd2}}
    when 
        Timer :: 'undefined' | hc_timer:timer(),
        Error :: any(),
        Sd1   :: sd(),
        Sd2   :: sd().
handle_do_ping(Timer, #sd{
    this_name=From, prim=To, nodes=Nodes,
    evt_raws=Raws, ping_attempts=Attempts
}=Sd) ->
    case new_ping_arg(get_type_raw(Timer, Raws, Attempts), From, To, Nodes) of
        {ok, #ping_arg{}=PingArg} ->
            ping_remote_node(PingArg, Nodes),
            {ok, Sd#sd{ping_attempts = [PingArg|Attempts]}};
        {error, {{'reason', Error}, {'raw', Raw}}} ->
            {error, {Error, Sd#sd{evt_raws = del_from_raws(Raw, Raws)}}};
        {error, {'reason', Error}} ->
            {error, {Error, Sd}}
    end.

%% Determine the timer type (which will also becomes the #ping_arg.type) if
%% there was a timer present (defaults to ?PING_ROUTINE), 
%% and also the evt_raw() if there is one.
get_type_raw('undefined', [], _Attempts) ->
    ?PING_ROUTINE;
get_type_raw('undefined', [_|_]=Raws, _Attempts) ->
    {?PING_ROUTINE, lists:last(Raws)};
get_type_raw(Timer, Raws, Attempts) ->
    case hc_timer:type(Timer) of
        ?PING_ROUTINE when Raws =:= [] ->
            ?PING_ROUTINE;
        ?PING_ROUTINE ->
            {?PING_ROUTINE, lists:last(Raws)};
        ?PING_RETRY ->
            case lists:keyfind(
                hc_timer:details(Timer), #ping_arg.ref, Attempts
            ) of
                #ping_arg{node_ping=Ping} ->
                    case hc_evt:node_ping_raw(Ping) of
                        'undefined' -> ?PING_RETRY;
                        Raw         -> {?PING_RETRY, Raw}
                    end;
                false when Raws =:= [] ->
                    ?PING_ROUTINE;
                false ->
                    {?PING_ROUTINE, lists:last(Raws)}
            end
    end.

%% Create ping arguments, either from a timer timeout, or voluntary ping.
%% Also returns the evt_raw() used, or to be used, for the ping_arg().
%%
%% Will accept a DOWN origin node if the accompanying 
%% evt_raw() is an ?EVT_NODE_UP.
new_ping_arg({Type, Raw}, From, To, Nodes) ->
    RawType = hc_evt:type(Raw),
    case validate_node_names(From, To, Nodes) of
        ok -> 
            {ok, new_ping_arg(Type, Raw, From, To, false)};
        {error, 'origin_down'} when RawType =:= ?EVT_NODE_UP ->
            {ok, new_ping_arg(Type, Raw, From, To, false)};
        {error, Error} ->
            {error, {{'reason', Error}, {'raw', Raw}}}
    end;
new_ping_arg(Type, From, To, Nodes) ->
    case validate_node_names(From, To, Nodes) of
        ok           -> {ok, new_ping_arg(Type, 'undefined', From, To, false)};
        {error, Err} -> {error, {'reason', Err}}
    end.

new_ping_arg(Type, Raw, From, To, Sync) ->
    #ping_arg{
        ref = make_ref(),
        type = Type,
        node_ping = hc_evt:new_node_ping(
            hc_evt:random_str(8), From, To, Raw, Sync
        )
    }.

%% Validates both sender and destination nodes.
%% Will return an error if the 'from' node is down.
validate_node_names(From, To, Nodes) ->
    case {hc_node:get_node(From, Nodes), hc_node:get_node(To, Nodes)} of
        {_, 'undefined'} ->
            {error, 'destination_not_found'};
        {'undefined', _} ->
            {error, 'origin_not_found'};
        {FromNode, _ToNode} ->
            case hc_node:is_connected(FromNode) of
                true  -> ok;
                false -> {error, 'origin_down'}
            end
    end.

%% Use the client comms module to ping a destination node.
-spec ping_remote_node(PingArg, Nodes) -> _
    when PingArg :: ping_arg(), Nodes :: hc_node:cnodes().
ping_remote_node(#ping_arg{ref=PingRef, node_ping=NodePing}, Nodes) ->
    Mod = ?get_env(?MOD_COMS),
    ?log_debug(
        "(PingRef: ~p) Applying client handler funs: ~p:~p/3, ~p:~p/4", 
        [PingRef, Mod, ?HANDLER_CREATE_PINGDATA, Mod, ?HANDLER_PING_TO_NODE]
    ),
    proc_lib:spawn_link(?MODULE, 'apply_ping_funs', [PingRef, NodePing, Nodes]).

%% @private
%% @doc Used internally to execute the ping functions of the user comms module.
%%      Meant to be called as a separate process to be safe.
-spec 'apply_ping_funs'(PingRef, NodePing, Nodes) -> _
    when
        PingRef  :: reference(),
        NodePing :: hc_evt:node_ping(),
        Nodes    :: hc_node:cnodes().
'apply_ping_funs'(PingRef, NodePing, Nodes) ->
    proc_lib:init_ack({ok, self()}),
    {FromNode, ToNode, OtherNodes} = get_from_to_other_nodes(NodePing, Nodes),
    ?apply_coms_fun(
        ?HANDLER_PING_TO_NODE,
        [
            ?apply_coms_fun(
                ?HANDLER_CREATE_PINGDATA,
                [NodePing, FromNode, OtherNodes]
            ),
            FromNode, ToNode, PingRef
        ]
    ).

get_from_to_other_nodes(Ping, Nodes) ->
    {Fnode, Nodes1} = hc_node:take_node(hc_evt:node_com_source(Ping), Nodes),
    Tnode = hc_node:get_node(hc_evt:node_com_destination(Ping), Nodes),
    {Fnode, Tnode, hc_node:cnodes_to_list(Nodes1)}.
%% -----------------

%% Try to send a sync ping to the first element of the nodes list.
-spec handle_do_sync_ping(Sd1) -> 
    {ok, {Node, Sd2}} | {error, {Error, Node, Sd2}} | {error, 'nodelist_empty'}
    when
        Sd1   :: sd(),
        Sd2   :: sd(),
        Node  :: hc_node:cnode(),
        Error :: any().
handle_do_sync_ping(#sd{this_name=This, nodes=Nodes}=Sd) ->
    case prepare_sync_ping(Sd) of
        {ok, {_ToNode, #sd{ping_attempts=[Parg|_]}}}=Ok ->
            httpcluster:soft_init(hc_node:get_node(This, Nodes)),
            ping_remote_node(Parg, Nodes),
            Ok;
        {error, _}=Error ->
            httpcluster:deactivate(),
            Error
    end.

prepare_sync_ping(#sd{
    this_name=From, nodes=Nodes,
    evt_raws=[Raw|_], ping_attempts=Attempts
}=Sd) ->
    case hc_node:get_first(Nodes) of
        'undefined' ->
            {error, 'nodelist_empty'};
        ToNode ->
            case sync_ping_arg(Raw, From, hc_node:name(ToNode), Nodes) of
                {ok, #ping_arg{}=PingArg} ->
                    {ok, {ToNode, Sd#sd{ping_attempts = [PingArg|Attempts]}}};
                {error, Error} ->
                    {error, {Error, ToNode, Sd}}
            end
    end.

sync_ping_arg(Raw, From, To, Nodes) ->
    Type = ?PING_SYNC,
    case validate_node_names(From, To, Nodes) of
        ok                     -> {ok, new_ping_arg(Type, Raw, From, To, true)};
        {error, 'origin_down'} -> {ok, new_ping_arg(Type, Raw, From, To, true)};
        {error, _}=Error       -> Error
    end.
%% -----------------

%% Perform procedures necessary when a ttd timer for a primary node times out.
%%
%% If this node becomes primary because the previous one timed out,
%% then forge nodedown raw pings for all previous prims that timed out,
%% then send those to the local primary cluster process (httpcluster module).
%% 
%% If this node went down because the primary went down, then forge
%% a local nodedown event and broadcast to subscribing processes.
-spec handle_prim_timeout(Name, Details, Sd1) -> Sd2
    when
        Name    :: hc_node:name(),
        Details :: term(),
        Sd1     :: sd(),
        Sd2     :: sd().
handle_prim_timeout(Name, Details, #sd{this_name=This, nodes=Nodes}=Sd) ->
    Exs1   = [{Name, Details}|Sd#sd.prim_exs],
    Prim1  = refresh_prim_name(Nodes, Exs1),
    Nodes1 = case Prim1 of
        'undefined' -> disc_node(This, Nodes);
        _           -> Nodes
    end,
    trigger_role_changes(This, Prim1, Nodes1, Sd#sd.evts),
    hard_primdown_transition(This, Prim1, Exs1, Nodes, Nodes1),
    Sd#sd{prim = Prim1, prim_exs = Exs1, nodes = Nodes1}.

hard_primdown_transition(This, 'undefined', _Exs, OldNodes, NewNodes) ->
    do_broadcast(
        This, OldNodes, hc_node:get_node(This, NewNodes), 
        NewNodes, ?EVT_NODE_DOWN
    );
hard_primdown_transition(Prim, Prim, Exs, _OldNodes, Nodes) ->
    forge_nodedown_pings(Prim, Exs, Nodes);
hard_primdown_transition(_This, _Prim, _Exs, _OldNodes, _NewNodes) ->
    ok.

forge_nodedown_pings(Prim, Exs, Nodes) ->
    Pargs = nodedown_raws_to_pingargs(exs_to_nodedown_raws(Exs, Nodes), Prim),
    [ping_remote_node(Parg, Nodes) || Parg <- Pargs].

nodedown_raws_to_pingargs(Raws, ToName) ->
    [new_ping_arg(
        ?PING_ROUTINE, Raw, hc_node:name(hc_evt:cnode(Raw)), 
        ToName, false
     ) || Raw <- Raws].

exs_to_nodedown_raws(Exs, Nodes) ->
    [hc_evt:new_raw(
        new_raw_name(?EVT_NODE_DOWN, Name), ?EVT_NODE_DOWN,
        hc_node:disconnect(hc_node:get_node(Name, Nodes))
     ) || {Name, _} <- Exs].

new_raw_name(Type, NodeName) ->
    Type ++ "_" ++ NodeName ++ "_" ++ hc_evt:random_str(8).

%%====================================================================
%% Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-endif.
