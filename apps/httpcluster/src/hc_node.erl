%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Interface module for network node representation. 
%%%      A node in the cluster, called a `cnode', is known to all
%%%      other nodes. This means all of its values, including 
%%%      the user-defined `attribs', are transmitted to the entire network.
%%%
%%%      Do not manipulate the cnode record directly nor manually store
%%%      them in a custom list/dict/etc. Instead, use this module to do so.
%%%      The {@link empty/0} function can generate an empty nodes container
%%%      as a starting point.

-module(hc_node).

-include("httpcluster_int.hrl").

%% API
-export([
    empty/0,
    list_to_cnodes/1,
    cnodes_to_list/1,
    new/6,
    new/4,
    new/2,
    get_node/2,
    get_first/1,
    take_node/2,
    store_node/2,
    store_node/3,
    store_first/2,
    store_last/2,
    name/1,
    attribs/1,
    priority/1,
    ttd/1,
    ttd/2,
    rank/1,
    is_connected/1,
    disconnect/1
]).

-export_type([
    cnode/0, cnodes/0, name/0, 
    ttd/0, priority/0, rank/0
]).

%%====================================================================
%% Types
%%====================================================================

-type name() :: string().
%% Name of a node. 
%% Can be any string, e.g. "somenode@somehost.com", "awesome_node_2".

-type priority() :: non_neg_integer().
%% Promotion priority. A significant factor when determining who becomes 
%% the next primary node in the cluster. A higher number means greater
%% priority. A zero (0) means the node is exempted from becoming primary.

-type ttd() :: non_neg_integer().
%% Time to die. Milliseconds of silence (no pings) before a node is considered
%% disconnected. Zero (0) means to assume the default system value for TTD.

-type rank() :: non_neg_integer().
%% Promotion ranking. Determines when a node becomes primary.
%% This value is supposed to be given by the primary node.

-record(cnode, {
    name         :: name(),
    attribs      :: term(),
    prio         :: priority(),
    ttd          :: ttd(),
    con  = false :: boolean(),
    rank = 0     :: rank()
}).
-type cnode() :: #cnode{}.
%% A node in the httpcluster network. 

%% Note: Setting cnode() to an opaque type (as it should be) makes Dialyzer
%% bug out and assume get_node/2 returns 'undefined' at all times.
%% Haven't figured out how to get around this yet.

