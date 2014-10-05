%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Very limited test cases for httpcluster.

-module(httpcluster_api_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("httpcluster/include/httpcluster.hrl").

%%====================================================================
%% Tests
%%====================================================================

api_test_() ->
    {
        "Testing the httpcluster's different APIs",
        {'setup',
         fun app_start/0,
         fun app_stop/1,
         fun (_Data) ->
            [sec_init_wrong(),
             sec_init_right(),
             no_sync_pings(),
             sync_pings(),
             no_sync_pings_from_up(),
             sync_pings_from_up(),
             no_sync_pings_from_down(),
             sync_pings_from_down(),
             timeout_cases()]
         end}
    }.

app_start() ->
    {ok, Apps} = httpcluster:start(),
    lager:set_loglevel('lager_console_backend', 'none'),
    lager:set_loglevel({'lager_file_backend', "log/console.log"}, 'debug'),
    mocked:start(),
    Apps.

app_stop(Apps) ->
    [application:stop(App) || App <- Apps],
    mocked:stop().

sec_init_wrong() ->
    Rs = httpcluster_sec:init_cluster("none", 60000, cnodes()),
    Rp = httpcluster:hard_activate("none", cnodes(), []),
    prim_external_timeout(make_ref()),
    PEs = httpcluster:get_evts(),
    {"Try to initialize with wrong values",
     [?_assertMatch({error, 'this_node_not_found'}, Rs),
      ?_assertMatch({error, 'this_node_not_found'}, Rp),
      ?_assertMatch(0, length(PEs))]}.

sec_init_right() ->
    httpcluster_sec:init_cluster(atom_to_list(node()), 60000, cnodes()),
    timer:sleep(1000),
    {"Testing the overall cluster init process.",
     [?_assert(httpcluster:is_active()),
      ?_assert(httpcluster_sec:is_connected())]}.

%% node1, no raw, no sync
%% node2, up, no sync
%% node3, down, no sync
%% node4, edit, no sync
%% node5, custom, no sync
no_sync_pings() ->
    Res1 = do_ping(1, 'undefined',    false, "No raw, nosync"),
    Res2 = do_ping(2, ?EVT_NODE_UP,   false, "Up, nosync"),
    Res3 = do_ping(3, ?EVT_NODE_DOWN, false, "Down, nosync"),
    Res4 = do_ping(4, ?EVT_NODE_EDIT, false, "Edit, nosync"),
    Res5 = do_ping(5, "custom event", false, "Custom, nosync"),
    timer:sleep(500),
    {{PNs, PEs}, {SNs, SEs}} = get_nodes_evts(),
    {"Ping with each of all raw cases, all no syncs, from nonexistent nodes.", 
     [?_assertMatch('undefined', hc_evt:node_pong_evt(Res1)),
      ?_assert(hc_evt:is_evt(hc_evt:node_pong_evt(Res2))),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res3))),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res4))),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res5))),
      ?_assertMatch(2, length(PNs)), ?_assertMatch(2, length(SNs)),
      ?_assertMatch(5, length(PEs)), ?_assertMatch(5, length(SEs))]}.

% node6, no raw, sync
% node7, up, sync
% node8, down, sync
% node9, edit, sync
% node10, custom, sync
sync_pings() ->
    Res6  = do_ping(6,  'undefined',    true, "No raw, sync"),
    Res7  = do_ping(7,  ?EVT_NODE_UP,   true, "Up, sync"),
    Res8  = do_ping(8,  ?EVT_NODE_DOWN, true, "Down, sync"),
    Res9  = do_ping(9,  ?EVT_NODE_EDIT, true, "Edit, sync"),
    Res10 = do_ping(10, "custom event", true, "Custom, sync"),
    timer:sleep(500),
    {{_PNs, PEs}, {_SNs, SEs}} = get_nodes_evts(),
    LenSyncNodes = fun(X) -> 
        length(hc_node:cnodes_to_list(hc_evt:node_pong_nodes(X)))
    end,
    {"Ping with each of all raw cases, all syncs, from nonexistent nodes.", 
     [?_assert(LenSyncNodes(Res6) =:= 2), ?_assert(LenSyncNodes(Res7) =:= 2),
      ?_assert(LenSyncNodes(Res8) =:= 3), ?_assert(LenSyncNodes(Res9) =:= 3),
      ?_assert(LenSyncNodes(Res10) =:= 3),
      ?_assertMatch(9, length(PEs)), ?_assertMatch(9, length(SEs))]}.

