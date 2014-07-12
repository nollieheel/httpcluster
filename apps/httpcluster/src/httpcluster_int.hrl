
%% App environment vars (integer values cannot be zero)
-define(HIST_LEN, 'history_len').
-define(DEF_PING, 'default_ping').
-define(DEF_TTD, 'default_ttd').
-define(MOD_COMS, 'coms_module').

%% Functions implemented by the coms module:
-define(HANDLER_CREATE_INITDATA, 'create_initdata').
-define(HANDLER_INIT_TO_NODE, 'init_to_node').
-define(HANDLER_TRANSLATE_INIT_REPLY, 'translate_init_reply').

-define(HANDLER_CREATE_PINGDATA, 'create_pingdata').
-define(HANDLER_PING_TO_NODE, 'ping_to_node').
-define(HANDLER_TRANSLATE_PING_REPLY, 'translate_ping_reply').

%% Default values of app vars (if none are provided)
-define(DEF_HIST_LEN, 20).
-define(DEF_DEF_PING, 60).
-define(DEF_DEF_TTD, 180).
-define(DEF_MOD_COMS, 'httpcluster_coms').

%% Different node ttd cases
-define(TTD_PRIM_DISC, 'primary_disc').
-define(TTD_PRIM_REDIR, 'primary_redir').
-define(TTD_SEC_DISC, 'secondary_disc').

-type ttd_type() :: ?TTD_SEC_DISC | ?TTD_PRIM_DISC | ?TTD_PRIM_REDIR.

%% Node roles
-define(ROLE_PRIM, 'primary').
-define(ROLE_SEC, 'secondary').
-define(ROLE_DISC, 'disconnected').

-type node_role() :: ?ROLE_PRIM | ?ROLE_SEC | ?ROLE_DISC.