-opaque cnodes() :: {'cnodes', [#cnode{}]}.
%% A container for cnodes.

%%====================================================================
%% API
%%====================================================================

%% @doc Return an empty container for cnodes.
-spec empty() -> Empty
    when Empty :: cnodes().
empty() ->
    cnodes([]).

%% @doc Convert a list of cnodes into a container.
-spec list_to_cnodes(List) -> Cnodes
    when List :: [cnode()], Cnodes :: cnodes().
list_to_cnodes(List) ->
    cnodes(List).

%% @doc Convert a cnodes container into a list.
-spec cnodes_to_list(Cnodes) -> List
    when Cnodes :: cnodes(), List :: [cnode()].
cnodes_to_list(Cnodes) ->
    cnodes(Cnodes).

%% @doc Create a new cnode. `Attribs' is an additional user-defined 
%%      term that can be attached to the cnode. `Con' is a boolean
%%      that determines whether or not the node is connected to the cluster.
-spec new(Name, Attribs, Ttd, Prio, Con, Rank) -> Cnode
    when
        Name  :: name(),    Attribs :: term(), 
        Ttd   :: ttd(),     Prio    :: priority(), 
        Con   :: boolean(), Rank    :: rank(),
        Cnode :: cnode().
new(Name, Attribs, Ttd, Prio, Con, Rank) ->
    #cnode{
        name    = Name,
        attribs = Attribs,
        ttd     = Ttd,
        prio    = Prio,
        con     = Con,
        rank    = Rank
    }.

%% @doc Create a new cnode.
%% @equiv new(Name, Attribs, Ttd, Prio, false, 0)
-spec new(Name, Attribs, Ttd, Prio) -> Cnode
    when
        Name  :: name(), Attribs :: term(), 
        Ttd   :: ttd(),  Prio    :: priority(), 
        Cnode :: cnode().
new(Name, Attribs, Ttd, Prio) ->
    new(Name, Attribs, Ttd, Prio, false, 0).

%% @doc Create a new cnode.
%% @equiv new(Name, Attribs, 0, 3, false, 0)
-spec new(Name, Attribs) -> Cnode
    when 
        Name    :: name(), 
        Attribs :: term(), 
        Cnode   :: cnode().
new(Name, Attribs) ->
    new(Name, Attribs, 0, 3, false, 0).

%% @doc Finds a node in a nodes container.
-spec get_node(Name, Nodes) -> Node
    when 
        Name  :: name(), 
        Nodes :: cnodes(), 
        Node  :: 'undefined' | cnode().
get_node(Name, Nodes) ->
    case lists:keyfind(Name, #cnode.name, cnodes(Nodes)) of
        #cnode{}=Node -> Node;
        false         -> 'undefined'
    end.

%% @doc Take the first node, if it exists, from a nodes container. 
-spec get_first(Nodes) -> Node
    when 
        Nodes :: cnodes(), 
        Node  :: 'undefined' | cnode().
get_first(Nodes) ->
    case cnodes(Nodes) of
        []       -> 'undefined';
        [Node|_] -> Node
    end.

%% @doc Take a node, if it exists, from a nodes container. 
%%      Returns both the node and the other nodes.
-spec take_node(Name, Nodes) -> {Node, OtherNodes}
    when 
        Name       :: name(), 
        Nodes      :: cnodes(), 
        Node       :: 'undefined' | cnode(),
        OtherNodes :: cnodes().
take_node(Name, Nodes) ->
    case lists:keytake(Name, #cnode.name, cnodes(Nodes)) of
        {'value', Node, Nodes1} -> {Node, cnodes(Nodes1)};
        false                   -> {'undefined', Nodes}
    end.

%% @doc Store (overwrite) a cnode in a cnodes container. 
-spec store_node(Node, Nodes1) -> Nodes2
    when
        Node   :: cnode(),
        Nodes1 :: cnodes(),
        Nodes2 :: cnodes().
store_node(#cnode{name=Name}=Node, Nodes) ->
    store_node(Name, Node, Nodes).

%% @doc Store (overwrite) a cnode in a cnodes container. 
%%      Use this version if a potentially different name is to be
%%      used as key.
-spec store_node(Name, Node, Nodes1) -> Nodes2
    when
        Name   :: name(),
        Node   :: cnode(),
        Nodes1 :: cnodes(),
        Nodes2 :: cnodes().
store_node(Name, Node, Nodes) ->
    cnodes(lists:keystore(Name, #cnode.name, cnodes(Nodes), Node)).

%% @doc Store `Node' as the first one in a nodes container, without
%%      duplicating elements.
-spec store_first(Node, Nodes1) -> Nodes2
    when
        Node   :: cnode(),
        Nodes1 :: cnodes(),
        Nodes2 :: cnodes().
store_first(#cnode{name=Name}=Node, Nodes) ->
    {_, Nodes1} = take_node(Name, Nodes),
    cnodes([Node|cnodes(Nodes1)]).

%% @doc Store `Node' as the last one in a nodes container, without
%%      duplicating elements.
-spec store_last(Node, Nodes1) -> Nodes2
    when
        Node   :: cnode(),
        Nodes1 :: cnodes(),
        Nodes2 :: cnodes().
store_last(#cnode{name=Name}=Node, Nodes) ->
    {_, Nodes1} = take_node(Name, Nodes),
    cnodes(lists:reverse([Node|lists:reverse(cnodes(Nodes1))])).

%% @doc Set node's designation to disconnected.
-spec disconnect(Node) -> DiscNode
    when Node :: cnode(), DiscNode :: cnode().
disconnect(#cnode{}=Node) ->
    Node#cnode{con = false, rank = 0}.

%% @doc Check if node is designated as connected to cluster.
-spec is_connected(Node) -> Con
    when Node :: cnode(), Con :: boolean().
is_connected(#cnode{con=Con}) -> 
    Con.

%% @doc Get node name.
-spec name(Node) -> Name
    when Node :: cnode(), Name :: name().
name(#cnode{name=Name}) -> 
    Name.

%% @doc Get node attribs.
-spec attribs(Node) -> Attribs
    when Node :: cnode(), Attribs :: term().
attribs(#cnode{attribs=Attribs}) -> 
    Attribs.

%% @doc Get node priority.
-spec priority(Node) -> Prio
    when Node :: cnode(), Prio :: priority().
priority(#cnode{prio=Prio}) -> 
    Prio.

%% @doc Get node TTD.
-spec ttd(Node) -> Ttd
    when Node :: cnode(), Ttd :: ttd().
ttd(#cnode{ttd=Ttd}) -> 
    Ttd.

%% @doc Alias for `ttd(get_node(Name, Nodes))'.
-spec ttd(Name, Nodes) -> Ttd
    when Name :: name(), Nodes :: cnodes(), Ttd :: ttd().
ttd(Name, Nodes) ->
    #cnode{ttd=Ttd} = get_node(Name, Nodes),
    Ttd.

%% @doc Get node rank.
-spec rank(Node) -> Rank
    when Node :: cnode(), Rank :: rank().
rank(#cnode{rank=Rank}) -> 
    Rank.

%%====================================================================
%% Internal functions
%%====================================================================

%% Making Dialyzer happy
cnodes({'cnodes', Cnodes}) -> Cnodes;
cnodes(Cnodes)             -> {'cnodes', Cnodes}.
