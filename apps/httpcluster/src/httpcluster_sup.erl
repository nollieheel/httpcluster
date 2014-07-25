%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Top-level supervisor.

-module(httpcluster_sup).
-behaviour(supervisor).

%% API
-export([start_link/1]).

%% supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Opt), 
    {I, {I, 'start_link', [Opt]}, 'permanent', 5000, Type, [I]}
).

%% -----------------

%% @private
start_link(Opts) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, Opts).

%% @private
init(Opts) ->
    {'ok', {{'one_for_one', 10, 10},
            [
             ?CHILD('httpcluster', 'worker', Opts),
             ?CHILD('httpcluster_sec', 'worker', Opts)
            ]
           }}.
