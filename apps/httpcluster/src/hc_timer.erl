%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Interface module for all cluster timer needs. Manipulate a timer
%%%      and timers container using this API. Use {@link empty/0} to
%%%      generate an empty container as a starting point.

-module(hc_timer).

-include("httpcluster_int.hrl").

%% API
-export([
    ping_routine_timer/2,
    ping_retry_timer/3,
    ping_stall_timer/2,
    empty/0,
    prim_disc_on/4,
    sec_disc_on/3,
    sec_disc_off/2,
    all_off/1,
    del_if_exists/2,
    is_equal/2,
    ident/1,
    type/1,
    details/1
]).

-export_type([type/0, timer/0, timers/0]).

%%====================================================================
%% Types
%%====================================================================

-type type() :: ?TTD_SEC_DISC | ?TTD_PRIM_DISC | 
                ?PING_ROUTINE | ?PING_RETRY | ?PING_STALL.
%% Atoms defining the timer types.

-type id() :: {term(), type()}.
%% A timer id. The 'timer identifier' is the first element in the tuple.

-record(timer, {
    id      :: id(),
    ttd     :: pos_integer(),
    details :: term(),
    pid     :: pid()
}).
-opaque timer()  :: #timer{}. 
%% A timer value. If it times out, it sends the message
%% ``{'$ttd_timeout', Timer}'' to its parent process.

