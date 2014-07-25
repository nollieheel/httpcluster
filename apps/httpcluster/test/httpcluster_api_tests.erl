-module(httpcluster_api_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/httpcluster_int.hrl").

api_test_() ->
    {
        "Testing the httpcluster's different APIs",
        {'setup',
         fun app_start/0,
         fun app_stop/1,
         fun (_Data) ->
            [sec_init()]
         end}
    }.

app_start() ->
    {ok, Apps} = httpcluster:start(),
    mocked:start(),
    Apps.

app_stop(Apps) ->
    [application:stop(App) || App <- Apps],
    mocked:stop().

cnodes() ->
    hc_node:list_to_cnodes([
        hc_node:new(atom_to_list(node()), none, 180000, 5),
        hc_node:new("somenode@location", none, 180000, 3),
        hc_node:new("someothernode@location", none, 120000, 6, false, 0)
    ]).

sec_init() ->
    httpcluster_sec:init_cluster(atom_to_list(node()), 60000, cnodes()),
    [?_assert(true)].

%activate() ->
%    Cnodes = hc_node:list_to_cnodes(cnodes_list()),
%    ok = httpcluster:activate("nodeZ", Cnodes, []),
%    {sd, _, Nodes, Evts, _} = sys:get_state('httpcluster'),
%    [?_assertMatch([], Evts),
%     ?_assert(length(Nodes) =:= 3)].

%cases:
% node1, no raw, no sync
% node2, up, no sync
% node3, down, no sync
% node4, edit, no sync
% node5, custom, no sync

% node6, no raw, sync
% node7, up, sync
% node8, down, sync
% node9, edit, sync
% node10, custom, sync

% node2, no raw, no sync
% node2, up, no sync
% node2, edit, no sync
% node2, custom, no sync
% node2, down, no sync

% node7, no raw, sync
% node7, up, sync
% node7, edit, sync
% node7, custom, sync
% node7, down, sync

% node2, no raw, no sync
% node2, edit, no sync
% node2, custom, no sync
% node2, down, no sync
% node2, up, no sync

% node7, no raw, sync
% node7, edit, sync
% node7, custom, sync
% node7, down, sync
% node7, up, sync
%raw_from_node() ->
%    Ping = hc_evt:new_node_ping(
%        "aaa", "somenode@nowhere", "nodeZ", 'undefined', false
%    ),
%    Res = httpcluster:node_ping(Ping),
%    ?log_debug("Ping result: ~p", [Res]),
%    [{"Ping data, no raw, no sync", 
%      ?_assertMatch({ok, _}, Res)}].

% timeout cases:
% ttd, unknown timer
% ttd, known timer, undefined node
% ttd, known timer, down node
% ttd, known timer, up node

% sec module cases:
% TODO
