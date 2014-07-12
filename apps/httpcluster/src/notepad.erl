-module(notepad).

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").

-compile(export_all).

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

%%====================================================================
%% API
%%====================================================================

-spec get_app_var(atom()) -> term().
%% @doc Wrapper fun for getting an app variable value.
get_app_var(?HIST_LEN) -> get_app_var(?HIST_LEN, ?DEF_HIST_LEN);
get_app_var(?DEF_PING) -> get_app_var(?DEF_PING, ?DEF_DEF_PING);
get_app_var(?DEF_TTD)  -> get_app_var(?DEF_TTD, ?DEF_DEF_TTD);
get_app_var(?MOD_COMS) -> get_app_var(?MOD_COMS, ?DEF_MOD_COMS);
get_app_var(Atom)      -> get_app_var(Atom, 'undefined').


-spec get_app_var(atom(), term()) -> term().
%% @doc Wrapper fun for getting an app variable value.
%% TODO add checking to make sure zero values are not accepted, i.e. the def_def values are used, instead.
%TODO may be no need to export this. Not used outside this module, currently.
get_app_var(Prop, Def) ->
    {ok, App} = application:get_application(),
    application:get_env(App, Prop, Def).


-spec apply_handler_fun(atom(), [term()]) -> term().
%% @doc Apply user-defined handler functions. These functions should
%%      be implemented in the module given as the ?MOD_COMS app variable.
%% TODO reimplement using behaviours.
apply_handler_fun(Fun, Args) ->
    Mod = get_app_var(?MOD_COMS, ?DEF_MOD_COMS),
    apply(Mod, Fun, Args).


