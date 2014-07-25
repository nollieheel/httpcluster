%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Interface module for network events and messages.

-module(hc_evt).

-include("httpcluster_int.hrl").

%% API
-export([
    new_raw/3,
    new_evt_from_raw/5,
    new_evt_err_from_raw/4,
    new_node_ping/5,
    new_node_pong/5,
    new_node_reply/4,
    id/1,
    name/1,
    type/1,
    org_name/1,
    cnode/1,
    reason/1,
    node_com_id/1,
    node_com_source/1,
    node_com_destination/1,
    node_ping_raw/1,
    node_ping_sync/1,
    node_pong_evt/1,
    node_pong_nodes/1,
    node_reply_val/1,
    truncate_evts/1,
    is_evt/1,
    is_node_pong/1,
    is_node_reply/1,
    random_str/1
]).

-export_type([
    id/0, type/0, err_reason/0, 
    evt_raw/0, evt/0, evt_err/0,
    node_ping/0, node_msg/0,
    node_pong/0, node_reply/0
]).

%%====================================================================
%% Types
%%====================================================================

-type type() :: string().
%% The type of {@link evt_raw()}, {@link evt()}, or {@link evt_err()}.

-type id() :: pos_integer().
%% After processing a raw event, the primary node assigns an 
%% incrementing integer to the result, which can be used by the secondary
%% nodes to make sure they receive the results in proper order.

-type err_reason() :: atom().
%% Error type that can result from processing an event. See 
%% {@link evt_err_from_raw/4} for the preset values.

-record(evt_raw, {
    name :: string(),
    type :: type(),
    node :: hc_node:cnode()
}).
-opaque evt_raw() :: #evt_raw{}.
%% A raw event that needs processing, coming from a pre-given source node. 

-record(evt, {
    id       :: id(),
    name     :: string(),
    type     :: type(),
    time     :: integer(), % when processed by prim node (UTC gregorian seconds)
    org_name :: 'undefined' | hc_node:name(),
    node     :: hc_node:cnode()
}).
-opaque evt() :: #evt{}.
%% A successfully-processed event concerning a particular node. It contains
%% the new node values, as well as that node's original name.

-record(evt_err, {
    id     :: id(),
    name   :: string(),
    type   :: type(),
    time   :: integer(), % when processed by prim node (UTC gregorian seconds)
    reason :: err_reason()
}).
-opaque evt_err() :: #evt_err{}.
%% An error result from processing a raw event.

-record(node_ping, {
    id   :: string(),
    from :: hc_node:name(),
    to   :: hc_node:name(),
    raw  :: 'undefined' | evt_raw(),
    sync :: boolean()
}).
-opaque node_ping() :: #node_ping{}.
%% A health check (ping) sent by a node to the primary node.
%% Can also contain a raw event and a flag to sync the nodes list. If the latter
%% flag is true, the reply will include the most current nodes list, i.e.
%% the list just before this ping's raw event (if present) was processed.
%%
%% The reponse can either be a {@link node_pong()} or {@link node_reply()}.

-record(node_msg, {
    id   :: string(),
    from :: hc_node:name(),
    to   :: hc_node:name(),
    val  :: term()
}).
-opaque node_msg() :: #node_msg{}.
%% A general message sent by one node to another.

-record(node_pong, {
    id    :: string(),
    from  :: hc_node:name(),
    to    :: hc_node:name(),
    evt   :: 'undefined' | evt() | evt_err(),
    nodes :: 'undefined' | hc_node:cnodes()
}).
-opaque node_pong() :: #node_pong{}.
%% A message from the primary node sent as either a reply for a
%% {@link node_ping()}, or as a routine update message to all secondary nodes. 

