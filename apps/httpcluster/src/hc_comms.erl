%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Behavior module for `hc_comms'. See each function's source 
%%%      documentation for details.

-module(hc_comms).

%%====================================================================
%% Behavior callbacks
%%====================================================================

%% A ping is a message from a secondary node to the primary node.
%% This is where the ping message can be modified/serialized. The return
%% value will become the first argument to ping_to_node/4.
%%
%% `NodePing' is the actual ping message. `FromNode' is the source node.
%% `OtherNodes' is a list of other nodes in the cluster, all of which 
%% are _not_ necessarily up.
%%
%% The source node is usually this node (self), but not always.
-callback 'create_pingdata'(NodePing, FromNode, OtherNodes) -> Data
    when
        NodePing   :: hc_evt:node_ping(),
        FromNode   :: hc_node:cnode(),
        OtherNodes :: [hc_node:cnode()],
        Data       :: term().

%% The actual message-sending function. `ToNode' is the destination,
%% `FromNode' is the source.
%%
%% It is recommended to make this return immediately. After the message has
%% been relayed and the reply obtained, format it and send back to the 
%% httpcluster using the call:
%%
%%   httpcluster_sec:ping_reply(PingRef, PingReply)
%%
%% where PingReply :: hc_evt:node_pong() | hc_evt:node_reply() | {error, any()}.
-callback 'ping_to_node'(Data, FromNode, ToNode, PingRef) -> _
    when
        Data     :: term(),
        FromNode :: hc_node:cnode(),
        ToNode   :: hc_node:cnode(),
        PingRef  :: reference().

%% Much like create_pingdata/3, only the data created here are sent from 
%% a primary node back to secondary nodes. Note that a non-primary node
%% might still need to call this function, in which case `FromNode' will
%% have only skeleton values and `OtherNode' will be empty.
%%
%% The return value will become the first argument to pong_to_node/3.
-callback 'create_pongdata'(NodePongMsg, FromNode, OtherNodes) -> Data
    when
        NodePongMsg :: hc_evt:node_pong() | hc_evt:node_reply(),
        FromNode    :: hc_node:cnode(),
        OtherNodes  :: [hc_node:cnode()],
        Data        :: term().

%% The actual message-sending function for a pong data cast. `ToNode' is the
%% destination, `FromNode' is the source.
%%
%% Similar to ping_to_node/4, but there is no need to send the replies back
%% to httpcluster.
-callback 'pong_to_node'(Data, FromNode, ToNode) -> _
    when
        Data     :: term(),
        FromNode :: hc_node:cnode(),
        ToNode   :: hc_node:cnode().

%% For every cluster event that gets acknowledged by the node, this function
%% gets called. The event type and the old and new values of the 
%% node in question are provided. The current cluster information is also
%% given as a list of nodes.
%%
%% This is the place where one might implement some sort of process subscription
%% and each event notification gets broadcasted to those subscribers.
%% I didn't have the time to implement that built-in to httpcluster.
-callback 'cluster_event'(EvtType, OldNode, NewNode, Nodes) -> _
    when
        EvtType :: hc_evt:type(),
        OldNode :: hc_node:cnode(),
        NewNode :: hc_node:cnode(),
        Nodes   :: [hc_node:cnode()].