% node2, no raw, no sync
% node2, up, no sync
% node2, edit, no sync
% node2, custom, no sync
% node2, down, no sync
no_sync_pings_from_up() ->
    Res2a = do_ping(2, 'undefined',    false, "From up, no raw, nosync"),
    Res2b = do_ping(2, ?EVT_NODE_UP,   false, "From up, up, nosync"),
    Res2c = do_ping(2, ?EVT_NODE_EDIT, false, "From up, edit, nosync"),
    Res2d = do_ping(2, "custom event", false, "From up, custom, nosync"),
    Res2e = do_ping(2, ?EVT_NODE_DOWN, false, "From up, down, nosync"),
    timer:sleep(500),
    {{PNs, PEs}, {SNs, SEs}} = get_nodes_evts(),
    LenLiveNodes = fun(Ns) ->
        length([N || N <- Ns, hc_node:is_connected(N)])
    end,
    {"Ping with each of all raw cases, all no syncs, from a connected node.", 
     [?_assertMatch('undefined', hc_evt:node_pong_evt(Res2a)),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res2b))),
      ?_assert(hc_evt:is_evt(hc_evt:node_pong_evt(Res2c))),
      ?_assert(hc_evt:is_evt(hc_evt:node_pong_evt(Res2d))),
      ?_assert(hc_evt:is_evt(hc_evt:node_pong_evt(Res2e))),
      ?_assertMatch(3, length(PNs)), ?_assertMatch(2, LenLiveNodes(SNs)),
      ?_assertMatch(13, length(PEs)), ?_assertMatch(13, length(SEs))]}.

% node7, no raw, sync
% node7, up, sync
% node7, edit, sync
% node7, custom, sync
% node7, down, sync
sync_pings_from_up() ->
    Res7a = do_ping(7, 'undefined',    true, "From up, no raw, sync"),
    Res7b = do_ping(7, ?EVT_NODE_UP,   true, "From up, up, sync"),
    Res7c = do_ping(7, ?EVT_NODE_EDIT, true, "From up, edit, sync"),
    Res7d = do_ping(7, "custom event", true, "From up, custom, sync"),
    Res7e = do_ping(7, ?EVT_NODE_DOWN, true, "From up, down, sync"),
    timer:sleep(500),
    {{_PNs, PEs}, {_SNs, SEs}} = get_nodes_evts(),
    LenSyncNodes = fun(X) -> 
        length(hc_node:cnodes_to_list(hc_evt:node_pong_nodes(X)))
    end,
    {"Ping with each of all raw cases, all syncs, from a connected node.", 
     [?_assert(LenSyncNodes(Res7a) =:= 3), ?_assert(LenSyncNodes(Res7b) =:= 3),
      ?_assert(LenSyncNodes(Res7c) =:= 3), ?_assert(LenSyncNodes(Res7d) =:= 3),
      ?_assert(LenSyncNodes(Res7e) =:= 3),
      ?_assertMatch(17, length(PEs)), ?_assertMatch(17, length(SEs))]}.

% node2, no raw, no sync
% node2, edit, no sync
% node2, custom, no sync
% node2, down, no sync
% node2, up, no sync
no_sync_pings_from_down() ->
    Res2a = do_ping(2, 'undefined',    false, "From down, no raw, nosync"),
    Res2b = do_ping(2, ?EVT_NODE_EDIT, false, "From down, edit, nosync"),
    Res2c = do_ping(2, "custom event", false, "From down, custom, nosync"),
    Res2d = do_ping(2, ?EVT_NODE_DOWN, false, "From down, down, nosync"),
    Res2e = do_ping(2, ?EVT_NODE_UP,   false, "From down, up, nosync"),
    timer:sleep(500),
    {{PNs, _PEs}, {SNs, _SEs}} = get_nodes_evts(),
    LenLiveNodes = fun(Ns) ->
        length([N || N <- Ns, hc_node:is_connected(N)])
    end,
    {"Ping with each of all raw cases, all no syncs, from a disconnected node.", 
     [?_assertMatch('undefined', hc_evt:node_pong_evt(Res2a)),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res2b))),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res2c))),
      ?_assertNot(hc_evt:is_evt(hc_evt:node_pong_evt(Res2d))),
      ?_assert(hc_evt:is_evt(hc_evt:node_pong_evt(Res2e))),
      ?_assertMatch(3, length(PNs)), ?_assertMatch(2, LenLiveNodes(SNs))]}.