-record(node_reply, {
    id   :: string(),
    from :: hc_node:name(),
    to   :: hc_node:name(),
    val  :: term()
}).
-opaque node_reply() :: #node_reply{}.
%% A reply coming from a node in response to either a {@link node_ping()} or
%% {@link node_msg()}. Contains a `val' property that can be an arbitrary term,
%% such as: `{redir, Node}', `{error, Any}', etc.

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new {@link evt_raw()}. `EvtName' is a local dedup identifier
%%      for the raw evt. `Node' is an {@link hc_node:cnode()} that contains
%%      the <em>new</em> values for the source node in relation to the evt type.
%%
%%      Three built-in event types are:
%%      <dl>
%%      <dt>`"node_up"'</dt>
%%      <dd>Turns the node's connection to true. Also sets new values 
%%      (overwrite) for the node Name, Attribs, Priority, and/or TTD.</dd>
%%
%%      <dt>`"node_down"'</dt>
%%      <dd>Turns the node's connection to false.</dd>
%%
%%      <dt>`"node_edit"'</dt>
%%      <dd>Modifies the values for node Name, Priority, and/or TTD.</dd>
%%      </dl>
%%
%%      Custom event types will modify the node's `Attribs' value.
-spec new_raw(EvtName, Type, Node) -> Raw
    when 
        EvtName :: string(),
        Type    :: type(),
        Node    :: hc_node:cnode(),
        Raw     :: evt_raw().
new_raw(EvtName, Type, Node) ->
    #evt_raw{name = EvtName, type = Type, node = Node}.

%% @doc Create an {@link evt()} based on an {@link evt_raw()}. This would mean 
%%      the {@link evt_raw()} was successfully processed by the primary node 
%%      and is ready to be integrated into the cluster.
%%
%%      Arguments are:
%%      <dl>
%%      <dt>`Id'</dt>
%%      <dd>Primary-node-generated value that determines evt execution 
%%      order.</dd>
%%
%%      <dt>`Time'</dt>
%%      <dd>When the evt has been processed.</dd>
%%
%%      <dt>`OrgName'</dt>
%%      <dd>The original name of the cluster node affected by the evt.
%%      This is important during `?EVT_NODE_EDIT' events where the node's
%%      name can be modified.</dd>
%%
%%      <dt>`NewNode'</dt>
%%      <dd>The cluster node containing the new and validated values
%%      of the subject node.</dd>
%%
%%      <dt>`Raw'</dt>
%%      <dd>The {@link evt_raw()} this evt is based from.</dd>
%%      </dl>
-spec new_evt_from_raw(Id, Time, OrgName, NewNode, Raw) -> Evt
    when
        Id      :: id(), 
        Time    :: non_neg_integer(), 
        OrgName :: 'undefined' | hc_node:name(), 
        NewNode :: hc_node:cnode(), 
        Raw     :: evt_raw(),
        Evt     :: evt().
new_evt_from_raw(Id, Time, OrgName, NewNode, Raw) ->
    #evt{
        id       = Id,
        name     = Raw#evt_raw.name,
        type     = Raw#evt_raw.type,
        time     = Time,
        org_name = OrgName,
        node     = NewNode
    }.

%% @doc Create an {@link evt_err()} based on an {@link evt_raw()}. This  
%%      should be used if processing the {@link evt_raw()} failed with one
%%      of the following reasons:
%%
%%      <dl>
%%      <dt>`?EVT_ERR_DOWN'</dt>
%%      <dd>Any event type other than `?EVT_NODE_UP' was attempted on a
%%      disconnected node.</dd>
%%
%%      <dt>`?EVT_ERR_UP'</dt>
%%      <dd>An `?EVT_NODE_UP' was attempted on an already connected node.</dd>
%%
%%      <dt>`?EVT_ERR_NOT_FOUND'</dt>
%%      <dd>Any event type other than `?EVT_NODE_UP' was attempted on a
%%      non-existent node.</dd>
%%
%%      <dt>`?EVT_ERR_ALREADY_EXISTS'</dt>
%%      <dd>An event of type `?EVT_NODE_UP' or `?EVT_NODE_EDIT' failed
%%      because another connected node of the same name already exists.</dd>
%%      </dl>
%%
%%      The arguments of this function are as follows:
%%      <dl>
%%      <dt>`Id'</dt>
%%      <dd>Primary-node-generated value that determines evt_err order.</dd>
%%
%%      <dt>`Time'</dt>
%%      <dd>When the evt_err has been processed.</dd>
%%
%%      <dt>`Reason'</dt>
%%      <dd>See the possible error reasons above.</dd>
%%
%%      <dt>`Raw'</dt>
%%      <dd>The {@link evt_raw()} this evt_err is based from.</dd>
%%      </dl>
-spec new_evt_err_from_raw(Id, Time, Reason, Raw) -> Err
    when
        Id     :: id(), 
        Time   :: non_neg_integer(), 
        Reason :: err_reason(),
        Raw    :: evt_raw(),
        Err    :: evt_err().
