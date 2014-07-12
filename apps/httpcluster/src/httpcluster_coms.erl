%%% Default handler module for node communication functions.
%%%
%%%
-module(httpcluster_coms).

-include("httpcluster.hrl").

%% Default handlers
-export([
    create_initdata/2,
    create_pingdata/3,
    init_to_node/3,
    ping_to_node/3,
    translate_init_reply/2,
    translate_ping_reply/2
]).


%%====================================================================
%% Default function handlers
%%====================================================================

%% JSON translation for a mnode():
%%         {
%%           "mname"  : "nodex",
%%           "con"    : True,
%%           "prio"   : 1,
%%           "rank"   : 3,
%%           "ping"   : 300,
%%           "ttd"    : 600,
%%           "attribs": ["some", "terms", "here"]
%%         }
%% Erlang proplist translation for a mnode():
%%         [
%%           {"mname", "nodex"},
%%           {"con", true},
%%           {"prio", 1},
%%           {"rank", 3},
%%           {"ping", 300},
%%           {"ttd", 600},
%%           {"attribs", [...]}
%%         ]

-spec create_initdata(evt(), {'struct', [{string(), term()}]}) -> 
    {'struct', [{string(), term()}]}.
%% @doc Used to form the initial data sent when connecting to network.
%%      NodeupEvtStruct is the mochijson2 struct term equivalent 
%%      of the NodeupEvt record.
%%
%%      Must return a json-encodeable (using {@link mochijson2:encode/1}) term.
'create_initdata'(_NodeupEvt, NodeupEvtStruct) ->
    NodeupEvtStruct.


%THIS:
% No more implicit JSON.
'create_initdata'(#sec_msg{get_nodes=true}=Msg, _ThisNode, _OtherNodes) ->
    % Encode Msg here with mochijson2:encode or something.
    Msg.

'create_pingdata'(#sec_msg{}=Msg, _ThisNode, _OtherNodes) ->
    % Encode Msg here with mochijson2:encode or something.
    % returned val will be the first argument in ping_to_node/3
    Msg.

-spec ping_to_node(term(), mnode(), mnode()) -> ok.
% TODO this should be a cast into this gen_server module so that it will return right away. (or call with an immediate return)
% The gen_server should then call httpcluster_sec:ping_reply() and give it either of the following results:
% {DestNode, {ok, prim_res()} | {'redir', mnode()} | {error, any()}}
'ping_to_node'(_Data, _ThisNode, _DestNode) ->
    ok.



-spec create_pingdata(mnode(), evt_ref() | 'undefined', [{string(), term()}]) ->
    [{string(), term()}].
%% @doc Used to form the data sent during a routing secondary node ping.
%%      Proplist arg is:
%%       [
%%        {"last_ref", "refx" | undefined},
%%        {"node", <proplist mnode>}
%%       ]
%%
%-------------------------------------------------
%%      Must return a json-encodeable (using {@link mochijson2:encode/1}) term.
'create_pingdata'(_ThisNode, _LastHistRef, Proplist) ->
    Proplist.


-spec init_to_node(mnode(), mnode(), term()) -> 
    {ok, string()} | {error, any()}.
%% @doc Attempt to connect to network by communicating to destination node.
%%      Return the raw json response, or an error.
'init_to_node'(_ThisNode, _DestNode, _BinData) ->
    {error, 'unreachable'}.


-spec ping_to_node(mnode(), mnode(), term()) ->
    {ok, string()} | {error, any()}.
%% @doc Ping a destination node as a health check-in.
%%      Return the raw json response, or an error.
'ping_to_node'(_ThisNode, _DestNode, _BinData) ->
    {error, 'unreachable'}.


-spec translate_init_reply(mnode(), term()) -> 
    {ok, {[mnode()], [evt()]}} | {'redir', mnode()} | {error, any()}.
%% @doc Should return either a list of mnodes with full details, 
%%      a new remote mnode indicating a redirect, or an error.
%%
%%      As for this result handler, 'init_to_node' should return either
%%      of the following JSON formats on a 200 HTTP result:
%%        {
%%         "result" : "ok",
%%         "nodes"  : [<JSON mnode>, <JSON mnode>, ...],
%TODO the "nodes" reply here should be the networked nodes BEFORE this node connected. i.e. before the NODE_UP event happened. So the "evts" should only contain 1 event -- the NODE_UP event.
%%         "evts"   : [<JSON evt> | <JSON evt_err>]
%% TODO evts should be ORDERED. the same order as the original evts sent
%%        }
%%
%%        {
%%         "result": "redir",
%%         "node"  : <JSON mnode>
%%        }
%%
%%        {
%%         "result": "error",
%%         "reason": "something"
%%        }
'translate_init_reply'(_ThisNode, {'struct', Ls}=_JsonDecoded) ->
    case prop_val(<<"result">>, Ls) of
        <<"error">> -> 
            {error, prop_val(<<"reason">>, Ls)};
        <<"redir">> -> 
            {'redir', httpcluster:json2mnode(prop_val(<<"node">>, Ls))};
        <<"ok">> -> 
            Nodes = lists:map(fun httpcluster:json2mnode/1, 
                              prop_val(<<"nodes">>, Ls)),
            Evts = lists:map(fun httpcluster:json2evt/1, 
                             prop_val(<<"evts">>, Ls)),
            {ok, {Nodes, Evts}}
    end.


-spec translate_ping_reply(mnode(), term()) -> 
    {ok, [evt()]} | {'redir', mnode()} | {error, any()}.
    %%TODO no longer used. See ping_to_node()
%% @doc Should return either a list of evts that happened in the cluster, 
%%      a new remote mnode, indicating a redirect, or an error.
%%
%%      As for this result handler, 'ping_to_node' should return either
%%      of the following JSON formats on a 200 HTTP result:
%%        {
%%         "result": "ok",
%%         "evts" : [<JSON evt>, <JSON evt>, ...],
%%         "nodes": null | [<JSON mnode>
%%        }
%%
%%        {
%%         "result": "redir",
%%         "node"  : <JSON mnode>
%%        }
%%
%%        {
%%         "result": "error",
%%         "reason": "something"
%%        }
'translate_ping_reply'(_ThisNode, {'struct', Ls}=_JsonDecoded) ->
    case prop_val(<<"result">>, Ls) of
        <<"error">> -> 
            {error, prop_val(<<"reason">>, Ls)};
        <<"redir">> -> 
            {'redir', httpcluster:json2mnode(prop_val(<<"node">>, Ls))};
        <<"ok">> -> 
            {ok, lists:map(fun httpcluster:json2evt/1, 
                           prop_val(<<"evts">>, Ls))}
    end.


%% === Utility funs ====

prop_val(Prop, Ls) ->
    case lists:keyfind(Prop, 1, Ls) of
        {_, Val} -> Val;
        false    -> 'undefined'
    end.
