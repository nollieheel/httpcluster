-module(httpcluster_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Opt), {I, {I, 'start_link', [Opt]}, 'permanent', 5000, Type, [I]}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

%% @private
start_link(Opts) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, Opts).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

%% @private
init(Opts) ->
    {'ok', {{'one_for_one', 10, 10},
            [
             ?CHILD('httpcluster', 'worker', Opts)
            ]
           }}.