new_evt_err_from_raw(Id, Time, Reason, Raw) ->
    #evt_err{
        id     = Id,
        name   = Raw#evt_raw.name,
        type   = Raw#evt_raw.type,
        time   = Time,
        reason = Reason
    }.

%% @doc Create a new {@link node_ping()} value. `Id' is an arbitrary string
%%      that may be used to match with the reply. `Raw' is an optional 
%%      {@link evt_raw()}, and `Sync' is a flag to include the most recent
%%      nodes list in the response.
-spec new_node_ping(Id, From, To, Raw, Sync) -> NodePing
    when
        Id       :: string(), 
        From     :: hc_node:name(), 
        To       :: hc_node:name(), 
        Raw      :: 'undefined' | evt_raw(), 
        Sync     :: boolean(),
        NodePing :: node_ping().
new_node_ping(Id, From, To, Raw, Sync) ->
    #node_ping{id = Id, from = From, to = To, raw = Raw, sync = Sync}.

%% @doc Create a new {@link node_pong()} value.
-spec new_node_pong(Id, From, To, Evt, Nodes) -> NodePong
    when
        Id       :: string(), 
        From     :: hc_node:name(), 
        To       :: hc_node:name(), 
        Evt      :: 'undefined' | evt() | evt_err(), 
        Nodes    :: 'undefined' | hc_node:cnodes(),
        NodePong :: node_pong().
new_node_pong(Id, From, To, Evt, Nodes) ->
    #node_pong{id = Id, from = From, to = To, evt = Evt, nodes = Nodes}.

%% @doc Create a new {@link node_reply()} value in response to a 
%%      {@link node_ping()}.
-spec new_node_reply(Id, From, To, Val) -> NodeReply
    when
        Id        :: string(), 
        From      :: hc_node:name(), 
        To        :: hc_node:name(), 
        Val       :: term(), 
        NodeReply :: node_reply().
new_node_reply(Id, From, To, Val) ->
    #node_reply{id = Id, from = From, to = To, val = Val}.

%% @doc Get the id of either {@link evt()} or {@link evt_err()}.
-spec id(Evt) -> Id
    when Evt :: evt() | evt_err(), Id :: id().
id(#evt{id=Id})     -> Id;
id(#evt_err{id=Id}) -> Id.

%% @doc Get the name of {@link evt_raw()}, {@link evt()}, or {@link evt_err()}.
-spec name(Evt) -> Name
    when Evt :: evt_raw() | evt() | evt_err(), Name :: string().
name(#evt_raw{name=Name}) -> Name;
name(#evt{name=Name})     -> Name;
name(#evt_err{name=Name}) -> Name.

%% @doc Get the type of {@link evt_raw()}, {@link evt()}, or {@link evt_err()}.
-spec type(Evt) -> Type
    when Evt :: evt_raw() | evt() | evt_err(), Type :: type().
type(#evt_raw{type=Type}) -> Type;
type(#evt{type=Type})     -> Type;
type(#evt_err{type=Type}) -> Type.

%% @doc Get the original name of the event's subject node.
-spec org_name(Evt) -> OrgName
    when Evt :: evt(), OrgName :: 'undefined' | hc_node:name().
org_name(#evt{org_name=OrgName}) ->
    OrgName.

%% @doc Get the node value of either an {@link evt_raw()} or {@link evt()}.
-spec cnode(Evt) -> Cnode
    when Evt :: evt_raw() | evt(), Cnode :: hc_node:cnode().
cnode(#evt{node=Cnode})     -> Cnode;
cnode(#evt_raw{node=Cnode}) -> Cnode.

%% @doc Get the `reason' value of an {@link evt_err()}.
-spec reason(Err) -> Reason
    when Err :: evt_err(), Reason :: err_reason().