% node7, no raw, sync
% node7, edit, sync
% node7, custom, sync
% node7, down, sync
% node7, up, sync
sync_pings_from_down() ->
    Res7a = do_ping(7, 'undefined',    true, "From down, no raw, sync"),
    Res7b = do_ping(7, ?EVT_NODE_EDIT, true, "From down, edit, sync"),
    Res7c = do_ping(7, "custom event", true, "From down, custom, sync"),
    Res7d = do_ping(7, ?EVT_NODE_DOWN, true, "From down, down, sync"),
    Res7e = do_ping(7, ?EVT_NODE_UP,   true, "From down, up, sync"),
    timer:sleep(500),
    {{_PNs, _PEs}, {SNs, SEs}} = get_nodes_evts(),
    LenSyncNodes = fun(X) -> 
        length(hc_node:cnodes_to_list(hc_evt:node_pong_nodes(X)))
    end,
    LenLiveNodes = fun(Ns) ->
        length([N || N <- Ns, hc_node:is_connected(N)])
    end,
    {"Ping with each of all raw cases, all syncs, from a disconnected node.", 
     [?_assert(LenSyncNodes(Res7a) =:= 3), ?_assert(LenSyncNodes(Res7b) =:= 3),
      ?_assert(LenSyncNodes(Res7c) =:= 3), ?_assert(LenSyncNodes(Res7d) =:= 3),
      ?_assert(LenSyncNodes(Res7e) =:= 3), ?_assertMatch(20, length(SEs)),
      ?_assertMatch(3, LenLiveNodes(SNs))]}.

% ttd, unknown timer
% ttd, known timer, undefined node
% ttd, known timer, up node
% ttd, known timer, down node
timeout_cases() ->
    prim_external_timeout(make_ref()),
    prim_internal_timeout(make_ref()),

    [E1|_] = httpcluster:get_evts(),
    Id = get_prim_local_id(nodename(7)),

    prim_external_timeout(Id),
    timer:sleep(500),
    prim_internal_timeout(Id),
    timer:sleep(500),

    {{_PNs, [E2|[E3|_]]}, {SNs, [E4|[E5|_]]}} = get_nodes_evts(),
    LenLiveNodes = fun(Ns) ->
        length([N || N <- Ns, hc_node:is_connected(N)])
    end,
    {"TTD timeout cases for httpcluster module.",
     [?_assertMatch(25, hc_evt:id(E1)), 
      ?_assertMatch(27, hc_evt:id(E2)), ?_assertMatch(26, hc_evt:id(E3)),
      ?_assertMatch(27, hc_evt:id(E4)), ?_assertMatch(26, hc_evt:id(E5)),
      ?_assertMatch(?EVT_NODE_DOWN, hc_evt:type(E3)),
      ?_assertNot(hc_evt:is_evt(E2)),
      ?_assertMatch(2, LenLiveNodes(SNs))]}.

% TODO: httpcluster_sec module tests.

%%====================================================================
%% Internal functions
%%====================================================================

cnodes() ->
    hc_node:list_to_cnodes([
        hc_node:new(atom_to_list(node()), none, 180000, 5),
        hc_node:new("somenode@location", none, 180000, 3),
        hc_node:new("someothernode@location", none, 120000, 6, false, 0)
    ]).

do_ping(NodeNum, RawType, Sync, Str) ->
    Raw = case RawType of
        'undefined' -> 'undefined';
        _           -> raw(RawType, cnode(NodeNum))
    end,
    Res = do_ping(NodeNum, Raw, Sync),
    lager:debug("TEST " ++ Str ++ " response: ~p", [Res]),
    Res.

do_ping(NodeNum, Raw, Sync) ->
    {ok, Res} = httpcluster:node_ping(ping(NodeNum, Raw, Sync)),
    Res.

nodename(Num) ->
    lists:concat(["node", Num, "@test"]).

ping(NodeNum, Raw, Sync) ->
    Id = hc_evt:random_str(8),
    From = nodename(NodeNum),
    To = atom_to_list(node()),
    hc_evt:new_node_ping(Id, From, To, Raw, Sync).

cnode(NodeNum) ->
    hc_node:new(nodename(NodeNum), none, 180000, 5, false, 0).

raw(Type, Node) ->
    Id = hc_evt:random_str(8),
    hc_evt:new_raw(Id, Type, Node).

get_nodes_evts() ->
    {{httpcluster:get_nodes(), httpcluster:get_evts()},
     {hc_node:cnodes_to_list(httpcluster_sec:get_nodes()),
      httpcluster_sec:get_evts()}}.

get_prim_local_id(Name) ->
    {sd, _,_, Ns, _,_} = sys:get_state(httpcluster),
    element(2, lists:keyfind(Name, 3, Ns)).

prim_external_timeout(Id) ->
    hc_timer:sec_disc_on(Id, 0, hc_timer:empty()),
    forward_timeout2hc().

prim_internal_timeout(Id) ->
    {sd, _,_,_,_, Ts} = sys:get_state(httpcluster),
    Ts1 = hc_timer:sec_disc_on(Id, 0, Ts),
    Fun = fun({sd, IId, TId, Ns, Es, _}) -> {sd, IId, TId, Ns, Es, Ts1} end,
    sys:replace_state(httpcluster, Fun),
    forward_timeout2hc().

forward_timeout2hc() ->
    receive
        {'$ttd_timeout', _}=Msg -> httpcluster ! Msg
    end.
