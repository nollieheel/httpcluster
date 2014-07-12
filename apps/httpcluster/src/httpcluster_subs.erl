%%% Httpcluster "subscriber" processes list.
%%%
%%%
-module(httpcluster_subs).
-behaviour(gen_server).

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").

%% API
-export([
    add_proc/0,
    del_proc/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Internal API
-export([
    start_link/1,
    broadcast/1
]).

-define(SERVER, ?MODULE).


%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).


-spec broadcast(evt()) -> ok.
%% @doc Broadcast event to all subscribed processes.
broadcast(Evt) ->
    gen_server:cast(?SERVER, {'broadcast', Evt}).


-spec add_proc() -> boolean().
%% @doc Add calling process to subscriber processes list.
add_proc() ->
    Pid = self(),
    gen_server:call(?SERVER, {'add_proc', Pid}).


-spec del_proc() -> boolean().
%% @doc Remove calling process from subscriber processes list.
del_proc() ->
    Pid = self(),
    gen_server:call(?SERVER, {'del_proc', Pid}).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Opts]) ->
    {ok, []}.

handle_call({'add_proc', Pid}, _From, Pids) ->
    {Reply, Pids1} = case lists:member(Pid, Pids) of
        true  -> {false, Pids};
        false -> {true, [Pid|Pids]}
    end,
    {reply, Reply, Pids1};

handle_call({'del_proc', Pid}, _From, Pids) ->
    {Reply, Pids1} = case lists:member(Pid, Pids) of
        true  -> {true, lists:delete(Pid, Pids)};
        false -> {false, Pids}
    end,
    {reply, Reply, Pids1};

handle_call(_Msg, _From, State) ->
    {reply, 'undefined', State}.

handle_cast({'broadcast', Evt}, Pids) ->
    Pids1 = lists:filter(fun(Pid) ->
        case is_process_alive(Pid) of
            true  -> gen_server:cast(Pid, {'$cluster_event', Evt}), true;
            false -> false
        end
    end, Pids),
    {noreply, Pids1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
