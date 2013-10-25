-module(beatnet_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case beatnet_sup:start_link(application:get_all_env()) of
        {ok, _}=Ok     -> Ok;
        {error, _}=Err -> Err;
        Err            -> {error, Err}
    end.

stop(_State) ->
    ok.
