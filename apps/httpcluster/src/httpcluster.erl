%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Handles cluster information. This module runs the main primary-node
%%%      functions such as triggering TTD timers on nodes, refreshing them
%%%      if the nodes check in, and manipulating node info when requested.
%%%
%%%      The cluster information being run by the primary node then becomes 
%%%      the source of truth for all secondary nodes.
%%%
%%%      Nodes check in (health check) using {@link node_ping/1}. If
%%%      they fail to do that within their TTD window, a node-down event
%%%      is automatically triggered within the module and the cluster info
%%%      is updated.

-module(httpcluster).
-behaviour(gen_server).

-include("httpcluster_int.hrl").
-include("../include/httpcluster.hrl").

%% API
-export([
    start/0,
    start_link/1,
    soft_init/1,
    hard_activate/3,
    node_ping/1,
    deactivate/0,
    is_active/0
]).

%% Debugging
-export([
    get_nodes/0,
    get_evts/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Module internal
-export([
    'cast_node_pong'/4,
    'reply_with_node_reply_error'/6,
    'reply_with_node_pong_ok'/6
]).

-define(SERVER, ?MODULE).

%%====================================================================
%% Types
%%====================================================================

-type local_id() :: reference().

-record(pnode, {
    local_id :: local_id(),
    name     :: string(),
    ttd      :: pos_integer(),
    con      :: boolean(),
    rank     :: non_neg_integer(),
    prio     :: non_neg_integer(),
    attribs  :: 'undefined' | binary() % term_to_binary(Attribs)
}).
-type pnode() :: #pnode{}.
%% This module's own representation of hc_node:cnode(). 
%% A pnode() will only exist locally within the context of the primary node;
%% it will not be communicated to the network like an hc_node:cnode().
%%
%% Most of these values are of similar type as in hc_node:cnode().

-record(sd, {
    init_id    :: 'undefined' | local_id(),
    this_id    :: 'undefined' | local_id(),
    nodes = [] :: [pnode()],
    evts  = [] :: [hc_evt:evt() | hc_evt:evt_err()],
    timers     :: hc_timer:timers()
}).
-type sd() :: #sd{}.
%% Internal state data.

%%====================================================================
%% API
%%====================================================================

%% @doc Useful for starting the VM with `-s httpcluster' flag.
-spec start() -> {ok, Started} | {error, Error}
    when Started :: [atom()], Error :: any().
start() ->
    application:ensure_all_started('httpcluster').

%% @private
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).

%% @doc Put the server on standby, awaiting ping from self node. This
%%      is the same as not active, but the server will respond to a future
%%      nodeup event coming from the given node. It will keep doing this 
%%      as long as it is not activated/deactivated.
-spec soft_init(ThisNode) -> ok | {error, 'already_active'}
    when ThisNode :: hc_node:cnode().
soft_init(ThisNode) ->
    gen_server:call(?SERVER, {'soft_init', ThisNode}).

%% @doc Activate the server as primary with a new set of `Nodes' and `Evts'.
%%      `ThisName' is the name of this node, which must be present in `Nodes'.
%%
%%      Calling this function again after the server has been activated 
%%      will result in an error.
-spec hard_activate(ThisName, Nodes, Evts) -> 
    ok | {error, 'this_node_not_found' | 'already_active'}
    when
        ThisName :: hc_node:name(),
        Nodes    :: hc_node:cnodes(),
        Evts     :: [hc_evt:evt() | hc_evt:evt_err()].
hard_activate(ThisName, Nodes, Evts) ->
    gen_server:call(?SERVER, {'hard_activate', ThisName, Nodes, Evts}).

%% @doc Process a {@link hc_evt:node_ping()} coming from a single source.
%%      The ping may or may not contain an `evt_raw'.
%%
%%      If successful, return the result as a {@link hc_evt:node_pong()}, 
%%      along with the most recent list of nodes if the ping was a sync.
%%      The nodes returned in this way is the list just before
%%      the `evt_raw' is applied. Additionally, the `node_pong' will be
%%      broadcasted to all other live nodes. 
%%
%%      If the ping is invalid, or a {@link hc_evt:node_reply()}
%%      resulted from processing the ping, then no broadcast will happen.
%%
%%      Calling this function also serves as a health check for
%%      the ping source regardless if there was an `evt_raw' in it or not.
%%
%%      The actual returned value `Data' will be the {@link hc_evt:node_pong()}
%%      or {@link hc_evt:node_reply()} filtered through the client comm module
%%      function `create_pongdata/3'.
-spec node_ping(Ping) -> {ok, Data}
    when Ping :: hc_evt:node_ping(), Data :: term().
node_ping(Ping) ->
    gen_server:call(?SERVER, {'node_ping', Ping}).

%% @doc Turn off active state.
-spec deactivate() -> ok | {error, 'not_active'}.
deactivate() ->
    gen_server:call(?SERVER, 'deactivate').

%% @doc Check if currently active or not.
-spec is_active() -> boolean().
is_active() ->
    gen_server:call(?SERVER, 'is_active').

%% @doc Get the local nodes list. For debugging purposes.
-spec get_nodes() -> Nodes
    when Nodes :: [pnode()].
get_nodes() ->
    gen_server:call(?SERVER, 'get_nodes').

%% @doc Get the local history list. For debugging purposes.
-spec get_evts() -> Hist
    when Hist :: [hc_evt:evt() | hc_evt:evt_err()].
get_evts() ->
    gen_server:call(?SERVER, 'get_evts').

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([_Opts]) ->
    process_flag('trap_exit', true),
    {ok, #sd{timers = hc_timer:empty()}}.

%% @private
handle_call({'soft_init', Node}, _From, #sd{this_id='undefined'}=Sd) ->
    #pnode{local_id=Id} = Pnode = from_cnode(Node),
    {reply, ok, Sd#sd{init_id = Id, nodes = [Pnode]}};

handle_call({'soft_init', _}, _From, Sd) ->
    {reply, {error, 'already_active'}, Sd};

handle_call(
    {'hard_activate', ThisName, Cnodes, Evts}, _From, #sd{this_id='undefined'}=Sd
) ->
    {Nodes1, Timers1} = lists:foldl(
        fun(Cnode, {Ns, Ts}) ->
            Pnode = from_cnode(Cnode),
            {[Pnode|Ns], trigger_timer(Pnode, Ts, false)}
        end,
        {[], hc_timer:empty()}, hc_node:cnodes_to_list(Cnodes)
    ),
    case get_node(ThisName, Nodes1) of
        #pnode{local_id=Id} ->
            % Seed now for future hc_evt:random_str/1 calls
            random:seed(now()),
            {reply, ok, update_sd(
                Evts, Nodes1, Timers1, 
                Sd#sd{init_id = 'undefined', this_id = Id}
            )};
        'undefined' ->
            hc_timer:all_off(Timers1),
            {reply, {error, 'this_node_not_found'}, Sd}
    end;

handle_call({'hard_activate', _,_,_}, _From, Sd) ->
    {reply, {error, 'already_active'}, Sd};

handle_call({'node_ping', Ping}, From, Sd) ->
    {noreply, handle_node_ping(Ping, From, Sd)};

handle_call('deactivate', _From, #sd{this_id='undefined'}=Sd) ->
    {reply, {error, 'not_active'}, Sd#sd{init_id = 'undefined'}};

handle_call('deactivate', _From, Sd) ->
    {reply, ok, Sd#sd{init_id = 'undefined', this_id = 'undefined'}};

handle_call('is_active', _From, #sd{this_id=ThisId}=Sd) ->
    {reply, ThisId =/= 'undefined', Sd};

handle_call('get_nodes', _From, Sd) ->
    {reply, Sd#sd.nodes, Sd};

handle_call('get_evts', _From, Sd) ->
    {reply, Sd#sd.evts, Sd};

handle_call(_Msg, _From, Sd) ->
    {reply, {error, 'undefined'}, Sd}.

%% @private
handle_cast(_Msg, Sd) ->
    {noreply, Sd}.

%% @private
handle_info({'$ttd_timeout', T}, #sd{this_id='undefined', timers=Ts}=Sd) ->
    {_, Ts1} = hc_timer:del_if_exists(T, Ts),
    {noreply, Sd#sd{timers = Ts1}};

handle_info({'$ttd_timeout', T}, #sd{timers=Ts}=Sd) ->
    Sd1 = case hc_timer:del_if_exists(T, Ts) of
        {true, Ts1} -> handle_ttd_timeout(T, Sd#sd{timers = Ts1});
        {false, _}  -> Sd
    end,
    {noreply, Sd1};

handle_info({'EXIT', Pid, Reason}, Sd) ->
    case Reason of
        'normal'        -> ok;
        'shutdown'      -> ok;
        {'shutdown', _} -> ok;
        _               -> ?log_warning("Pid ~p terminated: ~p", [Pid, Reason])
    end,
    {noreply, Sd};

handle_info(_Msg, Sd) ->
    {noreply, Sd}.

%% @private
terminate(_Reason, _Sd) ->
    ok.

%% @private
code_change(_OldVsn, Sd, _Extra) ->
    {ok, Sd}.

%%====================================================================
%% Internal functions
%%====================================================================

new_con_pnode(Name, Ttd, Prio, Attribs, Nodes) ->
    new_pnode(Name, Ttd, Prio, Attribs, true, new_rank(Nodes)).

edit_pnode(Name, Ttd, Prio, Node) ->
    Node#pnode{
        name = Name,
        ttd  = def_ttd_if_zero(Ttd),
        prio = Prio
    }.

edit_pnode(Attribs, Node) ->
    Node#pnode{attribs = attribs_to_bin(Attribs)}.

connect_pnode(Name, Ttd, Prio, Attribs, #pnode{local_id=Id}, Nodes) ->
    new_pnode(Id, Name, Ttd, Prio, Attribs, true, new_rank(Nodes)).

disconnect_pnode(Node) ->
    Node#pnode{con = false, rank = 0}.

new_pnode(Name, Ttd, Prio, Attribs, Con, Rank) ->
    new_pnode(make_ref(), Name, Ttd, Prio, Attribs, Con, Rank).

new_pnode(Id, Name, Ttd, Prio, Attribs, Con, Rank) ->
    #pnode{
        local_id = Id,
        name     = Name,
        ttd      = def_ttd_if_zero(Ttd),
        prio     = Prio,
        attribs  = attribs_to_bin(Attribs),
        con      = Con,
        rank     = Rank
    }.

def_ttd_if_zero(0)   -> ?get_env(?DEF_TTD);
def_ttd_if_zero(Ttd) -> Ttd.

attribs_to_bin('undefined') -> 'undefined';
attribs_to_bin(Attribs)     -> term_to_binary(Attribs).

new_rank(Nodes) ->
    lists:foldl(
        fun
        (#pnode{rank=Rank, con=true}, Acc) when Rank > Acc -> Rank;
        (#pnode{con=true}, Acc)                            -> Acc;
        (#pnode{con=false}, Acc)                           -> Acc
        end, 
        0, Nodes
    ) + 1.

pnode_name(#pnode{name=Name}) -> Name;
pnode_name('undefined')       -> 'undefined'.

from_cnode(Cnode) ->
    new_pnode(
        hc_node:name(Cnode), 
        hc_node:ttd(Cnode), 
        hc_node:priority(Cnode), 
        hc_node:attribs(Cnode), 
        hc_node:is_connected(Cnode), 
        hc_node:rank(Cnode)
    ).

to_cnode(Node) ->
    hc_node:new(
        Node#pnode.name,
        bin_to_attribs(Node#pnode.attribs),
        Node#pnode.ttd,
        Node#pnode.prio,
        Node#pnode.con,
        Node#pnode.rank
    ).

bin_to_attribs('undefined') -> 'undefined';
bin_to_attribs(Bin)         -> binary_to_term(Bin).

get_node(Ident, Nodes) ->
    case lists:keyfind(Ident, ident_int(Ident), Nodes) of
        #pnode{}=Node -> Node;
        false         -> 'undefined'
    end.

take_node(Ident, Nodes) ->
    case lists:keytake(Ident, ident_int(Ident), Nodes) of
        {'value', Node, OtherNodes} -> {Node, OtherNodes};
        false                       -> {'undefined', Nodes}
    end.

ident_int(Ident) ->
    case is_local_id(Ident) of
        true  -> #pnode.local_id;
        false -> #pnode.name
    end.

% A weak function
is_local_id(Id) when is_reference(Id) -> true;
is_local_id(_)                        -> false.

store_node('undefined', Nodes)   -> Nodes;
store_node(#pnode{}=Node, Nodes) -> [Node|Nodes].

local_id(#pnode{local_id=Id}) -> Id;
local_id('undefined')         -> 'undefined'.
%% -----------------

%% When a node_ping() is received from a remote node, it will be checked
%% for validity. If so, and the result of processing it is an evt() or 
%% an evt_err(), then a node_pong() will be created both as a reply,
%% and a broadcast to all other live nodes. 
%%
%% The broadcasted node_pong() in this case will never be a sync (i.e.,
%% containing a non-undefined 'nodes' property) even if the original
%% node_ping() was.
%%
%% If the result of processing the node_ping() was an node_reply(), then
%% no broadcast will happen.
%%
%% If a soft init is triggered, server will only respond to a ping that
%% contains a nodeup event from self node.
-spec handle_node_ping(Ping, From, Sd1) -> Sd2
    when
        Ping :: hc_evt:node_ping(),
        From :: term(),
        Sd1  :: sd(),
        Sd2  :: sd().
handle_node_ping(Ping, From, #sd{init_id=Init, this_id=This, nodes=Nodes}=Sd) ->
    case {Init, This} of
        {'undefined', 'undefined'} ->
            dont_handle_node_ping(Ping, From, Sd);
        {_, 'undefined'} ->
            #pnode{name=Name} = get_node(Init, Nodes),
            case is_nodeup4(Name, Ping) of
                true  -> do_handle_node_ping(Init, Ping, From, Sd);
                false -> dont_handle_node_ping(Ping, From, Sd)
            end;
        {_,_} ->
            do_handle_node_ping(This, Ping, From, Sd)
    end.

dont_handle_node_ping(Ping, From, Sd) ->
    proc_lib:spawn_link(
        ?MODULE, 'reply_with_node_reply_error',
        [hc_evt:node_com_id(Ping), 'not_primary',
         hc_evt:node_com_destination(Ping), hc_evt:node_com_source(Ping),
         Sd#sd.nodes, From]
    ),
    Sd.

do_handle_node_ping(ThisId, Ping, From, #sd{nodes=Nodes}=Sd) ->
    PingId = hc_evt:node_com_id(Ping),
    PingSource = hc_evt:node_com_source(Ping),
    #pnode{name=ThisNameOrig} = get_node(ThisId, Nodes),
    case hc_evt:node_com_destination(Ping) of
        ThisNameOrig ->
            % Process the valid ping that may or may not contain a raw.
            {{Id, Evt, Cnodes}, #sd{nodes=Nodes1}=Sd1} = handle_raw_from_node(
                PingSource, hc_evt:node_ping_raw(Ping), 
                hc_evt:node_ping_sync(Ping), Sd
            ),
            % Reply back with the result.
            proc_lib:spawn_link(
                ?MODULE, 'reply_with_node_pong_ok',
                [PingId, {Evt, Cnodes}, {ThisId, ThisNameOrig},
                 PingSource, Nodes1, From]
            ),
            % Dessiminate the event to other nodes if applicable.
            node_cast(Id, Evt, {ThisId, ThisNameOrig}, Nodes1),
            Sd1;
        _ ->
            proc_lib:spawn_link(
                ?MODULE, 'reply_with_node_reply_error',
                [PingId, 'invalid_destination', 
                 ThisId, PingSource, Nodes, From]
            ),
            Sd
    end.

node_cast(_Id, 'undefined', _ThisInfo, _Nodes) ->
    ok;
node_cast(Id, Evt, ThisInfo, Nodes) ->
    proc_lib:spawn_link(?MODULE, 'cast_node_pong', [Id, Evt, ThisInfo, Nodes]).

is_nodeup4(Name, Ping) ->
    (hc_evt:node_com_source(Ping) =:= Name) andalso 
    (hc_evt:type(hc_evt:node_ping_raw(Ping)) =:= ?EVT_NODE_UP).

%% @private
%% @doc Create and broadcast a node_pong(). Create a node_pong()
%%      record containing `Evt' and send it to all connected 
%%      nodes except for this node and the subject node of `Evt'.
-spec 'cast_node_pong'(EvtSourceId, Evt, {ThisId, ThisNameOrig}, Nodes) -> _
    when
        EvtSourceId  :: 'undefined' | local_id(),
        Evt          :: hc_evt:evt() | hc_evt:evt_err(),
        ThisId       :: local_id(),
        ThisNameOrig :: hc_node:name(),
        Nodes        :: [pnode()].
'cast_node_pong'(EvtSourceId, Evt, {ThisId, ThisNameOrig}, Nodes) ->
    proc_lib:init_ack({ok, self()}),
    {ThisNode, OtherNodes} = take_node(ThisId, Nodes),
    FromInfo    = {to_cnode(ThisNode), ThisNameOrig},
    OtherCnodes = [to_cnode(Nx) || Nx <- OtherNodes],
    PongId      = hc_evt:random_str(8),
    [do_cast_pongdata(PongId, Evt, FromInfo, to_cnode(N), OtherCnodes) ||
        N <- Nodes, N#pnode.con, N#pnode.local_id =/= EvtSourceId].

do_cast_pongdata(PongId, Evt, {FromCnode, FromName}, ToCnode, OtherCnodes) ->
    NodePong = hc_evt:new_node_pong(
        PongId, FromName, hc_node:name(ToCnode), Evt, 'undefined'
    ),
    ?apply_coms_fun(
        ?HANDLER_PONG_TO_NODE,
        [
            ?apply_coms_fun(
                ?HANDLER_CREATE_PONGDATA,
                [NodePong, FromCnode, OtherCnodes]
            ),
            FromCnode, ToCnode
        ]
    ).

%% @private
%% @doc Create and serialize a {@link hc_evt:node_reply()} containing 
%%      an error message using the client comms module.
%%      Meant to be called as a separate process not only to be safe, but to
%%      prevent race conditions as well.
-spec 'reply_with_node_reply_error'(ComId, Reason, Source, Dest, Nodes, From) ->
    _
    when
        ComId  :: string(),
        Reason :: term(),
        Source :: hc_node:name() | local_id(),
        Dest   :: hc_node:name(),
        Nodes  :: [pnode()],
        From   :: term().
'reply_with_node_reply_error'(ComId, Reason, Source, Dest, Nodes, From) ->
    proc_lib:init_ack({ok, self()}),
    SourceName = case is_local_id(Source) of
        true  -> #pnode{name=Name}=get_node(Source, Nodes), Name;
        false -> Source
    end,
    NodeReply = hc_evt:new_node_reply(ComId, SourceName, Dest, {error, Reason}),
    create_pongdata_then_reply(NodeReply, Source, Nodes, From).

%% @private
%% @doc Create and serialize a {@link hc_evt:node_pong()} 
%%      using the client comms module.
%%      Meant to be called as a separate process not only to be safe, but to
%%      prevent race conditions as well.
-spec 'reply_with_node_pong_ok'(
    ComId, {ComEvt, ComCnodes}, {SourceId, SourceName}, Dest, Nodes, From
) -> _
    when
        ComId      :: string(),
        ComEvt     :: 'undefined' | hc_evt:evt() | hc_evt:evt_err(),
        ComCnodes  :: 'undefined' | hc_node:cnodes(),
        SourceId   :: local_id(),
        SourceName :: hc_node:name(),
        Dest       :: hc_node:name(),
        Nodes      :: [pnode()],
        From       :: term().
'reply_with_node_pong_ok'(
    ComId, {ComEvt, ComCnodes}, {SourceId, SourceName}, Dest, Nodes, From
) ->
    proc_lib:init_ack({ok, self()}),
    NodePong = hc_evt:new_node_pong(ComId, SourceName, Dest, ComEvt, ComCnodes),
    create_pongdata_then_reply(NodePong, SourceId, Nodes, From).

create_pongdata_then_reply(NodeCom, Source, Nodes, From) ->
    {SourceCnode, OtherCnodes} = case is_local_id(Source) of
        true -> 
            {N, Ns} = take_node(Source, Nodes),
            {to_cnode(N), [to_cnode(Nx) || Nx <- Ns]};
        false ->
            {hc_node:new(Source, 'undefined'), hc_node:empty()}
    end,
    Data = ?apply_coms_fun(
        ?HANDLER_CREATE_PONGDATA, [NodeCom, SourceCnode, OtherCnodes]
    ),
    gen_server:reply(From, {ok, Data}).
%% -----------------

%% Processes a given evt_raw (ReqRaw) from a node (ReqNodeName)
%% into the server state data and return the resulting evt or evt_err.
%% Also returns the local_id of the subject node, and the current 
%% Nodes list if ReqDoSync is true.
-spec handle_raw_from_node(ReqNodeName, ReqRaw, ReqDoSync, Sd) ->
    {{Id, Evt, Nodes}, Sd1}
    when
        ReqNodeName :: hc_node:name(),
        ReqRaw      :: 'undefined' | hc_evt:evt_raw(),
        ReqDoSync   :: boolean(),
        Sd          :: sd(),
        Id          :: 'undefined' | local_id(),
        Evt         :: 'undefined' | hc_evt:evt() | hc_evt:evt_err(),
        Nodes       :: 'undefined' | hc_node:cnodes(),
        Sd1         :: sd().
handle_raw_from_node(
    ReqNodeName, ReqRaw, ReqDoSync,
    #sd{nodes=Nodes, evts=Evts, timers=Timers}=Sd
) ->
    log_if_defined(
        ReqRaw, "Begin processing evt_raw from ~p: ~p", [ReqNodeName, ReqRaw]
    ),
    {Id, Evt, Nodes1, Timers1} = process_raw(
        {ReqNodeName, ReqRaw}, get_last_evtid(Evts), Nodes, Timers
    ),
    log_if_defined(
        Evt, "Done processing evt_raw from ~p: ~p", [ReqNodeName, Evt]
    ),
    Return = {Id, Evt, undef_or_cnodes(ReqDoSync, Nodes)},
    {Return, update_sd({Evt, Nodes1, Timers1}, Sd)}.

log_if_defined('undefined', _,_) -> ok;
log_if_defined(_, Format, Args)  -> ?log_debug(Format, Args).

get_last_evtid([])      -> 0;
get_last_evtid([Evt|_]) -> hc_evt:id(Evt).

undef_or_cnodes(true, Nodes) -> 
    hc_node:list_to_cnodes([to_cnode(Node) || Node <- Nodes]);
undef_or_cnodes(false, _) -> 
    'undefined'.

%% Fires an automatic NODE_DOWN on a node that times out on its TTD.
-spec handle_ttd_timeout(Timer, Sd) -> Sd1
    when
        Timer :: hc_timer:timer(), 
        Sd    :: sd(),
        Sd1   :: sd().
handle_ttd_timeout(
    Timer, #sd{this_id=ThisId, nodes=Nodes, evts=Evts, timers=Timers}=Sd
) ->
    % Include an additional check to make sure no NODE_DOWN 
    % evts are created for non-existing nodes.
    Ident = hc_timer:ident(Timer),
    case get_node(Ident, Nodes) of
        'undefined' ->
            Sd;
        Node ->
            #pnode{name=ThisNameOrig} = get_node(ThisId, Nodes),
            {Id, Evt, Nodes1, Timers1} = process_raw(
                {Ident, nodedown_raw("ttd_timeout_", Node)},
                get_last_evtid(Evts), Nodes, Timers
            ),
            Sd1 = update_sd({Evt, Nodes1, Timers1}, Sd),
            node_cast(Id, Evt, {ThisId, ThisNameOrig}, Sd1#sd.nodes),
            Sd1
    end.

nodedown_raw(Prefix, Node) ->
    hc_evt:new_raw(
        Prefix ++ Node#pnode.name, 
        ?EVT_NODE_DOWN, 
        to_cnode(disconnect_pnode(Node))
    ).
%% -----------------

%% Do the thing!
-spec process_raw({NodeIdent, Raw}, LastEvtId, Nodes, Timers) ->
    {Id, Evt, Nodes1, Timers1}
    when
        NodeIdent :: hc_node:name() | local_id(),
        Raw       :: 'undefined' | hc_evt:evt_raw(),
        LastEvtId :: 0 | hc_evt:id(),
        Nodes     :: [pnode()],
        Timers    :: hc_timer:timers(),
        Id        :: 'undefined' | local_id(),
        Evt       :: 'undefined' | hc_evt:evt() | hc_evt:evt_err(),
        Nodes1    :: [pnode()],
        Timers1   :: hc_timer:timers().
process_raw({NodeIdent, Raw}, LastEvtId, Nodes, Timers) ->
    {Node, OtherNodes} = take_node(NodeIdent, Nodes),
    {Node1, Evt1, Timers1} = raw2evt_with_timer_triggers(
        Node, OtherNodes, LastEvtId, Raw, Timers
    ),
    Nodes1 = store_node(Node1, OtherNodes),
    {local_id(Node1), Evt1, Nodes1, Timers1}.

raw2evt_with_timer_triggers(OldNode, _,_, 'undefined', Timers) ->
    {OldNode, 'undefined', trigger_timer(OldNode, Timers, true)};
raw2evt_with_timer_triggers(OldNode, OtherNodes, LastEvtId, Raw, Timers) ->
    % Refresh timer as a first step just in case processing the raw
    % will take a longer time than expected. 
    %
    % SemiNewTimers should be exactly the same as Timers.
    SemiNewTimers = trigger_timer(OldNode, Timers, false),
    {NewNode, NewEvt} = raw2evt(OldNode, OtherNodes, LastEvtId, Raw),
    % This time, if the node went down, turn off the timer.
    % If it went up, turn on the timer.
    % If it stayed up, the timer may be refreshed twice in 
    % rapid succession, which is ok.
    NewTimers = trigger_timer(NewNode, SemiNewTimers, true),
    {NewNode, NewEvt, NewTimers}.

trigger_timer('undefined', Timers, _) ->
    Timers;
trigger_timer(#pnode{local_id=Id, ttd=Ttd, con=true}, Timers, _) ->
    hc_timer:sec_disc_on(Id, Ttd + ?get_env(?TTD_DELAY), Timers);
trigger_timer(#pnode{local_id=Id, con=false}, Timers, true) ->
    hc_timer:sec_disc_off(Id, Timers);
trigger_timer(#pnode{con=false}, Timers, false) ->
    Timers.

update_sd({Evt, Nodes, Timers}, #sd{evts=Evts}=Sd) ->
    update_sd(update_evts(Evt, Evts), Nodes, Timers, Sd).

update_sd(Evts, Nodes, Timers, Sd) ->
    Sd#sd{evts = hc_evt:truncate_evts(Evts), nodes = Nodes, timers = Timers}.

update_evts('undefined', Evts) -> Evts;
update_evts(Evt, Evts)         -> [Evt|Evts].

%% Convert an evt_raw() into either an evt() (successfully processed) 
%% or an evt_err() (error during processing). Also returns the
%% resulting pnode() after processing.
-spec raw2evt(OldNode, OtherNodes, LastId, Raw) -> 
    {NewNode, Evt} | {OldNode, Err}
    when
        OldNode    :: pnode() | 'undefined',
        NewNode    :: pnode(),
        OtherNodes :: [pnode()],
        LastId     :: non_neg_integer(),
        Raw        :: hc_evt:evt_raw(),
        Evt        :: hc_evt:evt(),
        Err        :: hc_evt:evt_err().
raw2evt(OldNode, OtherNodes, LastId, Raw) ->
    NewId = LastId + 1,
    Type  = hc_evt:type(Raw),
    Time  = now_in_sec(),
    case check_rawtype(Type, OldNode) of
        ok ->
            RawNode = hc_evt:cnode(Raw),
            case form_newnode(OldNode, OtherNodes, RawNode, Type) of
                {ok, NewNode} ->
                    {NewNode, hc_evt:new_evt_from_raw(
                        NewId, Time, pnode_name(OldNode), 
                        to_cnode(NewNode), Raw
                    )};
                {error, Error} ->
                    {OldNode, hc_evt:new_evt_err_from_raw(
                        NewId, Time, Error, Raw
                    )}
            end;
        {error, Error} ->
            {OldNode, hc_evt:new_evt_err_from_raw(NewId, Time, Error, Raw)}
    end.

now_in_sec() ->
    calendar:datetime_to_gregorian_seconds(calendar:universal_time()).

%% Check if a raw event's type is valid given the current 
%% state of the node in question.
-spec check_rawtype(Type, Node) -> Result
    when
        Type   :: hc_evt:type(),
        Node   :: pnode() | 'undefined',
        Result :: ok | {error, hc_evt:err_reason()}.
check_rawtype(?EVT_NODE_UP, 'undefined')       -> ok;
check_rawtype(_, 'undefined')                  -> {error, ?EVT_ERR_NOT_FOUND};
check_rawtype(?EVT_NODE_UP, #pnode{con=true})  -> {error, ?EVT_ERR_UP};
check_rawtype(_, #pnode{con=true})             -> ok;
check_rawtype(?EVT_NODE_UP, #pnode{con=false}) -> ok;
check_rawtype(_, #pnode{con=false})            -> {error, ?EVT_ERR_DOWN}.

%% Create/modify the new state of the node. 
%% Check for duplicate names when applicable.
-spec form_newnode(OldNode, OtherNodes, RawNode, Type) -> 
    {ok, NewNode} | {error, Error}
    when
        OldNode    :: pnode() | 'undefined',
        OtherNodes :: [pnode()],
        RawNode    :: hc_node:cnode(),
        Type       :: hc_evt:type(),
        NewNode    :: pnode(),
        Error      :: hc_evt:err_reason().
form_newnode(OldNode, OtherNodes, RawNode, ?EVT_NODE_UP) ->
    Rname = hc_node:name(RawNode),
    Rttd  = hc_node:ttd(RawNode),
    Rprio = hc_node:priority(RawNode),
    Ratt  = hc_node:attribs(RawNode),
    case is_dup_name(RawNode, OtherNodes) of
        true -> 
            {error, ?EVT_ERR_ALREADY_EXISTS};
        false when OldNode =:= 'undefined' -> 
            {ok, new_con_pnode(Rname, Rttd, Rprio, Ratt, OtherNodes)};
        false ->
            {ok, connect_pnode(Rname, Rttd, Rprio, Ratt, OldNode, OtherNodes)}
    end;
form_newnode(OldNode, OtherNodes, RawNode, ?EVT_NODE_EDIT) ->
    case is_dup_name(RawNode, OtherNodes) of
        true -> 
            {error, ?EVT_ERR_ALREADY_EXISTS};
        false -> 
            {ok, edit_pnode(
                hc_node:name(RawNode), 
                hc_node:ttd(RawNode), 
                hc_node:priority(RawNode), 
                OldNode
            )}
    end;
form_newnode(OldNode, _,_, ?EVT_NODE_DOWN) ->
    {ok, disconnect_pnode(OldNode)};
form_newnode(OldNode, _, RawNode, _) ->
    {ok, edit_pnode(hc_node:attribs(RawNode), OldNode)}.

is_dup_name(HcNode, Nodes) ->
    Name = hc_node:name(HcNode),
    lists:any(
        fun (#pnode{name=Pname, con=Con}) -> Con andalso (Pname =:= Name) end,
        Nodes
    ).

%%====================================================================
%% Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

raw2evt_test_() ->
    {'foreach',
     fun setup/0,
     fun cleanup/1,
     [fun from_undef_2_up/1,
      fun from_undef_2_up_dupname/1,
      fun from_undef_2_down/1,
      fun from_undef_2_edit/1,
      fun from_undef_2_edit_dupname/1,
      fun from_undef_2_custom/1,
      fun from_up_2_up/1,
      fun from_up_2_up_diffname/1,
      fun from_up_2_up_dupname/1,
      fun from_up_2_down/1,
      fun from_up_2_edit/1,
      fun from_up_2_edit_diffname/1,
      fun from_up_2_edit_dupname/1,
      fun from_up_2_edit_dupname_disc/1,
      fun from_up_2_custom/1,
      fun from_down_2_up/1,
      fun from_down_2_up_diffname/1,
      fun from_down_2_up_dupname/1,
      fun from_down_2_down/1,
      fun from_down_2_edit/1,
      fun from_down_2_custom/1]}.

setup() ->
    [new_pnode("node-a", 180000, 5, {'name', "node-a"}, true, 1),
     new_pnode("node-b", 180000, 5, {'name', "node-b"}, true, 3),
     new_pnode("node-c", 180000, 5, {'name', "node-c"}, false, 0),
     new_pnode("node-d", 180000, 5, {'name', "node-d"}, true, 2)].

cleanup(_) ->
    ok.

new_raw(RawName, Type, NodeName, Attribs, Ttd, Prio, Con, Rank) ->
    hc_evt:new_raw(
        RawName, Type,
        hc_node:new(NodeName, Attribs, Ttd, Prio, Con, Rank)
    ).

type_orgname(E) ->
    {hc_evt:type(E), hc_evt:org_name(E)}.

type_reason(E) ->
    {hc_evt:type(E), hc_evt:reason(E)}.

from_undef_2_up(Nodes) ->
    {_, Evt} = raw2evt(
        'undefined',
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-e", 
            {'name', "node-e"}, 60000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, 'undefined'}, type_orgname(Evt)),
     ?_assert(hc_node:is_connected(hc_evt:cnode(Evt)))].

from_undef_2_up_dupname(Nodes) ->
    {_, Evt} = raw2evt(
        'undefined',
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-a", 
            {'name', "node-a"}, 60000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, ?EVT_ERR_ALREADY_EXISTS}, type_reason(Evt))].

from_undef_2_down(Nodes) ->
    {_, Evt} = raw2evt(
        'undefined',
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_DOWN, "node-e", 
            {'name', "node-e"}, 60000, 5, false, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_DOWN, ?EVT_ERR_NOT_FOUND}, type_reason(Evt))].

from_undef_2_edit(Nodes) ->
    {_, Evt} = raw2evt(
        'undefined',
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-e", 
            {'name', "node-e"}, 160000, 5, true, 4
        )
    ),
    [?_assertMatch({?EVT_NODE_EDIT, ?EVT_ERR_NOT_FOUND}, type_reason(Evt))].

from_undef_2_edit_dupname(Nodes) ->
    {_, Evt} = raw2evt(
        'undefined',
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-a", 
            {'name', "node-a"}, 160000, 5, true, 4
        )
    ),
    [?_assertMatch({?EVT_NODE_EDIT, ?EVT_ERR_NOT_FOUND}, type_reason(Evt))].

from_undef_2_custom(Nodes) ->
    {_, Evt} = raw2evt(
        'undefined',
        Nodes, 0,
        new_raw(
            "evtid", "custom_evt", "node-e", 
            {'prop', "val"}, 60000, 5, true, 4
        )
    ),
    [?_assertMatch({"custom_evt", ?EVT_ERR_NOT_FOUND}, type_reason(Evt))].

from_up_2_up(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-e", 
            {'name', "node-e"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, ?EVT_ERR_UP}, type_reason(Evt))].

from_up_2_up_diffname(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-f", 
            {'name', "node-f"}, 30000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, ?EVT_ERR_UP}, type_reason(Evt))].

from_up_2_up_dupname(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-a", 
            {'name', "node-a"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, ?EVT_ERR_UP}, type_reason(Evt))].

from_up_2_down(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_DOWN, "node-e", 
            {'name', "node-e"}, 160000, 5, false, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_DOWN, _}, type_orgname(Evt)),
     ?_assertNot(hc_node:is_connected(hc_evt:cnode(Evt)))].

from_up_2_edit(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-e", 
            {'name', "node-e"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_EDIT, _}, type_orgname(Evt)),
     ?_assertEqual("node-e", hc_node:name(hc_evt:cnode(Evt))),
     ?_assert(hc_node:is_connected(hc_evt:cnode(Evt)))].

from_up_2_edit_diffname(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-f", 
            {'name', "node-f"}, 90000, 3, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_EDIT, _}, type_orgname(Evt)),
     ?_assertEqual("node-f", hc_node:name(hc_evt:cnode(Evt))),
     ?_assertEqual({'name', "node-e"}, hc_node:attribs(hc_evt:cnode(Evt))),
     ?_assert(hc_node:is_connected(hc_evt:cnode(Evt)))].

from_up_2_edit_dupname(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-a", 
            {'name', "node-a"}, 90000, 3, true, 0
        )
    ),
    [?_assertMatch(
        {?EVT_NODE_EDIT, ?EVT_ERR_ALREADY_EXISTS}, type_reason(Evt)
    )].

from_up_2_edit_dupname_disc(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-c", 
            {'name', "node-c"}, 90000, 3, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_EDIT, _}, type_orgname(Evt)),
     ?_assertEqual("node-c", hc_node:name(hc_evt:cnode(Evt))),
     ?_assertEqual({'name', "node-e"}, hc_node:attribs(hc_evt:cnode(Evt))),
     ?_assert(hc_node:is_connected(hc_evt:cnode(Evt)))].

from_up_2_custom(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, true, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", "custom_evt", "node-x", 
            {'prop', "val"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({"custom_evt", _}, type_orgname(Evt)),
     ?_assertEqual("node-e", hc_node:name(hc_evt:cnode(Evt))),
     ?_assertEqual({'prop', "val"}, hc_node:attribs(hc_evt:cnode(Evt)))].

from_down_2_up(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, false, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-e", 
            {'name', "node-e"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, _}, type_orgname(Evt)),
     ?_assertEqual("node-e", hc_node:name(hc_evt:cnode(Evt)))].

from_down_2_up_diffname(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, false, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-f", 
            {'name', "node-f"}, 30000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, _}, type_orgname(Evt)),
     ?_assertEqual("node-f", hc_node:name(hc_evt:cnode(Evt)))].

from_down_2_up_dupname(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, false, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_UP, "node-a", 
            {'name', "node-a"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_UP, ?EVT_ERR_ALREADY_EXISTS}, type_reason(Evt))].

from_down_2_down(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, false, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_DOWN, "node-e", 
            {'name', "node-e"}, 160000, 5, false, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_DOWN, ?EVT_ERR_DOWN}, type_reason(Evt))].

from_down_2_edit(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, false, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", ?EVT_NODE_EDIT, "node-c", 
            {'name', "node-c"}, 90000, 3, false, 0
        )
    ),
    [?_assertMatch({?EVT_NODE_EDIT, ?EVT_ERR_DOWN}, type_reason(Evt))].

from_down_2_custom(Nodes) ->
    {_, Evt} = raw2evt(
        new_pnode(
            "node-e", 160000, 5, {'name', "node-e"}, false, 4
        ),
        Nodes, 0,
        new_raw(
            "evtid", "custom_evt", "node-x", 
            {'prop', "val"}, 160000, 5, true, 0
        )
    ),
    [?_assertMatch({"custom_evt", ?EVT_ERR_DOWN}, type_reason(Evt))].

-endif.
