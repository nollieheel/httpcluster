%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc OTP app module.

-module(httpcluster_app).
-behaviour(application).

%% application callbacks
-export([start/2, stop/1]).

%% -----------------

%% @private
start(_StartType, _StartArgs) ->
    case httpcluster_sup:start_link(application:get_all_env()) of
        {ok, _}=Ok     -> Ok;
        {error, _}=Err -> Err;
        Err            -> {error, Err}
    end.

%% @private
stop(_State) ->
    ok.
