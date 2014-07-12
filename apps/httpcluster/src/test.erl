%%% Default handler module for node communication functions.
%%%
%%%
-module(test).

%-include("httpcluster.hrl").

%% Default handlers
-compile(export_all).

-define(SEQ, 'seq').

-spec foo(string() | binary()) -> atom().
foo(S) ->
    case S of
        _ when is_binary(S) -> 'bin';
        _ -> 'list'
    end.

start() ->
    foo("dd"),
    foo(<<"aa">>).

seq() ->
    Mod = 'lists',
    Mod:?SEQ(1, 10).
