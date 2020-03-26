-define(COMMAND_PUBLISH, 0).
-define(COMMAND_PUBLISH_CONFIRM, 1).
-define(COMMAND_SUBSCRIBE, 2).
-define(COMMAND_DELIVER, 3).
-define(COMMAND_CREDIT, 4).
-define(COMMAND_UNSUBSCRIBE, 5).
-define(COMMAND_PUBLISH_ERROR, 6).
-define(COMMAND_METADATA_UPDATE, 7).
-define(COMMAND_METADATA, 8).
-define(COMMAND_SASL_HANDSHAKE, 9).
-define(COMMAND_SASL_AUTHENTICATE, 10).
-define(COMMAND_TUNE, 11).
-define(COMMAND_OPEN, 12).
-define(COMMAND_CLOSE, 13).
-define(COMMAND_CREATE_TARGET, 998).
-define(COMMAND_DELETE_TARGET, 999).

-define(VERSION_0, 0).

-define(RESPONSE_CODE_OK, 0).
-define(RESPONSE_CODE_TARGET_DOES_NOT_EXIST, 1).
-define(RESPONSE_CODE_SUBSCRIPTION_ID_ALREADY_EXISTS, 2).
-define(RESPONSE_CODE_SUBSCRIPTION_ID_DOES_NOT_EXIST, 3).
-define(RESPONSE_CODE_TARGET_ALREADY_EXISTS, 4).
-define(RESPONSE_CODE_TARGET_DELETED, 5).
-define(RESPONSE_SASL_MECHANISM_NOT_SUPPORTED, 6).
-define(RESPONSE_AUTHENTICATION_FAILURE, 7).
-define(RESPONSE_SASL_ERROR, 8).
-define(RESPONSE_SASL_CHALLENGE, 9).
-define(RESPONSE_SASL_AUTHENTICATION_FAILURE_LOOPBACK, 10).
-define(RESPONSE_VHOST_ACCESS_FAILURE, 11).