%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Default client communication module.
%%%      Uses normal erlang messaging system with epmd.

-module(httpcluster_coms).
-behaviour(hc_comms).

-include("../src/httpcluster_int.hrl").

%% hc_comms callbacks
-export([create_pingdata/3, create_pongdata/3,
         ping_to_node/4, pong_to_node/3, cluster_event/4]).

%%====================================================================
%% hc_comms callbacks
%%====================================================================

create_pingdata(NodePing, FromNode, OtherNodes) ->
    ?log_debug(
        "Fun called: create_pingdata/3~n"
        "NodePing: ~p~n"
        "FromNode: ~p~n"
        "OtherNodes: ~p",
        [NodePing, FromNode, OtherNodes]
    ),
    NodePing.

ping_to_node(Data, FromNode, ToNode, PingRef) ->
    ?log_debug(
        "Fun called: ping_to_node/4~n"
        "Data: ~p~n"
        "FromNode: ~p~n"
        "ToNode: ~p~n"
        "PingRef: ~p",
        [Data, FromNode, ToNode, PingRef]
    ),
    Reply = case rpc:call(name2atom(ToNode), httpcluster, node_ping, [Data]) of
        {ok, Result}      -> Result;
        {error, _}=Error  -> Error;
        {badrpc, _}=Error -> {error, Error};
        Other             -> Other
    end,
    httpcluster_sec:ping_reply(PingRef, Reply).

create_pongdata(NodePongMsg, FromNode, OtherNodes) ->
    ?log_debug(
        "Fun called: create_pongdata/3~n"
        "NodePongMsg: ~p~n"
        "FromNode: ~p~n"
        "OtherNodes: ~p",
        [NodePongMsg, FromNode, OtherNodes]
    ),
    NodePongMsg.

pong_to_node(Data, FromNode, ToNode) ->
    ?log_debug(
        "Fun called: pong_to_node/3~n"
        "Data: ~p~n"
        "FromNode: ~p~n"
        "ToNode: ~p",
        [Data, FromNode, ToNode]
    ),
    rpc:call(name2atom(ToNode), httpcluster_sec, pong_cast, [Data]).

cluster_event(EvtType, OldNode, NewNode, Nodes) ->
    ?log_debug(
        "Fun called: cluster_event/4~n"
        "EvtType: ~p~n"
        "OldNode: ~p~n"
        "NewNode: ~p~n"
        "Nodes: ~p~n",
        [EvtType, OldNode, NewNode, Nodes]
    ),
    ok.

name2atom(Hcnode) ->
    list_to_atom(hc_node:name(Hcnode)).
