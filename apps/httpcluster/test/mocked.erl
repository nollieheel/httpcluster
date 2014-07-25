-module(mocked).

-include("../src/httpcluster_int.hrl").

-export([start/0, stop/0]).

-define(COM, 'comms_mod').

start() ->
    app_start(),
    comms_mod_start(),
    ok.

stop() ->
    comms_mod_stop().

app_start() ->
    application:ensure_all_started('meck').

comms_mod_start() ->
    meck:new(?COM, ['non_strict']),
    meck:expect(?COM, 'create_pingdata',
        fun(NodePing, FromNode, OtherNodes) ->
            ?log_debug(
                "Fun called: create_pingdata/3~n"
                "NodePing: ~p~n"
                "FromNode: ~p~n"
                "OtherNodes: ~p",
                [NodePing, FromNode, OtherNodes]
            ),
            NodePing
        end
    ),
    meck:expect(?COM, 'ping_to_node',
        fun(Data, FromNode, ToNode, PingRef) ->
            ?log_debug(
                "Fun called: ping_to_node/4~n"
                "Data: ~p~n"
                "FromNode: ~p~n"
                "ToNode: ~p~n"
                "PingRef: ~p",
                [Data, FromNode, ToNode, PingRef]
            ),
            Reply = case rpc:call(
                name2atom(ToNode), httpcluster, node_ping, [Data]
            ) of
                {ok, Result}      -> Result;
                {error, _}=Error  -> Error;
                {badrpc, _}=Error -> {error, Error};
                Other             -> Other
            end,
            httpcluster_sec:ping_reply(PingRef, Reply)
        end
    ),
    meck:expect(?COM, 'create_pongdata',
        fun(NodePongMsg, FromNode, OtherNodes) ->
            ?log_debug(
                "Fun called: create_pongdata/3~n"
                "NodePongMsg: ~p~n"
                "FromNode: ~p~n"
                "OtherNodes: ~p",
                [NodePongMsg, FromNode, OtherNodes]
            ),
            NodePongMsg
        end
    ),
    meck:expect(?COM, 'pong_to_node',
        fun(Data, FromNode, ToNode) ->
            ?log_debug(
                "Fun called: pong_to_node/3~n"
                "Data: ~p~n"
                "FromNode: ~p~n"
                "ToNode: ~p",
                [Data, FromNode, ToNode]
            ),
            rpc:call(
                name2atom(ToNode), httpcluster_sec, pong_cast, [Data]
            )
        end
    ),
    meck:expect(?COM, 'cluster_event',
        fun(EvtType, OldNode, NewNode, Nodes) ->
            ?log_debug(
                "Fun called: cluster_event/4"
                "EvtType: ~p~n"
                "OldNode: ~p~n"
                "NewNode: ~p~n"
                "Nodes: ~p~n",
                [EvtType, OldNode, NewNode, Nodes]
            ),
            ok
        end
    ),
    application:set_env('httpcluster', ?MOD_COMS, ?COM).

name2atom(Hcnode) ->
    list_to_atom(hc_node:name(Hcnode)).

comms_mod_stop() ->
    meck:unload(?COM).