-opaque timers() :: [#timer{}]. 
%% Container for timers.

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new `?PING_ROUTINE' timer.
-spec ping_routine_timer(Ident, Time) -> Timer
    when
        Ident :: term(),
        Time  :: pos_integer(),
        Timer :: timer().
ping_routine_timer(Ident, Time) ->
    start_new_timer(Ident, ?PING_ROUTINE, Time, 'undefined').

%% @doc Create a new `?PING_RETRY' timer. `RetryRef' is the reference
%%      of the previous ping attempt to be retried.
-spec ping_retry_timer(Ident, Time, RetryRef) -> Timer
    when
        Ident    :: term(),
        Time     :: pos_integer(),
        RetryRef :: term(),
        Timer    :: timer().
ping_retry_timer(Ident, Time, RetryRef) ->
    start_new_timer(Ident, ?PING_RETRY, Time, RetryRef).

%% @doc Create a new `?PING_STALL' timer.
-spec ping_stall_timer(Ident, Time) -> Timer
    when
        Ident :: term(),
        Time  :: pos_integer(),
        Timer :: timer().
ping_stall_timer(Ident, Time) ->
    start_new_timer(Ident, ?PING_STALL, Time, 'undefined').

%% @doc Return an empty timer list.
-spec empty() -> Empty
    when Empty :: timers().
empty() ->
    [].

%% @doc Add a new `?TTD_PRIM_DISC' timer to `Timers' 
%%      if it doesn't already exist.
-spec prim_disc_on(Ident, TTD, Details, Timers1) -> Timers2
    when
        Ident   :: term(),
        TTD     :: pos_integer(),
        Details :: term(),
        Timers1 :: timers(),
        Timers2 :: timers().
prim_disc_on(Ident, TTD, Details, Timers) ->
    start_or_ignore(Ident, ?TTD_PRIM_DISC, TTD, Details, Timers).

%% @doc Add a new `?TTD_SEC_DISC' timer to `Timers' if it doesn't already exist.
%%      Otherwise, send a refresh signal to it, possibly with a new `TTD'.
-spec sec_disc_on(Ident, TTD, Timers1) -> Timers2
    when
        Ident   :: term(),
        TTD     :: pos_integer(),
        Timers1 :: timers(),
        Timers2 :: timers().
sec_disc_on(Ident, TTD, Timers) ->
    start_or_refresh(Ident, ?TTD_SEC_DISC, TTD, 'undefined', Timers).

%% @doc Stop and delete a `?TTD_SEC_DISC' timer from `Timers' if it is there.
-spec sec_disc_off(Ident, Timers1) -> Timers2
    when 
        Ident   :: term(),
        Timers1 :: timers(),
        Timers2 :: timers().
sec_disc_off(Ident, Timers) ->
    stop_or_ignore(Ident, ?TTD_SEC_DISC, Timers).

%% @doc Stops all timers in the timers container. Then returns an 
%%      empty container. 
-spec all_off(Timers) -> Empty
    when Timers :: timers(), Empty :: timers().
all_off(Timers) ->
    [Pid ! {'$ttd_stop', self()} || #timer{pid=Pid} <- Timers],
    empty().

%% @doc Merely delete a timer from the list if it is there.
%%      It will not be turned off explicitly. Return value includes a boolean
%%      for whether the timer was in fact deleted or not.
-spec del_if_exists(Timer, Timers) -> Result
    when 
        Timer  :: timer(), 
        Timers :: timers(), 
        Result :: {boolean(), timers()}.
del_if_exists(Timer, Timers) -> 
    case lists:keytake(Timer#timer.id, #timer.id, Timers) of
        {'value', _, OtherTimers} -> {true, OtherTimers};
        false                     -> {false, Timers}
    end.

%% @doc Compare 2 timers. They are equal if their identifiers and types
%%      are the same.
-spec is_equal(Timer1, Timer2) -> IsEqual
    when Timer1 :: timer(), Timer2 :: timer(), IsEqual :: boolean().
is_equal(#timer{id=Id}, #timer{id=Id}) -> true;
is_equal(#timer{}, #timer{})           -> false.

%% @doc Get the identifier given with the timer.
-spec ident(Timer) -> Ident
    when Timer :: timer(), Ident :: term().
ident(#timer{id={Ident, _}}) ->
    Ident.

%% @doc Get the type of the timer.
-spec type(Timer) -> Type
    when Timer :: timer(), Type :: type().
type(#timer{id={_, Type}}) ->
    Type.

%% @doc Get the details given with the timer.
-spec details(Timer) -> Details
    when Timer :: timer(), Details :: term().
details(#timer{details=Details}) ->
    Details.

%%====================================================================
%% Internal functions
%%====================================================================

start_or_refresh(Ident, Type, TTD, Details, Timers) ->
    case lists:keyfind({Ident, Type}, #timer.id, Timers) of
        #timer{pid=Pid} ->
            Pid ! {'$ttd_refresh', TTD, self()},
            Timers;
        false ->
            [start_new_timer(Ident, Type, TTD, Details)|Timers]
    end.

start_or_ignore(Ident, Type, TTD, Details, Timers) ->
    case lists:keyfind({Ident, Type}, #timer.id, Timers) of
        #timer{} -> Timers;
        false    -> [start_new_timer(Ident, Type, TTD, Details)|Timers]
    end.

stop_or_ignore(Ident, Type, Timers) ->
    case lists:keytake({Ident, Type}, #timer.id, Timers) of
        {'value', #timer{pid=Pid}, OtherTimers} ->
            Pid ! {'$ttd_stop', self()},
            OtherTimers;
        false ->
            Timers
    end.

start_new_timer(Ident, Type, TTD, Details) ->
    Self = self(),
    Pid = spawn_link(
        fun() -> timer_init(Self, Ident, Type, TTD, Details) end
    ),
    to_timer_rec(Ident, Type, TTD, Details, Pid).

timer_init(Parent, Ident, Type, TTD, Details) ->
    timer_loop(Parent, to_timer_rec(Ident, Type, TTD, Details, self())).

timer_loop(Parent, Timer) ->
    receive
        {'$ttd_refresh', TTD, Parent} ->
            timer_loop(Parent, Timer#timer{ttd = TTD});
        {'$ttd_stop', Parent} ->
            ok
    after Timer#timer.ttd ->
        Parent ! {'$ttd_timeout', Timer}
    end.

to_timer_rec(Ident, Type, TTD, Details, Pid) ->
    #timer{id = {Ident, Type}, ttd = TTD, details = Details, pid = Pid}.
