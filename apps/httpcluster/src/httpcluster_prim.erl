-module(httpcluster_prim).

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").

-export([handle_sec_msg/2]).

-record(state, {
    nodes = [] :: [mnode()],
    hist  = [] :: [evt()]
}).
-type state() :: #state{}.

%%====================================================================
%% API
%%====================================================================

%% TODO: watch for a node_up event with EVT_ERR_UP error. This is technically an error, but wrap it in a prim_res() and respond with that anyway.

%%====================================================================
%% Internal functions
%%====================================================================

-spec handle_sec_msg(sec_msg(), state()) -> {prim_res(), state()}.
%% Converts a #sec_msg{} to a proper #prim_res{}.
%%
%% NOTE: A single sec_msg() will come from a single source node, and 
%%       will consequently refer only to that node in terms of its evt_raws.
%%
%%       A prim_res() is a response for a sec_msg().
handle_sec_msg(
    #sec_msg{from=OrgName, raws=Raws}=Msg, 
    #state{nodes=Nodes, hist=Hist}=State
) ->
    lager:debug("Begin processing #sec_msg{} from ~p", [OrgName]),
    {OrgNode, OtherNodes} = take_first_orgnode(OrgName, Nodes),
    {OrgNode, OtherNodes} = httpcluster:take_node(OrgName, Nodes),
    {Evts, FinalNode} = raws2evts(OrgNode, OtherNodes, Raws),
    lager:debug("Done processing #sec_msg{} from ~p", [OrgName]),
    {
        new_prim_res(Msg, Evts, Nodes, Hist),
        update_state([FinalNode|OtherNodes], Evts, State)
    }.

%% Turns a list of raw_evts (pertaining to a single node) 
%% into a list of evts or evt_errs. 
%% Also returns the final form of the node in question.
raws2evts(OrgNode, OtherNodes, Raws) ->
    lists:foldr(
        fun(Raw, {Acc, ONode}) ->
            case raw2evt(ONode, OtherNodes, Raw) of
                #evt{id=Id, type=Ty, time=Ti, org_name=Na1, node=No1}=Evt -> 
                    St = "{id=~p, type=~p, time=~p, org_name=~p, node=~p}",
                    lager:debug("Cluster evt: " ++ St, [Id, Ty, Ti, Na1, No1]),
                    {[Evt|Acc], No1};
                #evt_err{id=Id, type=Ty, time=Ti, reason=Re}=Err ->
                    St = "{id=~p, type=~p, time=~p, reason=~p}",
                    lager:debug("Cluster evt error: " ++ St, [Id, Ty, Ti, Re]),
                    {[Err|Acc], ONode}
            end
        end,
        {[], OrgNode}, 
        Raws
    ).

-spec raw2evt('undefined' | mnode(), [mnode()], evt_raw()) -> evt() | evt_err().
%% Convert an #evt_raw{} into a proper #evt{}, ready to be applied to cluster.
%% Could also return an #evt_err{}, instead.
raw2evt(OrgNode, OtherNodes, #evt_raw{type=RawType, node=RawNode}=Raw) ->
    Time = new_evt_time(),
    case check_orgnode(OrgNode, RawType) of
        ok ->
            case form_newnode(OrgNode, OtherNodes, RawNode, RawType) of
                #mnode{}=NewNode -> evt_from_raw(OrgNode, NewNode, Time, Raw);
                {error, Error}   -> evt_err_from_raw(Error, Time, Raw)
            end;
        {error, Error} ->
            evt_err_from_raw(Error, Time, Raw)
    end.

new_evt_time() ->
    calendar:datetime_to_gregorian_seconds(calendar:universal_time()).

evt_from_raw('undefined', NewNode, Time, Raw) ->
    evt_from_raw_2('undefined', NewNode, Time, Raw);
evt_from_raw(#mnode{name=OrgName}, NewNode, Time, Raw) ->
    evt_from_raw_2(OrgName, NewNode, Time, Raw).

evt_from_raw_2(OrgName, NewNode, Time, Raw) ->
    #evt{
        id       = Raw#evt_raw.id,
        type     = Raw#evt_raw.type,
        time     = Time,
        org_name = OrgName,
        node     = NewNode
    }.

evt_err_from_raw(Reason, Time, Raw) ->
    #evt_err{
        id        = Raw#evt_raw.id,
        type      = Raw#evt_raw.type,
        time      = Time,
        reason    = Reason
    }.

%% Check if a raw event's type is valid given the current 
%% state of the node in question.
check_orgnode('undefined', ?EVT_NODE_UP)       -> ok;
check_orgnode('undefined', _)                  -> {error, ?EVT_ERR_NOT_FOUND};
check_orgnode(#mnode{con=true}, ?EVT_NODE_UP)  -> {error, ?EVT_ERR_UP};
check_orgnode(#mnode{con=true}, _)             -> ok;
check_orgnode(#mnode{con=false}, ?EVT_NODE_UP) -> ok;
check_orgnode(#mnode{con=false}, _)            -> {error, ?EVT_ERR_DOWN}.

%% Create/modify the new state of the node. 
%% Also check for duplicate names when applicable.
form_newnode(_, OtherNodes, RawNode, ?EVT_NODE_UP) ->
    case is_dup_name(RawNode#mnode.name, OtherNodes) of
        true  -> {error, ?EVT_ERR_ALREADY_EXISTS};
        false -> new_connected_node(RawNode, OtherNodes)
    end;
form_newnode(OrgNode, OtherNodes, RawNode, ?EVT_NODE_EDIT) ->
    case is_dup_name(RawNode#mnode.name, OtherNodes) of
        true  -> {error, ?EVT_ERR_ALREADY_EXISTS};
        false -> edit_connected_node(OrgNode, RawNode)
    end;
form_newnode(OrgNode, _,_, ?EVT_NODE_DOWN) ->
    OrgNode#mnode{con = false, rank = 0};
form_newnode(OrgNode, _, RawNode, _) ->
    OrgNode#mnode{attribs = RawNode#mnode.attribs}.

new_connected_node(#mnode{ping=Ping, ttd=TTD}=RawNode, Nodes) ->
    RawNode#mnode{
        con  = true,
        rank = new_node_rank(Nodes),
        ping = def_if_zero(Ping, ?DEF_PING),
        ttd  = def_if_zero(TTD, ?DEF_TTD)
    }.

edit_connected_node(OrgNode, #mnode{ping=Ping, ttd=TTD}=RawNode) ->
    OrgNode#mnode{
        name = RawNode#mnode.name,
        prio = RawNode#mnode.prio,
        ping = def_if_zero(Ping, ?DEF_PING),
        ttd  = def_if_zero(TTD, ?DEF_TTD)
    }.

def_if_zero(0, Var) -> httpcluster:get_app_var(Var);
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

new_prim_res(
    #sec_msg{from=OrgName, last_evt=Time, get_nodes=Bool}, 
    Evts, Nodes, Hist
) ->
    #prim_res{
        to = OrgName,
        evts = Evts ++ get_hist_since(Time, Hist), 
        nodes = case Bool of
                    true  -> Nodes;
                    false -> 'undefined'
                end
    }.

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

%% Begin updating the nodes and history lists with the resulting evts.
update_state(Nodes1, Evts, #state{hist=Hist}=State) ->
    {Oks, _} = lists:partition(fun(#evt{}) -> true; (_) -> false end, Evts),
    State#state{
        nodes = Nodes1,
        hist  = httpcluster:apply_evt_to_hist(Oks, Hist)
    }.

