-module(httpcluster).
-behaviour(gen_server).

%TODO this entire module is whack

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").
-export_type([mnode/0, evt/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
-export([
    evt2struct/1,
    struct2evt/1,
    mnode2proplist/1,
    json2mnode/1,
    validate_event_props/1
]).

%% Used internally
-export([
    start_link/1,
    new_remote_evt/1,
    new_remote_evts/1,
    get_sec_ping_details/0,
    apply_handler_fun/2,
    get_app_var/1,
    get_app_var/2
]).

% this_node  :: name of this node
% prim       :: name of node being currently treated as primary
% prim_ex    :: nodes exempted from being primary
% hist       :: lists the events that have already been applied to the network
% wait_ev    :: raw events on wait-list (not applied yet)
-record(net, {
    this_node    :: 'undefined' | mnode_name(),
    nodes   = [] :: [mnode()],
    prim         :: 'undefined' | mnode_name(),
    prim_ex = [] :: [{mnode_name(), ttd_type()}],
    hist    = [] :: [evt()],
    wait_ev = [] :: [evt_raw()]
}).
-type net() :: #net{}.

-define(SERVER, ?MODULE).


%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).


evt2struct(#evt{}=_E) ->
    %TODO
    % no need to append 'struct', but do it for posterity
    {'struct', []}.


struct2evt({'struct', _Ls}) ->
    %TODO
    #evt{}.


struct2evt_err({'struct', _Ls}) ->
    %TODO,
    #evt_err{}

-spec mnode2proplist(mnode()) -> list().
%% @doc Utility fun.
mnode2proplist(#mnode{}=N) ->
    [
        {"name", N#mnode.mname},
        {"prio", N#mnode.prio},
        {"rank", N#mnode.rank},
        {"ping", N#mnode.ping},
        {"ttd", N#mnode.ttd},
        {"attribs", N#mnode.attribs}
    ].


-spec json2mnode({'struct', list()}) -> mnode().
%% @doc Utility fun.
json2mnode({'struct', Ls}) ->
    #mnode{
        mname   = erlang:binary_to_atom(prop_val(<<"mname">>, Ls), 'utf8'),
        con     = prop_val(<<"con">>, Ls),
        prio    = prop_val(<<"prio">>, Ls),
        rank    = prop_val(<<"rank">>, Ls),
        ping    = prop_val(<<"ping">>, Ls),
        ttd     = prop_val(<<"ttd">>, Ls),
        attribs = stringify_json(prop_val(<<"attribs">>, Ls))
    }.

stringify_json({'struct', Obj}) -> stringify_json(Obj);
stringify_json({K, V})          -> {stringify_key(K), stringify_json(V)};
stringify_json([H|T])           -> [stringify_json(H)|stringify_json(T)];
stringify_json(X)               -> stringify_key(X).

stringify_key(K) when is_binary(K) -> binary_to_list(K);
stringify_key(K)                   -> K.


-spec validate_event_props(evt()) -> 
    ok | {error, 'invalid_node_val' | 'invalid_mname_val' | 'invalid_ttd_val' |
                 'invalid_ping_val' | 'invalid_prio_val'}.
%% TODO correct intent. wrong implementation.
%% values must be validated BEFORE being made into an event record!!!!!!!!!
%check dialyzer for clues.
%% update: this is also outdated. definitions have been updated.

%% Make sure an event contains all needed information.
%%
%% When on secondary node role, on event ?EVT_NODE_UP, 
%% relevant info transmitted from the primary node are:
%%    type = ?EVT_NODE_UP
%%    ref
%%    time
%%    node_new
%% Relevant info for node_new:
%%    mname
%%    prio
%%    ping
%%    ttd
%%    attribs
%% On primary node role, the above node_new values are also the
%% relevant values received when a node tries to connect.
%% This is the only event type accepted from a disconnected or 
%% previously non-existing node.
%%
%% When on secondary node role, on event ?EVT_NODE_DOWN, 
%% relevant info transmitted from the primary node are:
%%    type = ?EVT_NODE_DOWN
%%    ref
%%    time
%%    node_old
%% Relevant info for node_old:
%%    mname
%% On primary node role, the above node_old values are also the 
%% relevant values received when a node tries to gracefully disconnect.
%%
%% When on secondary node role, on event ?EVT_NODE_EDIT, 
%% relevant info transmitted from the primary node are:
%%    type = ?EVT_NODE_EDIT
%%    ref
%%    time
%%    node_old
%%    node_new
%% Relevant info for node_old:
%%    mname
%% Relevant info for node_new:
%%    mname
%%    prio
%%    ping
%%    ttd
%% On primary node role, the above node_new/old values are also the 
%% relevant values received when a node tries to edit its own properties.
%%
%% When on secondary node role, on a user-defined event, 
%% relevant info transmitted from the primary node are:
%%    type = <user-defined>
%%    ref
%%    time
%%    node_old
%%    node_new
%% Relevant info for node_old:
%%    mname
%% Relevant info for node_new:
%%    attribs
%% On primary node role, the above node_new/old values are also the 
%% relevant values received when a node emits a user-defined event.
validate_event_props(Evt) ->
    try validate_event(Evt), ok
    catch throw:Error -> {error, Error}
    end.

validate_event(#evt{type=?EVT_NODE_UP, node_new=Node}) ->
    validate_mname_val(Node),
    validate_int_mnode_vals(Node);
validate_event(#evt{type=?EVT_NODE_DOWN, node_old=Node}) ->
    validate_mname_val(Node);
validate_event(#evt{type=?EVT_NODE_EDIT, node_old=Node1, node_new=Node2}) ->
    validate_mname_val(Node1),
    validate_mname_val(Node2),
    validate_int_mnode_vals(Node2);
validate_event(#evt{type=_, node_old=Node}) ->
    validate_mname_val(Node).

validate_mname_val('undefined') ->
    throw('invalid_node_val');
validate_mname_val(#mnode{mname=N}) 
    when not is_atom(N) orelse N =:= 'undefined' ->
    throw('invalid_mname_val');
validate_mname_val(#mnode{}) ->
    ok.

validate_int_mnode_vals(#mnode{ttd=N}) when not is_integer(N) orelse N < 0 ->
    throw('invalid_ttd_val');
validate_int_mnode_vals(#mnode{ping=N}) when not is_integer(N) orelse N < 0 ->
    throw('invalid_ping_val');
validate_int_mnode_vals(#mnode{prio=N}) when not is_integer(N) orelse N < 0 ->
    throw('invalid_prio_val');
validate_int_mnode_vals(#mnode{}) ->
    ok.


-spec new_remote_evt(evt()) -> ok | {error, any()}.
%% @doc Process a cluster event from the primary node. If this node IS the 
%%      primary, the function may return an error if necessary, signifying the 
%%      event cannot be accepted. If this node is secondary, 
%%      the return value is always ok.
new_remote_evt(Evt) ->
    gen_server:call(?SERVER, {'new_remote_evt', Evt}).


-spec new_remote_evts([evt()]) -> ok.
%% @doc Send in new cluster events. This version can only accept events
%%      that have already been timestamped (i.e. defined ref and time values).
new_remote_evts(Evts) ->
    lists:foreach(fun(Evt) -> 
        new_remote_evt(Evt) 
    end, lists:keysort(#evt.time, Evts)),
    ok.


-spec get_sec_ping_details() -> 
    {ok, {mnode() | 'undefined', 
          mnode() | 'undefined', 
          evt_ref() | 'undefined'}}.
%% @doc Returns this node, the primary node, and the last history event ref.
get_sec_ping_details() ->
    gen_server:call(?SERVER, 'get_sec_ping_details').


-spec apply_handler_fun(atom(), [term()]) -> term().
%% @doc Apply user-defined handler functions. These functions should
%%      be implemented in the module given as the ?MOD_COMS app variable.
apply_handler_fun(Fun, Args) ->
    Mod = get_app_var(?MOD_COMS, ?DEF_MOD_COMS),
    apply(Mod, Fun, Args).


-spec get_app_var(atom()) -> term().
%% @doc Wrapper fun for getting an app variable value.
get_app_var(?HIST_LEN) -> get_app_var(?HIST_LEN, ?DEF_HIST_LEN);
get_app_var(?DEF_PING) -> get_app_var(?DEF_PING, ?DEF_DEF_PING);
get_app_var(?DEF_TTD)  -> get_app_var(?DEF_TTD, ?DEF_DEF_TTD);
get_app_var(?MOD_COMS) -> get_app_var(?MOD_COMS, ?DEF_MOD_COMS);
get_app_var(Atom)      -> get_app_var(Atom, 'undefined').


-spec get_app_var(atom(), term()) -> term().
%% @doc Wrapper fun for getting an app variable value.
get_app_var(Prop, Def) ->
    {ok, App} = application:get_application(),
    application:get_env(App, Prop, Def).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Opts]) ->
    {ok, reset_state(#net{})}.

%TODO on network init, call main httpcluster module for details about
% this node.
% So the main module contains a copy, and this module contains a copy.
% If main module wishes to modify this node, call this module. Then this module
% should communicate on next opportunity to the cluster about the attrib change.



% TODO client supplies thisnode here. Minimum allowed info: 
% mname, prio, ping, ttd, attribs
% TODO client supplies a list of mnodes here. Each mnode contains the bare
% minimum allowed to establish contact to that node: mname and attribs
handle_call({'init_network', ThisNode, InitNodes}, From, Net) ->
    gen_server:reply(From, ok),
    Net1 = this_connect_network(ThisNode, InitNodes, Net),
    {noreply, Net1};

%TODO on 'other_node_init', filter the error for 'mnode_up' error. On such a case, reply with an empty event list, instead of an error. See this previous implementation:
%other_connect_network(NodeupEvt, #net{prim=Prim, this_node=Prim}=Net) ->
%    case process_remote_event(NodeupEvt, Net) of
%        {ok, Evt, Net1}           -> {ok, {Net#net.nodes, [Evt]}, Net1};
%        {error, 'mnode_up', Net1} -> {ok, {Net#net.nodes, []}, Net1};
%        {error, _,_}=Error        -> Error
%    end;


handle_call('get_sec_ping_details', _From, Net) ->
    ThisNode = get_node(Net),
    PrimNode = get_node(Net#net.prim, Net),
    LastRef = case Net#net.hist of
        [#evt{ref=Ref}|_] -> Ref;
        []                -> 'undefined'
    end,
    {reply, {ok, {ThisNode, PrimNode, LastRef}}, Net};
    %% TODO this function should also return the cached custom event that this node wants to cast to the primary node.

handle_call({'new_remote_evt', Evt}, _From, Net) ->
%    {Reply, Net1} = handle_raw_event(Evt, Net), TODO FIX THIS
    {_, Reply, Net1} = process_remote_event(Evt, Net),
    {reply, Reply, Net1};

handle_call(_Msg, _From, State) ->
    {reply, 'undefined', State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Internal functions
%%====================================================================

%% === Utility funs ====

prop_val(Prop, Ls) ->
    case lists:keyfind(Prop, 1, Ls) of
        {_, Val} -> Val;
        false    -> 'undefined'
    end.

%TODO client nodes must already filter for bitstrings. This module should no longer do that.
-spec to_list(string() | binary()) -> string().
to_list(Bin) when is_binary(Bin) -> binary_to_list(Bin);
to_list(Str)                     -> Str.

reset_state(Net) ->
    reset_state(Net, 'undefined', []).

reset_state(Net, ThisNode, Nodes) ->
    Net#net{
        this_node = ThisNode,
        nodes     = Nodes,
        prim      = 'undefined',
        prim_ex   = [],
        hist      = [],
        wait_ev   = []
    }.

-spec get_secondaries(atom(), [mnode()]) -> [mnode()].
%% Get all connected secondary nodes
get_secondaries(Prim, Nodes) ->
    [N || #mnode{mname=Mn, con=C}=N <- Nodes, C, Mn =/= Prim].

%% Get node (default: this node) from nodes list
get_node(#net{this_node=ThisName, nodes=Nodes}) ->
    get_node(ThisName, Nodes).

get_node(Name, #net{nodes=Nodes}) ->
    get_node(Name, Nodes);
get_node(Name, Nodes) ->
    case lists:keyfind(Name, #mnode.mname, Nodes) of
        #mnode{}=N -> N;
        false      -> 'undefined'
    end.

get_this_role(#net{prim='undefined'})          -> ?ROLE_DISC;
get_this_role(#net{prim=Prim, this_node=Prim}) -> ?ROLE_PRIM;
get_this_role(#net{})                          -> ?ROLE_SEC.


-spec disconnect_network(net()) -> net().
%% Disconnect from network cluster and reset data.
%TODO cast to network the node_down event..........................
% this function should not be here.
disconnect_network(Net) ->
    httpcluster_ping:set_role_disc(),
    httpcluster_timer:stop_all(),
    reset_state(Net).



%% === This node connects to httpcluster network ====
%% (This node transmits init data)

-spec this_connect_network(mnode(), [mnode()], net()) -> 
    {ok, evt() | 'undefined', net()} | 
    {error, evt_err() | 'already_connected', net()}.
%% Connect to network by pinging to every node in the given list. 
%% Then assume either primary or secondary role based on result.
this_connect_network(#mnode{mname=ThisName}=ThisNode, NodesList, 
                     #net{prim='undefined', prim_ex=[]}=Net) ->
    {Nodes, Evt} = cast_node_up_2network(ThisNode, NodesList),
    process_remote_event(Evt, Net#net{this_node = ThisName, nodes = Nodes});
this_connect_network(_ThisNode, _NodesList, Net) ->
    {error, 'already_connected', Net}.
%TODO perform this check here:
% is_this_connected(Net)

cast_node_up_2network(ThisNode, NodesList) ->
    Ns1 = lists:keydelete(ThisNode#mnode.mname, #mnode.mname, NodesList),
    Evt = single_nodeup_event(ThisNode),
    Data = mochijson2:encode(
        apply_handler_fun(
            ?HANDLER_CREATE_INITDATA, 
            [Evt, evt2struct(Evt)]
        )
    ),
    case cast_up_seq(Ns1, ThisNode, Data, false) of
        {ok, {Nodes, [Evt1]}}  -> {Nodes, Evt1};
        {ok, {Nodes, []}}      -> {Nodes, 'undefined'};
        {error, 'unreachable'} -> {[], Evt}
    end.

cast_up_seq([], _,_,_) ->
    {error, 'unreachable'};
cast_up_seq([DNode|Tail], ThisNode, Data, IsRedir) ->
    case apply_handler_fun(?HANDLER_INIT_TO_NODE, [ThisNode, DNode, Data]) of
        {ok, Bin} ->
            case apply_handler_fun(
                ?HANDLER_TRANSLATE_INIT_REPLY,
                [ThisNode, mochijson2:decode(Bin)]
            ) of
                {ok, {_MNodes, _Evts}}=Ok ->
                    Ok;
                {'redir', _} when IsRedir ->
                    cast_up_seq(Tail, ThisNode, Data, false);
                {'redir', DNode2} ->
                    cast_up_seq([DNode2|Tail], ThisNode, Data, true);
                {error, _} ->
                    cast_up_seq(Tail, ThisNode, Data, false)
            end;
        {error, _} ->
            cast_up_seq(Tail, ThisNode, Data, false)
    end.

single_nodeup_event(Node) ->
    #evt{
        type     = ?EVT_NODE_UP,
        node_new = #mnode{
            mname   = Node#mnode.mname,
            prio    = Node#mnode.prio,
            ping    = Node#mnode.ping,
            ttd     = Node#mnode.ttd,
            attribs = Node#mnode.attribs
        }
    }.


%% === A remote node connects to httpcluster network ====
%% (This node receives init data)

-spec other_connect_network(evt(), net()) -> 
    {ok, {[mnode()], [evt()]}, net()} |
    {error, evt_err(), net()} |
    {'redir', mnode(), net()}.
%% This node receives data from another node trying to join the network.
%% If this is the primary node, then reply with a nodes list and echo the
%% event. If this is secondary or disconnected, reply accordingly.
other_connect_network(_NodeupEvt, #net{prim='undefined'}=Net) ->
    {error, 'not_connected', Net};
other_connect_network(NodeupEvt, #net{prim=Prim, this_node=Prim}=Net) ->
    case process_remote_event(NodeupEvt, Net) of
        {ok, Evt, Net1}           -> {ok, {Net#net.nodes, [Evt]}, Net1};
        {error, 'mnode_up', Net1} -> {ok, {Net#net.nodes, []}, Net1};
        {error, _,_}=Error        -> Error
    end;
other_connect_network(_NodeupEvt, #net{prim=Prim, nodes=Nodes}=Net) ->
    {'redir', get_node(Prim, Nodes), Net}.


%% === 3rd-party initiated events ====

-spec manual_event(evt(), net()) ->
    {ok, evt() | 'evt_waiting', net()} | 
    {error, evt_err() | 'not_connected', net()}.
%% Entry point for manually-initiated events by the client. Events are only
%% accepted this way if this node is connected to the cluster. Otherwise,
%% this node must first "initiate" the connection before creating events.
%%
%% If this is primary, process event right away. Otherwise, put it on wait-list.
manual_event(Evt, #net{this_node=This, prim=Prim, wait_ev=Evts}=Net) ->
    case get_this_role(Net) of
        ?ROLE_PRIM -> process_event(Evt, Net);
        ?ROLE_SEC  -> {ok, 'evt_waiting', Net#net{wait_ev = [Evt|Evts]}};
            %TODO or this could be something like httpcluster_ping:add_to_waiting_evts(Evt)
        ?ROLE_DISC -> {error, 'not_connected', Net}
    end


%% === A remote node connects to httpcluster network ====
%% (This node receives init data)


%% This node received zero or more events from a node within the network. 
%% The node also gave it's LastRef, indicating how updated its event history is.
%% If this is the primary node, respond with a list of formalized events
%% and a list of error messages when applicable.
%%
%% If this node is secondary or disconnected, respond accordingly.
internal_net_events(Evts, LastRef, #net{prim=Prim, this_node=This}=Net) ->
    case get_this_role(Net) of
        ?ROLE_PRIM ->
            {Oks, Errs, Net1} = process_events(Evts, Net),
            {ok, {Oks, Errs}, Net1};
        ?ROLE_SEC ->
        ?ROLE_DISC ->
    end

% if you go this path, include LastHistRef in both functions. LastHistRef could be 'undefined', as is the case with node_up events. If it is undefined or false, then assume latest events only. i.e. node is fully updated with events.
%update: LastRef in internal_net_events CANNOT be undefined.
% external_net_event should also accept an ordered list of events, instead of just a single event.


-spec external_net_event(evt(), net()) -> 
    {ok, {[mnode()], [evt()]}, net()} |
    {error, evt_err(), net()} |
    {'redir', mnode(), net()}.
%% This node received an event from a node outside the network.
%% If this is the primary node, then reply with a nodes list and echo the
%% (formalized) event. If this is secondary or disconnected, reply accordingly.
external_net_event(_Evt, #net{prim='undefined'}=Net) ->
    {error, 'not_connected', Net};
external_net_event(Evt, #net{prim=Prim, this_node=Prim, nodes=Nodes}=Net) ->
    case process_event(Evt, Net) of
        {ok, Evt1, Net1}   -> {ok, {Nodes, [Evt1]}, Net1};
        {error, _,_}=Error -> Error
    end;
external_net_event(_Evt, #net{prim=Prim, nodes=Nodes}=Net) ->
    {'redir', get_node(Prim, Nodes), Net}.


%% === Cluster events handling ====

-spec process_events(['undefined' | evt()], net()) -> 
    {[evt()], [evt_err()], net()}.
%% Process multiple events.
%%
%% NOTE:
%% Evts list is from-latest-to-earliest. Returned event and evt_err lists 
%% are likewise ordered. The same ordering is also used for #net.hist.
process_events(Evts, Net) ->
    do_process_events(lists:reverse(Evts), [], [], Net).

do_process_events([], Oks, Errs, Net) ->
    {Oks, Errs, Net};
do_process_events([Evt|Tail], Oks, Errs, Net) ->
    case process_event(Evt, Net) of
        {ok, 'undefined', Net1} -> 
            do_process_events(Tail, Oks, Errs, Net1);
        {ok, Evt1, Net1} -> 
            do_process_events(Tail, [Evt1|Oks], Errs, Net1);
        {error, Error, Net1} ->
            do_process_events(Tail, Oks, [Error|Errs], Net1)
    end.

-spec process_event
(evt(), net())       -> {ok, evt(), net()} | {error, evt_err(), net()};
('undefined', net()) -> {ok, 'undefined', net()}.
%% Handles an event that came from the primary node (this node CAN be primary). 
%% The event goes through validation/etc. if it is an event with an
%% undefined 'ref' property (i.e., this node IS primary).
%%
%% NOTE: checking whether this node is connected, etc. must be done BEFORE
%% calling this function.
process_event('undefined', Net) ->
    {ok, 'undefined', event_net_update('undefined', Net)};
process_event(Evt, Net) ->
    case formalize_event(Evt, Net) of
        {ok, Evt1} ->
            Net1 = event_net_update(Evt1, Net),
            httpcluster_subs:broadcast(Evt1),
            %TODO require: client-provided process to intercept this procedure
            {ok, Evt1, Net1};
        {error, Error} ->
            {error, Error, Net}
    end.



do_secmsg_if_prim(#sec_msg{}=Msg, #net{}=Net) ->
    case get_this_role(Net) of
        ?ROLE_PRIM ->
            Res = msg2res(Msg, Net),
            
        ?ROLE_SEC -> 
            redir
        ?ROLE_DISC -> 
            {error, 'disconnected', Net}
    end.



process_evt_raw(Name, Raw, #net{nodes=Nodes, hist=Hist}=Net) ->
    case raw2evt(Name, Raw, Nodes, Hist) of
        #evt{}=Evt ->
            httpcluster_subs:broadcast(Evt),
            %TODO require: client-provided process to intercept this procedure
            %TODO this should be a CAST on httpcluster_subs, too.
            {Evt, net_update(Evt, Net)};
        #evt_err{}=Error ->
            {Error, Net}
    end.

% DEFUNCTION SECTION START ===================================================

%% === Cluster events handling on Primary Node ====
% IMPORTANT: primary MUST update process evt() and update the state immediately after converting sec_msg to prim_res. This is to preserve integrity of #evt.time

-spec msg2res(sec_msg(), net()) -> prim_res().
%% Converts a #sec_msg{} to a proper #prim_res{}, 
%% without affecting local state.
msg2res(#sec_msg{from=From, evts=Raws, last_evt=Time}=Msg, Net) ->
    #prim_res{
        origin = From,
        evts   = raws2evts(From, lists:reverse(Raws), Net, []) 
                 ++ get_hist_since(Time, Net#net.hist),
        nodes  = case Msg#sec_msg.get_nodes of
                     true  -> Net#net.nodes;
                     false -> 'undefined'
                 end
    }.

%  consider time=0 and time=-1
get_hist_since(Time, Hist) ->
    lists:takewhile(
        fun
            (#evt{time=T1}) when T1 >= Time -> true;
            (_) -> false
        end,
        Hist
    ).
% DEFUNCTION SECTION ===================================================

raws2evts(From, [], _Net, Res) ->
    Res;
raws2evts(From, [Raw|Tail], #net{nodes=Nodes, hist=Hist}=Net, Res) ->
    case raw2evt(From, Raw, Nodes, Hist) of
        #evt{}=Evt ->
            Net1 = net_soft_update(Evt, Net),
            raws2evts(From, Tail, Net1, [Evt|Res]);
        #evt_err{}=Err ->
            raws2evts(From, Tail, Net, [Err|Res])
    end.

-spec raw2evt(string(), evt_raw(), [mnode()], [evt()]) -> evt() | evt_err().
%% Convert an evt_raw{} into a proper evt{}, ready to be applied to cluster.
raw2evt(From, Raw, Nodes, Hist) ->
    case formalize_evt_node(From, Raw, Nodes) of
        #mnode{}=Node1 ->
            #evt{
                id        = Raw#evt_raw.id,
                type      = Raw#evt_raw.type,
                time      = new_evt_time(),
                node_name = From,
                node      = Node1
            };
        #evt_err{}=Err ->
            Err
    end.

formalize_evt_node(From, Raw, Nodes) ->
    case get_old_mnode(From, Raw, Nodes) of
        #evt_err{}=Err -> Err;
        Old            -> form_new_mnode(From, Raw, Old, Nodes)
    end.
% DEFUNCTION SECTION ===================================================

-spec get_old_mnode(string(), evt_raw(), [mnode()]) -> 
    'undefined' | mnode() | evt_err().
%% Get From's original record in the nodes list.
get_old_mnode(From, #evt_raw{type=T}=R, Nodes) ->
    Bool = (T =:= ?EVT_NODE_UP),
    case get_node(From, Nodes) of
        'undefined' when Bool -> 
            'undefined';
        'undefined' -> 
            evt_err_from_raw(From, R, ?EVT_ERR_NOT_FOUND);
        #mnode{con=true} when Bool -> 
            evt_err_from_raw(From, R, ?EVT_ERR_UP);
        #mnode{con=true}=Node -> 
            Node;
        #mnode{con=false}=Node when Bool ->
            Node;
        #mnode{con=false} -> 
            evt_err_from_raw(From, R, ?EVT_ERR_DOWN)
    end.

-spec form_new_mnode(string(), evt_raw(), 'undefined' | mnode(), [mnode()]) -> 
    mnode() | evt_err().
%% Form From's new node record.
form_new_mnode(From, #evt_raw{type=?EVT_NODE_UP, node=N}, _, Nodes) ->
    new_connected_mnode(From, N, Nodes);
form_new_mnode(_, #evt_raw{type=?EVT_NODE_DOWN}, Old, _) ->
    Old#mnode{con = false, rank = 0};
form_new_mnode(From, #evt_raw{type=?EVT_NODE_EDIT, node=N}=R, Old, Nodes) ->
    case is_dup_mname(Old#mnode.name, N#mnode.name, Nodes) of
        true  -> evt_err_from_raw(From, R, ?EVT_ERR_ALREADY_EXISTS);
        false -> edit_connected_mnode(Old, N)
    end;
form_new_mnode(_, #evt_raw{type=_, node=N}, Old, Nodes) ->
    Old#mnode{attribs = N#mnode.attribs}.
% DEFUNCTION SECTION ===================================================

new_connected_mnode(From, #mnode{ping=Ping, ttd=TTD}=Node, Nodes) ->
    Node#mnode{
        name = From,
        con  = true,
        rank = new_node_rank(Nodes),
        ping = def_if_zero(Ping, ?DEF_PING),
        ttd  = def_if_zero(TTD, ?DEF_TTD)
    }.

edit_connected_mnode(Old, New) ->
    Old#mnode{
        name = New#mnode.name,
        prio = New#mnode.prio,
        ping = def_if_zero(New#mnode.ping, ?DEF_PING),
        ttd  = def_if_zero(New#mnode.ttd, ?DEF_TTD)
    }.

def_if_zero(0, Var) -> get_app_var(Var);
def_if_zero(Num, _) -> Num.

evt_err_from_raw(From, Raw, Reason) ->
    #evt_err{
        id        = Raw#evt_raw.id,
        type      = Raw#evt_raw.type,
        time      = new_evt_time(),
        node_name = From,
        reason    = Reason
    }.

new_evt_time() ->
    calendar:datetime_to_gregorian_seconds(calendar:universal_time()).

new_node_rank(Nodes) ->
    1 + lists:max([Rank || #mnode{rank=Rank, con=Con} <- Nodes, Con]).

is_dup_mname(OrigName, NewName, Nodes) ->
    lists:any(fun(#mnode{name=NameX, con=ConX}) ->
        case NameX of NewName when ConX -> true; _ -> false end
    end, lists:keydelete(OrigName, #mnode.name, Nodes)).

% DEFUNCTION SECTION END ======================================================





%% === Refresh/update cluster values ====

%------------- is this useful?? ---------------
-spec net_updates([evt() | evt_err()], net()) -> {net(), [evt_err()]}.
net_updates(NodeEvts, Net) ->
    {Evts, Errs} = lists:partition(
        fun(#evt{}) -> true; (#evt_err{}) -> false end, 
        NodeEvts
    ),
    {iter_net_update(Evts, Net), Errs}.

iter_net_update([Evt|Tail], Net) -> iter_net_update(Tail, net_update(Evt, Net));
iter_net_update([], Net)         -> Net.
% ----------------------------------------------------


            httpcluster_subs:broadcast(Evt),
            %TODO require: client-provided process to intercept this procedure
            %TODO this should be a CAST on httpcluster_subs, too.
            {Evt, net_update(Evt, Net)};
-spec net_soft_update(evt(), net()) -> net().
%% Update state without triggering role changes. 
%TODO hist is not necessary here
net_soft_update(Evt, #net{this_node=This, nodes=Nodes, hist=Hist}=Net) ->
    {Nodes1, Hist1} = update_nodes_hist(Evt, Nodes, Hist),
    Net#net{
        nodes = Nodes1,
        hist  = Hist1,
        prim  = update_primary_name(This, Nodes1)
    }.

-spec net_update(evt(), net()) -> net().
%% Update the network state and renew node role.
net_update(Evt, #net{nodes=Nodes, hist=Hist}=Net) ->
    {Nodes1, Hist1} = update_nodes_hist(Evt, Nodes, Hist),
    net_update(Net#net{
        nodes = Nodes1,
        hist  = Hist1
    }).

-spec net_update(net()) -> net().
%% Renew node role.
net_update(#net{this_node=This, nodes=Nodes}=Net) ->
    Net1 = Net#net{prim = update_primary_name(This, Nodes)},
    trigger_role(Net1),
    Net1.

update_nodes_hist(#evt{node_name=Name, node=Node}=Evt, Nodes, Hist) ->
    {
        lists:keystore(Name, #mnode.name, Nodes, Node), 
        lists:sublist([Evt|Hist], get_app_var(?HIST_LEN))
    }.

refresh_primary_name(This, Nodes, _PrimEx) ->
    case get_node(This, Nodes) of
        #mnode{con=true}  ->
            #mnode{mname=Prim} = generate_primary('undefined', Nodes),
            Prim;
        #mnode{con=false} ->
            'undefined'
    end.
% TODO consider prim_ex list....

generate_primary(Prim, []) ->
    Prim;
generate_primary(Prim, [#mnode{con=false}|Tail]) ->
    generate_primary(Prim, Tail);
generate_primary('undefined', [Node|Tail]) ->
    generate_primary(Node, Tail);
generate_primary(#mnode{prio=P}=Prim, [#mnode{prio=N}|Tail]) when N > P ->
    generate_primary(Prim, Tail);
generate_primary(#mnode{prio=P}, [#mnode{prio=N}=Node|Tail]) when N < P ->
    generate_primary(Node, Tail);
generate_primary(#mnode{rank=P}=Prim, [#mnode{rank=N}|Tail]) when N > P ->
    generate_primary(Prim, Tail);
generate_primary(#mnode{rank=P}, [#mnode{rank=N}=Node|Tail]) when N < P ->
    generate_primary(Node, Tail).


%% === Assume node role, or abandon/disconnect role ====

-spec trigger_role(net()) -> _.
%% Evaluate this node's role and trigger the different corresponding
%% functions accordingly. Those functions MUST be idempotent.
% TODO-------------------------
trigger_role(#net{this_node=Prim, prim=Prim, nodes=Nodes}) ->
    %% PRIMARY NODE ROLE
    %TODO -------------------------------------
    httpcluster_timer:start_sec(get_secondaries(Prim, Nodes)), %TODO this must be converted into a function that starts a timer for each currently secondary node, and terminates all others.
    %httpcluster_ping:set_role_prim(), TODO this function should be implemented as a way of checking httpcluster_ping if it's still running secondary routines.
    % yeah..................do that.
    % i.e. each set_role_xxx must terminate all routines from other roles
    ok;
trigger_role(#net{}=Net) ->
    %% SECONDARY NODE ROLE
    ThisNode = get_node(Net),
    httpcluster_ping:set_role_sec(ThisNode#mnode.ping),
    ok.







