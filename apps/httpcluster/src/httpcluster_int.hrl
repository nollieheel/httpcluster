%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Internal definitions

%% App environment vars and common operations on them.
-define(DEF_PING,        'default_node_ping').
-define(DEF_TTD,         'default_node_ttd').
-define(HIST_LEN,        'evts_history_len').
-define(TTD_DELAY,       'ttd_delay_allow').
-define(MOD_COMS,        'comms_module').
-define(PING_RETRY_FREQ, 'evt_ping_retry_freq').
-define(PING_RETRY_TIME, 'evt_ping_retry_time').

-define(get_env(Var), element(2, application:get_env('httpcluster', Var))).
-define(apply_coms_fun(Fun, Args), apply(?get_env(?MOD_COMS), Fun, Args)).

%% Log handlers.
%%
%% If lager is used as parse_transform, it will, by default, redirect 
%% error_logger messages to itself. But it is better to explicitly use
%% lager functions here so that the nice "@MODULE:FUNCTION:LINE __" format is 
%% displayed.
%%
%% Still, error_logger is here if desired...
-define(log_debug(Str),         lager:debug(Str)).
-define(log_debug(Str, Args),   lager:debug(Str, Args)).
%-define(log_debug(Str),         error_logger:info_msg(Str)).
%-define(log_debug(Str, Args),   error_logger:info_msg(Str, Args)).

-define(log_info(Str),          lager:info(Str)).
-define(log_info(Str, Args),    lager:info(Str, Args)).
%-define(log_info(Str),          error_logger:info_msg(Str)).
%-define(log_info(Str, Args),    error_logger:info_msg(Str, Args)).

-define(log_warning(Str),       lager:warning(Str)).
-define(log_warning(Str, Args), lager:warning(Str, Args)).
%-define(log_warning(Str),       error_logger:warning_msg(Str)).
%-define(log_warning(Str, Args), error_logger:warning_msg(Str, Args)).

-define(log_error(Str),         lager:error(Str)).
-define(log_error(Str, Args),   lager:error(Str, Args)).
%-define(log_error(Str),         error_logger:error_msg(Str)).
%-define(log_error(Str, Args),   error_logger:error_msg(Str, Args)).

%% Functions implemented by the coms module:
-define(HANDLER_CREATE_PINGDATA, 'create_pingdata').
-define(HANDLER_PING_TO_NODE,    'ping_to_node').
-define(HANDLER_CREATE_PONGDATA, 'create_pongdata').
-define(HANDLER_PONG_TO_NODE,    'pong_to_node').
-define(HANDLER_CLUSTER_EVT,     'cluster_event').

-define(TTD_PRIM_DISC, 'primary_disc').
-define(TTD_SEC_DISC,  'secondary_disc').
-define(PING_ROUTINE,  'ping').
-define(PING_RETRY,    'ping_retry').
-define(PING_SYNC,     'ping_sync').
-define(PING_STALL,    'ping_stall').
%% The different kinds of {@link hc_timer:type()} values.