%TODO first clause not used
get_node(Name, #net{nodes=Nodes}) ->
    get_node(Name, Nodes);
get_node(Name, Nodes) ->
    case lists:keyfind(Name, #mnode.name, Nodes) of
        #mnode{}=N -> N;
        false      -> 'undefined'
    end.


take_node(Name, Nodes) ->
    case lists:keytake(Name, #mnode.name, Nodes) of
        {'value', Node, Nodes1} -> {Node, Nodes1};
        false                   -> {'undefined', Nodes}
    end.


-spec apply_change_to_nodes(evt(), [mnode()]) -> [mnode()].
%% Update a node record in the nodeslist from an evt.
%TODO not used so far
apply_change_to_nodes(#evt{org_name=OrgName, node=NewNode}, Nodes) ->
    apply_change_to_nodes(OrgName, NewNode, Nodes).


-spec apply_change_to_nodes(
    'undefined' | mnode() | mnode_name(), 
    mnode(), 
    [mnode()]
) -> [mnode()].
%% Update a node record in the nodeslist.
%TODO not used so far
apply_change_to_nodes('undefined', NewNode, Nodes) ->
    [NewNode|Nodes];
apply_change_to_nodes(#mnode{name=OrgName}, NewNode, Nodes) ->
    apply_change_to_nodes(OrgName, NewNode, Nodes);
apply_change_to_nodes(OrgName, NewNode, Nodes) ->
    lists:keystore(OrgName, #mnode.name, Nodes, NewNode).


apply_evt_to_nodes(#evt{org_name='undefined', node=NewNode}, Nodes) ->
    [NewNode|Nodes];
apply_evt_to_nodes(#evt{org_name=OrgName, node=NewNode}, Nodes) ->
    lists:keystore(OrgName, #mnode.name, Nodes, NewNode).


apply_evt_to_hist(#evt{}=Evt, Hist)              -> truncate_hist([Evt|Hist]);
apply_evt_to_hist(Evts, Hist) when is_list(Evts) -> truncate_hist(Evts ++ Hist).

truncate_hist(Hist) ->
    lists:sublist(Hist, get_app_var(?HIST_LEN)).

%%====================================================================
%% Internal functions
%%====================================================================

%% === Raw cluster events handling on primary node ====
%%
%% IMPORTANT: Primary MUST process resulting [#evt{}] and update the state 
%%            immediately after converting #sec_msg{} to #prim_res{}. 
%%            This is to preserve integrity of #evt.time.

-spec msg2res(sec_msg(), net()) -> 
    {prim_res(), mnode_name(), [evt() | evt_err()]}.
%% Converts a #sec_msg{} to a proper #prim_res{}.
%% This process will not affect the local state.
%%
%% Also returns the original source node, and the resulting
%% [#evt{} | #evt_err{}] records from the oncoming #evt_raw{} list.
msg2res(#sec_msg{from=From, evts=Raws, last_evt=Time, get_nodes=Bool}, 
        #net{nodes=Nodes, hist=Hist}) ->
    {OldNode, OtherNodes} = take_node_from_nodes(From, Nodes),
    ResEvts = raws2evts(From, OldNode, OtherNodes, lists:reverse(Raws), []),
    {
        #prim_res{
            origin = From, 
            evts   = ResEvts ++ get_hist_since(Time, Hist), 
            nodes  = case Bool of
                         true  -> Nodes;
                         false -> 'undefined'
                     end
        },
        From,
        ResEvts
    }.

take_node_from_nodes(Name, Nodes) ->
    case lists:keytake(Name, #mnode.name, Nodes) of
        {'value', Node, Nodes1} -> {Node, Nodes1};
        false                   -> {'undefined', Nodes}
    end.

%% Get all events from history that happened since Time.
%% 0 = all. -1 = none.
get_hist_since(0, Hist) ->
    Hist;
get_hist_since(-1, _Hist) ->
    [];
get_hist_since(Time, Hist) ->
    lists:takewhile(
        fun (#evt{time=T}) when T > Time -> true; (_) -> false end,
        Hist
    ).

raws2evts(_,_,_, [], Res) ->
    Res;
raws2evts(OldName, OldNode, OtherNodes, [Raw|Raws], Res) ->
    case raw2evt(OldName, OldNode, OtherNodes, Raw) of
        #evt{node_name=OldName1, node=OldNode1}=Evt ->
            raws2evts(OldName1, OldNode1, OtherNodes, Raws, [Evt|Res]);
        #evt_err{}=Err ->
            raws2evts(OldName, OldNode, OtherNodes, Raws, [Err|Res])
    end.

-spec raw2evt(string(), 'undefined' | mnode(), [mnode()], evt_raw()) ->
    evt() | evt_err().
%% Convert an evt_raw{} into a proper evt{}, ready to be applied to cluster.
raw2evt(OldName, OldNode, OtherNodes, #evt_raw{type=T, node=N}=Raw) ->
    case check_oldnode(OldNode, T) of
        ok ->
            case form_newnode(OldNode, OtherNodes, N, T) of
                #mnode{}=NewNode -> evt_from_raw(OldName, NewNode, Raw);
                {error, Error}   -> evt_err_from_raw(Error, Raw)
            end;
        {error, Error} ->
            evt_err_from_raw(Error, Raw)
    end.

evt_from_raw(OldName, NewNode, Raw) ->
    #evt{
        id        = Raw#evt_raw.id,
        type      = Raw#evt_raw.type,
        time      = new_evt_time(),
        node_name = OldName,
        node      = NewNode
    }.

evt_err_from_raw(Reason, Raw) ->
    #evt_err{
        id        = Raw#evt_raw.id,
        type      = Raw#evt_raw.type,
        time      = new_evt_time(),
        reason    = Reason
    }.

new_evt_time() ->
    calendar:datetime_to_gregorian_seconds(calendar:universal_time()).

%% Check if an event type is valid given the current 
%% state of the node in question.
check_oldnode('undefined', ?EVT_NODE_UP)       -> ok;
check_oldnode('undefined', _)                  -> {error, ?EVT_ERR_NOT_FOUND};
check_oldnode(#mnode{con=true}, ?EVT_NODE_UP)  -> {error, ?EVT_ERR_UP};
check_oldnode(#mnode{con=true}, _)             -> ok;
check_oldnode(#mnode{con=false}, ?EVT_NODE_UP) -> ok;
check_oldnode(#mnode{con=false}, _)            -> {error, ?EVT_ERR_DOWN}.

%% Create/modify the new state of the node. 
%% Also check for duplicate names when applicable.
form_newnode(_, OtherNodes, ENode, ?EVT_NODE_UP) ->
    case is_dup_name(ENode#mnode.name, OtherNodes) of
        true  -> {error, ?EVT_ERR_ALREADY_EXISTS};
        false -> new_connected_node(ENode, OtherNodes)
    end;
form_newnode(OldNode, OtherNodes, ENode, ?EVT_NODE_EDIT) ->
    case is_dup_name(ENode#mnode.name, OtherNodes) of
        true  -> {error, ?EVT_ERR_ALREADY_EXISTS};
        false -> edit_connected_node(OldNode, ENode)
    end;
form_newnode(OldNode, _OtherNodes, _ENode, ?EVT_NODE_DOWN) ->
    OldNode#mnode{con = false, rank = 0};
form_newnode(OldNode, _OtherNodes, ENode, _) ->
    OldNode#mnode{attribs = ENode#mnode.attribs}.

new_connected_node(#mnode{ping=Ping, ttd=TTD}=EvtNode, Nodes) ->
    EvtNode#mnode{
        con  = true,
        rank = new_node_rank(Nodes),
        ping = def_if_zero(Ping, ?DEF_PING),
        ttd  = def_if_zero(TTD, ?DEF_TTD)
    }.

edit_connected_node(Old, #mnode{ping=Ping, ttd=TTD}=EvtNode) ->
    Old#mnode{
        name = EvtNode#mnode.name,
        prio = EvtNode#mnode.prio,
        ping = def_if_zero(Ping, ?DEF_PING),
        ttd  = def_if_zero(TTD, ?DEF_TTD)
    }.

def_if_zero(0, Var) -> get_app_var(Var);
def_if_zero(Num, _) -> Num.

new_node_rank(Nodes) ->
    1 + lists:max([Rank || #mnode{rank=Rank, con=Con} <- Nodes, Con]).

is_dup_name(Name, Nodes) ->
    lists:any(
        fun(#mnode{name=Name1, con=Con}) ->
            case Name1 of Name when Con -> true; _ -> false end
        end, 
        Nodes
    ).

%% === Processed cluster events handling ====

%NOTE: checking #prim_res.origin == #net.this_node if this is a secondary node, should happen before this function

%apply_prim_res(Origin, #prim_res{nodes=RNodes}=Res, #net{nodes=NNodes}=Net) ->
%    NNodes1 = assume_nodelist(RNodes, NNodes),
%    sdsds

%assume_nodelist('undefined', Nodes)           -> Nodes;
%assume_nodelist(Nodes, _) when is_list(Nodes) -> Nodes.


-spec apply_evts_as_primary(mnode_name(), [evt() | evt_err()], net()) -> net().
%% Inside the primary node, immediately process and apply 
%% the results of msg2res/2. 
%%
%% This is in addition to replying to the Origin node about those results.
%%
%% Other nodes will have to wait until they've synced
%% with the primary on their next health check.
apply_evts_as_primary(Origin, Evts, Net) ->
    {Oks, Errs} = lists:partition(
        fun(#evt{}) -> true; (#evt_err{}) -> false end, 
        Evts
    ),
    log_evt_errors(Origin, Errs),
    apply_evts(Oks, Net).

log_evt_errors(_Origin, []) ->
    ok;
log_evt_errors(Origin, Errs) ->
    Str = "~n{id=~p, type=~p, time=~p, reason=~p}",
    {Str1, Vars1} = lists:foldl(fun(Err, {Strs, Vars}) -> 
        {
            Str ++ Strs,
            [
                Err#evt_err.id, 
                Err#evt_err.type, 
                Err#evt_err.time, 
                Err#evt_err.reason
                |Vars
            ]
        }
    end, {"", []}, Errs),
    lager:error("Event error/s from source ~p:" ++ Str1, [Origin|Vars1]).






-spec apply_evts([evt()], net()) -> net().
%% Apply the #prim_res.evts list (non-errors) into the state in reverse order.
%% This is where node roles are triggered/refreshed
%% and valid events are broadcasted to subscribing/client processes.
apply_evts(
    Evts, 
    #net{this_node=This, nodes=Nodes, prim=Prim, prim_ex=Pex, hist=Hist}=Net
) ->
    HLen = get_app_var(?HIST_LEN),
    {Nodes1, Prim1, Hist1} = lists:foldr(
        fun(Evt, Acc) -> apply_evt(Evt, This, Pex, HLen, Acc) end,
        {Nodes, Prim, Hist}, 
        Evts
    ),
    Net#net{nodes = Nodes1, prim = Prim1, hist = Hist1}.

apply_evt(
    #evt{id=Id, type=Ty, time=Ti, node_name=Na, node=No}=Evt,
    ThisName, PrimEx, HistLen, Tuple
) ->
    S = "Apply cluster event: {id=~p, type=~p, time=~p, node_name=~p, node=~p}",
    lager:info(S, [Id, Ty, Ti, Na, No]),
    apply_evt_2(Evt, ThisName, PrimEx, HistLen, Tuple).

apply_evt_2(
    #evt{node_name=Name, node=Node}=Evt,
    ThisName, PrimEx, HistLen,
    {Nodes, PrimName, Hist}
) ->
    Nodes1 = lists:keystore(Name, #mnode.name, Nodes, Node),
    PrimName1 = refresh_prim(ThisName, Nodes1, PrimEx),
    Hist1 = lists:sublist([Evt|Hist], HistLen),
    trigger_role(ThisName, PrimName1, Nodes1),
    httpcluster_subs:broadcast(Evt, {PrimName, PrimName1, Nodes}),
    %TODO require: client-provided process can intercept this procedure
    %TODO this should be a CAST on httpcluster_subs, too.
    {Nodes1, PrimName1, Hist1}.

%% Recalculate primary node.
refresh_prim(ThisName, Nodes, PrimEx) ->
    case get_node(ThisName, Nodes) of
        #mnode{con=true}  ->
            #mnode{name=Prim} = do_refresh_prim('undefined', Nodes, PrimEx),
            Prim;
        #mnode{con=false} ->
            'undefined'
    end.

do_refresh_prim(Prim, [], _Ex) ->
    Prim;
do_refresh_prim(Prim, [#mnode{con=false}|L], Ex) ->
    do_refresh_prim(Prim, L, Ex);
do_refresh_prim('undefined', [Node|L], Ex) ->
    do_refresh_prim(new_if_not_ex('undefined', Node, Ex), L, Ex);
do_refresh_prim(#mnode{prio=P}=Prim, [#mnode{prio=N}|L], Ex) when N > P ->
    do_refresh_prim(Prim, L, Ex);
do_refresh_prim(#mnode{prio=P}=Prim, [#mnode{prio=N}=Node|L], Ex) when N < P ->
    do_refresh_prim(new_if_not_ex(Prim, Node, Ex), L, Ex);
do_refresh_prim(#mnode{rank=P}=Prim, [#mnode{rank=N}|L], Ex) when N > P ->
    do_refresh_prim(Prim, L, Ex);
do_refresh_prim(#mnode{rank=P}=Prim, [#mnode{rank=N}=Node|L], Ex) when N < P ->
    do_refresh_prim(new_if_not_ex(Prim, Node, Ex), L, Ex).

new_if_not_ex(Old, New, PrimEx) ->
    case lists:keymember(New#mnode.name, 1, PrimEx) of
        true  -> Old;
        false -> New
    end.

% placeholder function
trigger_role(_ThisName, _PrimName, _Nodes) ->
    ok.