reason(#evt_err{reason=Reason}) ->
    Reason.

%% @doc Get the `id' of a node communication.
-spec node_com_id(NodeCom) -> Id
    when 
        NodeCom :: node_ping(),
        Id      :: string().
node_com_id(#node_ping{id=Id}) ->
    Id.

%% @doc Get the `from' value of a node communication.
-spec node_com_source(NodeCom) -> From
    when 
        NodeCom :: node_ping() | node_pong() | node_reply(),
        From    :: hc_node:name().
node_com_source(#node_ping{from=From})  -> From;
node_com_source(#node_pong{from=From})  -> From;
node_com_source(#node_reply{from=From}) -> From.

%% @doc Get the `to' value of a node communication.
-spec node_com_destination(NodeCom) -> To
    when 
        NodeCom :: node_ping() | node_pong() | node_reply(),
        To      :: hc_node:name().
node_com_destination(#node_ping{to=To})  -> To;
node_com_destination(#node_pong{to=To})  -> To;
node_com_destination(#node_reply{to=To}) -> To.

%% @doc Get the raw event in a {@link node_ping()}.
-spec node_ping_raw(NodePing) -> Raw
    when NodePing :: node_ping(), Raw :: 'undefined' | evt_raw().
node_ping_raw(#node_ping{raw=Raw}) ->
    Raw.

%% @doc Get the `sync' boolean in a {@link node_ping()}.
-spec node_ping_sync(NodePing) -> Sync
    when NodePing :: node_ping(), Sync :: boolean().
node_ping_sync(#node_ping{sync=Sync}) ->
    Sync.

%% @doc Get the `evt' value of a {@link node_pong()}.
-spec node_pong_evt(NodePong) -> Evt
    when NodePong :: node_pong(), Evt :: 'undefined' | evt() | evt_err().
node_pong_evt(#node_pong{evt=Evt}) ->
    Evt.

%% @doc Get the `nodes' value of a {@link node_pong()}.
-spec node_pong_nodes(NodePong) -> Nodes
    when NodePong :: node_pong(), Nodes :: 'undefined' | hc_node:cnodes().
node_pong_nodes(#node_pong{nodes=Nodes}) ->
    Nodes.

%% @doc Get the `val' value of a {@link node_reply()}.
-spec node_reply_val(NodeReply) -> Val
    when NodeReply :: node_reply(), Val :: term().
node_reply_val(#node_reply{val=Val}) ->
    Val.

%% @doc Shorten an events list according to app var `evts_history_len'.
-spec truncate_evts(Evts) -> Evts1
    when Evts :: [evt() | evt_err()], Evts1 :: [evt() | evt_err()].
truncate_evts(Evts) ->
    lists:sublist(Evts, ?get_env(?HIST_LEN)).

%% @doc Check if something is either an evt or an evt_err. 
-spec is_evt(EvtOrErr) -> IsEvt
    when EvtOrErr :: evt() | evt_err(), IsEvt :: boolean().
is_evt(#evt{})     -> true;
is_evt(#evt_err{}) -> false.

%% @doc Check if something is a {@link node_pong()} or not.
-spec is_node_pong(Term) -> IsNodePong
    when Term :: any(), IsNodePong :: boolean().
is_node_pong(#node_pong{}) -> true;
is_node_pong(_)            -> false.

%% @doc Check if something is a {@link node_reply()} or not.
-spec is_node_reply(Term) -> IsNodeReply
    when Term :: any(), IsNodeReply :: boolean().
is_node_reply(#node_reply{}) -> true;
is_node_reply(_)             -> false.

%% @doc A utility function to help generate random alphanumeric strings.
-spec random_str(Len) -> Str
    when Len :: non_neg_integer(), Str :: list().
random_str(0)   -> "";
random_str(Len) -> [random_char()|random_str(Len - 1)].

random_char() ->
    to_rand_char(random:uniform(62)).

to_rand_char(N) when N >= 37 -> N + 60;
to_rand_char(N) when N >= 11 -> N + 54;
to_rand_char(N)              -> N + 47.
