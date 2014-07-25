%%% @author nollieheel <iskitingbords@gmail.com>
%%% @copyright 2014, nollieheel
%%% @doc Public definitions

-define(EVT_NODE_UP,   "node_up").
-define(EVT_NODE_DOWN, "node_down").
-define(EVT_NODE_EDIT, "node_edit").
%% Built-in event types.
%%   "node_up"   :: Turns the node's connection to true. Also sets new values 
%%                  (overwrites) for the node name, attribs, priority, and TTD.
%%   "node_down" :: Turns the node's connection to false.
%%   "node_edit" :: Modifies the values for node name, priority, and TTD.

-define(EVT_ERR_DOWN,           'node_down').
-define(EVT_ERR_UP,             'node_up').
-define(EVT_ERR_NOT_FOUND,      'node_not_found').
-define(EVT_ERR_ALREADY_EXISTS, 'name_already_exists').
%% Built-in error values that can result from processing an event.
