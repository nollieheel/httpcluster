-module(httpcluster).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Opts]) ->
    {ok, []}.

handle_call(_Msg, _From, State) ->
    {reply, 'whatever', State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
