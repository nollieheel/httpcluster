%%% Exportable definitions.
%%%
%%%

-type mnode_name() :: string().

%% A node in the httpcluster network.
%%   name    - Name of node. (*)(**)
%%   con     - Whether node is officially connected to the network or not.
%%   prio    - Priority when determining who becomes the next primary node. (**)
%%             Lower number = higher priority.
%%   rank    - Determines when this node becomes primary.
%%             0 = implies not connected.
%%   ping    - Ping interval in seconds. (**)
%%             0 = Node uses the default ping value.
%%   ttd     - Time, in seconds, of silence (no pings) before this node is 
%%             considered disconnected. (**)
%%             0 = Node uses the default ttd value.
%%   attribs - User-defined attributes. (*)(**)
%%             MUST BE json-encodeable using mochijson2:encode/1.
%% (*) Initial required information for network nodes list during init.
%% (**) Initial required information for this node during init.
-record(mnode, {
    name = ""    :: mnode_name(),
    con  = false :: boolean(),
    prio = 5     :: non_neg_integer(),
    rank = 0     :: non_neg_integer(),
    ping = 0     :: non_neg_integer(),
    ttd  = 0     :: non_neg_integer(),
    attribs      :: any()
}).
-type mnode() :: #mnode{}.

-define(EVT_NODE_UP,   "node_up").
-define(EVT_NODE_DOWN, "node_down").
-define(EVT_NODE_EDIT, "node_edit").

-type evt_type() :: string(). % ?EVT_NODE_UP | ?EVT_NODE_DOWN | ?EVT_NODE_EDIT

-define(EVT_ERR_DOWN,           'mnode_down').
-define(EVT_ERR_UP,             'mnode_up').
-define(EVT_ERR_NOT_FOUND,      'mnode_not_found').
-define(EVT_ERR_ALREADY_EXISTS, 'mname_already_exists').

-type evt_err_reason() :: ?EVT_ERR_DOWN | ?EVT_ERR_UP | 
                          ?EVT_ERR_NOT_FOUND | ?EVT_ERR_ALREADY_EXISTS.

%% A raw event that needs processing, coming from a pre-given source node.
%%   id   - Used to relate to results.
%%   node - Contains the NEW values of the source node.
-record(evt_raw, {
    id = "" :: string(),
    type    :: evt_type(),
    node    :: mnode()
}).
-type evt_raw() :: #evt_raw{}.

%% An error resulting from processing a raw event.
%%   id   - Used to relate to evt_raws.
%%   time - When processed by primary node (UTC gregorian seconds).
-record(evt_err, {
    id     :: string(),
    type   :: evt_type(),
    time   :: integer(),
    reason :: evt_err_reason()
}).
-type evt_err() :: #evt_err{}.

%% An processed event from the primary node.
%%   id       - Used to relate to evt_raws.
%%   time     - When processed by primary node (UTC gregorian seconds).
%%   org_name - Original name of node in question.
%%   node     - Contains the NEW values of the node in question.
-record(evt, {
    id       :: string(),
    type     :: evt_type(),
    time     :: integer(), 
    org_name :: 'undefined' | mnode_name(),
    node     :: mnode()
}).
-type evt() :: #evt{}.

%% A message sent by a node to primary node. Contains a list of 
%% raw cluster events (all pertaining to the sender node)
%% to be processed by the primary node.
%%  from      - Sender of this msg.
%%  last_evt  - Time of the last event in the secondary node.
%%               0 = means node has never been updated.
%%              -1 = means the node is fully updated. 
%%  get_nodes - If true, the most recent nodes list will be included in 
%%              the response. i.e., the nodes list just before 
%%              these events were applied.
%%  raws      - Ordered last to first.
-record(sec_msg, {
    from              :: mnode_name(),
    last_evt          :: integer(),
    raws              :: [evt_raw()],
    get_nodes = false :: boolean()
}).
-type sec_msg() :: #sec_msg{}.

%% A reply coming from the primary node in response to a #sec_msg{}. 
%% Contains a list of events/errors ready to be processed by the receiving node.
%%  to   - Same value as the #sec_msg{}'s 'from' property.
%%  evts - Ordered last to first.
-record(prim_res, {
    to    :: mnode_name(),
    evts  :: [evt() | evt_err()],
    nodes :: 'undefined' | [mnode()]
}).
-type prim_res() :: #prim_res{}.


%% TODO: DEFUNCT
%% An event, serves as the message sent by node across networks to the 
%% primary node. Revised and sent back after processing. Recorded as history.
%%  type - Type of event. Provided by emitting node.
%%  time - NOT provided by emitting node. Primary node gives it, instead.

%-record(evt, {
%    type     :: evt_type(),
%    time     :: 'undefined' | integer(), % UTC gregorian seconds
%    ident    :: 'undefined' | string(),
%    ref      :: 'undefined' | evt_ref(), % Format: "xxx_N", where N :: integer.
%    %TODO ref has no uses, whatsoever
%    node_old :: 'undefined' | mnode(),
%    node_new :: 'undefined' | mnode()
%}).
%-type evt() :: #evt{}.



