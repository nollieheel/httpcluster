%%% The TTD timer used for node-monitoring.
%%%
%%%
-module(httpcluster_timer).
-behaviour(gen_server).

-include("httpcluster_int.hrl").
-include("httpcluster.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Internal API
-export([
    start_link/1,
    start/4,
    start_sec/1,
    stop_all/0
]).

-record(ttd_tmr, {
    mname   :: atom(),
    pid     :: pid(),
    type    :: ttd_type(),
    details :: mnode() | any()
}).
-type ttd_tmr() :: #ttd_tmr{}.

-record(state, {
    timers = [] :: [ttd_tmr()]
}).
%TODO if there's nothing else in state, then just turn this into a timer list

-define(SERVER, ?MODULE).


%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).


-spec start(atom(), integer(), ttd_type(), any()) -> ok.
%% @doc Starts a timer for one node, 
%%      if a similar timer is not already running.
start(Mname, TTD, Type, Details) ->
    gen_server:call(?SERVER, {'start', Mname, TTD, Type, Details}).


-spec start_sec([mnode()]) -> ok.
%% @doc Start secondary deadman timers for all provided nodes.
start_sec(SecNodes) ->
    gen_server:call(?SERVER, {'start_sec', SecNodes}).


-spec stop_all() -> ok.
%% @doc Stop all running ttd timers.
stop_all() ->
    gen_server:call(?SERVER, 'stop_all').


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Opts]) ->
    {ok, #state{}}.

handle_call({'start', Mname, TTD, Type, Details}, _From, 
            #state{timers=Tmrs}=State) ->
    Tmrs1 = start_timer(Mname, TTD, Type, Details, Tmrs),
    {reply, ok, State#state{timers = Tmrs1}};

handle_call({'start_sec', SecNodes}, _From, 
            #state{timers=Tmrs}=State) ->
    Tmrs1 = start_sec_timers(SecNodes, Tmrs),
    {reply, ok, State#state{timers = Tmrs1}};

handle_call('stop_all', _From, State) ->
    stop_all_ttd_timers(State#state.timers),
    {reply, ok, State#state{timers = []}};

handle_call(_Msg, _From, State) ->
    {reply, 'undefined', State}.

handle_cast({'$timer_timeout', _Pid}, State) ->
    %TODO
    {noreply, State};

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

-spec is_tmr_exists(atom(), ttd_type(), [ttd_tmr()]) -> boolean().
%% Check if a similar ttd timer is already running.
is_tmr_exists(Mname, Type, [#ttd_tmr{mname=Mname, type=Type}|_]) ->
    true;
is_tmr_exists(Mname, Type, [_|Tail]) ->
    is_tmr_exists(Mname, Type, Tail);
is_tmr_exists(_Mname, _Type, []) ->
    false.

-spec start_timer(atom(), integer(), ttd_type(), 
                  any(), [ttd_tmr()]) -> [ttd_tmr()].
%% Start a timer for Mname if it's not already started.
start_timer(Mname, TTD, Type, Details, Timers) ->
    case is_tmr_exists(Mname, Type, Timers) of
        true -> 
            Timers;
        false -> 
            TTD1 = case TTD of
                0 -> httpcluster:get_app_var(?DEF_TTD, ?DEF_DEF_TTD);
                _ -> TTD
            end,
            [new_timer(Mname, TTD1, Type, Details)|Timers]
    end.

-spec start_sec_timers([mnode()], [ttd_tmr()]) -> [ttd_tmr()].
%% Start secondary deadman timers for all provided nodes.
start_sec_timers(Secondaries, Timers) ->
    lists:foldl(fun(#mnode{mname=Name, ttd=TTD}, Acc) ->
        start_timer(Name, TTD, ?TTD_SEC_DISC, 'undefined', Acc)
    end, Timers, Secondaries).

-spec stop_all_ttd_timers([ttd_tmr()]) -> _.
stop_all_ttd_timers(Timers) ->
    lists:foreach(fun(#ttd_tmr{pid=Pid}) -> Pid ! '$timer_stop' end, Timers).

new_timer(Mname, TTD, Type, Details) ->
    #ttd_tmr{
        mname   = Mname,
        pid     = spawn_link(fun() -> timer_loop(TTD * 1000) end),
        type    = Type,
        details = Details
    }.

timer_loop(Timeout) ->
    receive
        '$timer_refresh' -> timer_loop(Timeout);
        '$timer_stop'    -> ok
    after Timeout ->
        gen_server:cast(?SERVER, {'$timer_timeout', self()})
    end.
