-module(rabbit_stream_reader).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("rabbit_stream.hrl").

-record(stream_connection, {
    name,
    helper_sup,
    listen_socket, socket, clusters, data, consumers,
    target_subscriptions, credits,
    blocked,
    authentication_state, user, virtual_host,
    connection_step, % tcp_connected, authenticating, authenticated, tuning, tuned, opened, failure, closing, closing_done
    frame_max,
    heartbeater
}).

-record(consumer, {
    socket, leader, offset, subscription_id, segment, credit, target
}).

-record(configuration, {
    initial_credits, credits_required_for_unblocking,
    frame_max, heartbeat
}).

-define(RESPONSE_FRAME_SIZE, 10). % 2 (key) + 2 (version) + 4 (correlation ID) + 2 (response code)

%% API
-export([start_link/4, init/1]).

start_link(KeepaliveSup, Transport, Ref, Opts) ->
    Pid = proc_lib:spawn_link(?MODULE, init,
        [[KeepaliveSup, Transport, Ref, Opts]]),

    {ok, Pid}.

init([KeepaliveSup, Transport, Ref, #{initial_credits := InitialCredits,
    credits_required_for_unblocking := CreditsRequiredBeforeUnblocking,
    frame_max := FrameMax,
    heartbeat := Heartbeat}]) ->
    process_flag(trap_exit, true),
    {ok, Sock} = rabbit_networking:handshake(Ref,
        application:get_env(rabbitmq_mqtt, proxy_protocol, false)),
    RealSocket = rabbit_net:unwrap_socket(Sock),
    case rabbit_net:connection_string(Sock, inbound) of
        {ok, ConnStr} ->
            rabbit_stream_manager:register(),
            Credits = atomics:new(1, [{signed, true}]),
            init_credit(Credits, InitialCredits),
            State = #stream_connection{
                name = ConnStr,
                helper_sup = KeepaliveSup,
                socket = RealSocket, data = none,
                clusters = #{},
                consumers = #{}, target_subscriptions = #{},
                blocked = false, credits = Credits,
                authentication_state = none, user = none,
                connection_step = tcp_connected,
                frame_max = FrameMax},
            Transport:setopts(RealSocket, [{active, once}]),

            listen_loop_pre_auth(Transport, State, #configuration{
                initial_credits = InitialCredits,
                credits_required_for_unblocking = CreditsRequiredBeforeUnblocking,
                frame_max = FrameMax,
                heartbeat = Heartbeat
            });
        {Error, Reason} ->
            rabbit_net:fast_close(RealSocket),
            error_logger:warning_msg("Closing connection because of ~p ~p~n", [Error, Reason])
    end.

init_credit(CreditReference, Credits) ->
    atomics:put(CreditReference, 1, Credits).

sub_credits(CreditReference, Credits) ->
    atomics:sub(CreditReference, 1, Credits).

add_credits(CreditReference, Credits) ->

    atomics:add(CreditReference, 1, Credits).

has_credits(CreditReference) ->
    atomics:get(CreditReference, 1) > 0.

has_enough_credits_to_unblock(CreditReference, CreditsRequiredForUnblocking) ->
    atomics:get(CreditReference, 1) > CreditsRequiredForUnblocking.

listen_loop_pre_auth(Transport, #stream_connection{socket = S} = State,
    #configuration{frame_max = FrameMax, heartbeat = Heartbeat} = Configuration) ->
    {OK, Closed, Error} = Transport:messages(),
    %% FIXME introduce timeout to complete the connection opening (after block should be enough)
    receive
        {OK, S, Data} ->
            #stream_connection{connection_step = ConnectionStep0} = State,
            State1 = handle_inbound_data_pre_auth(Transport, State, Data),
            Transport:setopts(S, [{active, once}]),
            #stream_connection{connection_step = ConnectionStep} = State1,
            error_logger:info_msg("Transitioned from ~p to ~p~n", [ConnectionStep0, ConnectionStep]),
            case ConnectionStep of
                authenticated ->
                    TuneFrame = <<?COMMAND_TUNE:16, ?VERSION_0:16, FrameMax:32, Heartbeat:32>>,
                    frame(Transport, State1, TuneFrame),
                    listen_loop_pre_auth(Transport, State1#stream_connection{connection_step = tuning}, Configuration);
                opened ->
                    listen_loop_post_auth(Transport, State1, Configuration);
                failure ->
                    close(Transport, S);
                _ ->
                    listen_loop_pre_auth(Transport, State1, Configuration)
            end;
        {Closed, S} ->
            error_logger:info_msg("Socket ~w closed [~w]~n", [S, self()]),
            ok;
        {Error, S, Reason} ->
            error_logger:info_msg("Socket error ~p [~w]~n", [Reason, S, self()]);
        M ->
            error_logger:warning_msg("Unknown message ~p~n", [M]),
            close(Transport, S)
    end.

close(Transport, S) ->
    Transport:shutdown(S, write),
    Transport:close(S).

listen_loop_post_auth(Transport, #stream_connection{socket = S, consumers = Consumers,
    target_subscriptions = TargetSubscriptions, credits = Credits, blocked = Blocked, heartbeater = Heartbeater} = State,
    #configuration{credits_required_for_unblocking = CreditsRequiredForUnblocking} = Configuration) ->
    {OK, Closed, Error} = Transport:messages(),
    receive
        {OK, S, Data} ->
            #stream_connection{connection_step = Step} = State1 = handle_inbound_data_post_auth(Transport, State, Data),
            case Step of
                closing ->
                    close(Transport, S);
                close_sent ->
                    listen_loop_post_close(Transport, State1, Configuration);
                _ ->
                    State2 = case Blocked of
                                 true ->
                                     case has_enough_credits_to_unblock(Credits, CreditsRequiredForUnblocking) of
                                         true ->
                                             Transport:setopts(S, [{active, once}]),
                                             ok = rabbit_heartbeat:resume_monitor(Heartbeater),
                                             State1#stream_connection{blocked = false};
                                         false ->
                                             State1
                                     end;
                                 false ->
                                     case has_credits(Credits) of
                                         true ->
                                             Transport:setopts(S, [{active, once}]),
                                             State1;
                                         false ->
                                             ok = rabbit_heartbeat:pause_monitor(Heartbeater),
                                             State1#stream_connection{blocked = true}
                                     end
                             end,
                    listen_loop_post_auth(Transport, State2, Configuration)
            end;
        {stream_manager, cluster_deleted, ClusterReference} ->
            Target = list_to_binary(ClusterReference),
            State1 = case clean_state_after_target_deletion(Target, State) of
                         {cleaned, NewState} ->
                             TargetSize = byte_size(Target),
                             FrameSize = 2 + 2 + 2 + 2 + TargetSize,
                             Transport:send(S, [<<FrameSize:32, ?COMMAND_METADATA_UPDATE:16, ?VERSION_0:16,
                                 ?RESPONSE_CODE_TARGET_DELETED:16, TargetSize:16, Target/binary>>]),
                             NewState;
                         {not_cleaned, SameState} ->
                             SameState
                     end,
            listen_loop_post_auth(Transport, State1, Configuration);
        {osiris_written, _Name, CorrelationIdList} ->
            CorrelationIdBinaries = [<<CorrelationId:64>> || CorrelationId <- CorrelationIdList],
            CorrelationIdCount = length(CorrelationIdList),
            FrameSize = 2 + 2 + 4 + CorrelationIdCount * 8,
            %% FIXME enforce max frame size
            %% in practice, this should be necessary only for very large chunks and for very small frame size limits
            Transport:send(S, [<<FrameSize:32, ?COMMAND_PUBLISH_CONFIRM:16, ?VERSION_0:16>>, <<CorrelationIdCount:32>>, CorrelationIdBinaries]),
            add_credits(Credits, CorrelationIdCount),
            State1 = case Blocked of
                         true ->
                             case has_enough_credits_to_unblock(Credits, CreditsRequiredForUnblocking) of
                                 true ->
                                     Transport:setopts(S, [{active, once}]),
                                     ok = rabbit_heartbeat:resume_monitor(Heartbeater),
                                     State#stream_connection{blocked = false};
                                 false ->
                                     State
                             end;
                         false ->
                             State
                     end,
            listen_loop_post_auth(Transport, State1, Configuration);
        {osiris_offset, TargetName, -1} ->
            error_logger:info_msg("received osiris offset event for ~p with offset ~p~n", [TargetName, -1]),
            listen_loop_post_auth(Transport, State, Configuration);
        {osiris_offset, TargetName, Offset} when Offset > -1 ->
            State1 = case maps:get(TargetName, TargetSubscriptions, undefined) of
                         undefined ->
                             error_logger:info_msg("osiris offset event for ~p, but no subscription (leftover messages after unsubscribe?)", [TargetName]),
                             State;
                         [] ->
                             error_logger:info_msg("osiris offset event for ~p, but no registered consumers!", [TargetName]),
                             State#stream_connection{target_subscriptions = maps:remove(TargetName, TargetSubscriptions)};
                         CorrelationIds when is_list(CorrelationIds) ->
                             Consumers1 = lists:foldl(fun(CorrelationId, ConsumersAcc) ->
                                 #{CorrelationId := Consumer} = ConsumersAcc,
                                 #consumer{credit = Credit} = Consumer,
                                 Consumer1 = case Credit of
                                                 0 ->
                                                     Consumer;
                                                 _ ->
                                                     {{segment, Segment1}, {credit, Credit1}} = send_chunks(
                                                         Transport,
                                                         Consumer
                                                     ),
                                                     Consumer#consumer{segment = Segment1, credit = Credit1}
                                             end,
                                 ConsumersAcc#{CorrelationId => Consumer1}
                                                      end,
                                 Consumers,
                                 CorrelationIds),
                             State#stream_connection{consumers = Consumers1}
                     end,
            listen_loop_post_auth(Transport, State1, Configuration);
        {heartbeat_send_error, Reason} ->
            error_logger:info_msg("Heartbeat send error ~p, closing connection~n", [Reason]),
            rabbit_stream_manager:unregister(),
            close(Transport, S);
        heartbeat_timeout ->
            error_logger:info_msg("Heartbeat timeout, closing connection~n"),
            rabbit_stream_manager:unregister(),
            close(Transport, S);
        {Closed, S} ->
            rabbit_stream_manager:unregister(),
            error_logger:info_msg("Socket ~w closed [~w]~n", [S, self()]),
            ok;
        {Error, S, Reason} ->
            rabbit_stream_manager:unregister(),
            error_logger:info_msg("Socket error ~p [~w]~n", [Reason, S, self()]);
        M ->
            error_logger:warning_msg("Unknown message ~p~n", [M]),
            %% FIXME send close
            listen_loop_post_auth(Transport, State, Configuration)
    end.

listen_loop_post_close(Transport, #stream_connection{socket = S} = State, Configuration) ->
    {OK, Closed, Error} = Transport:messages(),
    %% FIXME introduce timeout to complete the connection closing (after block should be enough)
    receive
        {OK, S, Data} ->
            #stream_connection{connection_step = Step} = State1 = handle_inbound_data_post_close(Transport, State, Data),
            case Step of
                closing_done ->
                    error_logger:info_msg("Received close confirmation from client"),
                    close(Transport, S);
                _ ->
                    Transport:setopts(S, [{active, once}]),
                    listen_loop_post_close(Transport, State1, Configuration)
            end;
        {Closed, S} ->
            error_logger:info_msg("Socket ~w closed [~w]~n", [S, self()]),
            ok;
        {Error, S, Reason} ->
            error_logger:info_msg("Socket error ~p [~w]~n", [Reason, S, self()]);
        M ->
            error_logger:warning_msg("Ignored message on closing ~p~n", [M])
    end.

handle_inbound_data_pre_auth(Transport, State, Rest) ->
    handle_inbound_data(Transport, State, Rest, fun handle_frame_pre_auth/4).

handle_inbound_data_post_auth(Transport, State, Rest) ->
    handle_inbound_data(Transport, State, Rest, fun handle_frame_post_auth/4).

handle_inbound_data_post_close(Transport, State, Rest) ->
    handle_inbound_data(Transport, State, Rest, fun handle_frame_post_close/4).

handle_inbound_data(_Transport, State, <<>>, _HandleFrameFun) ->
    State;
handle_inbound_data(Transport, #stream_connection{data = none, frame_max = FrameMax} = State, <<Size:32, _Frame:Size/binary, _Rest/bits>>, _HandleFrameFun)
    when FrameMax /= 0 andalso Size > FrameMax - 4 ->
    CloseReason = <<"frame too large">>,
    CloseReasonLength = byte_size(CloseReason),
    CloseFrame = <<?COMMAND_CLOSE:16, ?VERSION_0:16, 1:32, ?RESPONSE_CODE_FRAME_TOO_LARGE:16,
        CloseReasonLength:16, CloseReason:CloseReasonLength/binary>>,
    frame(Transport, State, CloseFrame),
    State#stream_connection{connection_step = close_sent};
handle_inbound_data(Transport, #stream_connection{data = none} = State, <<Size:32, Frame:Size/binary, Rest/bits>>, HandleFrameFun) ->
    {State1, Rest1} = HandleFrameFun(Transport, State, Frame, Rest),
    handle_inbound_data(Transport, State1, Rest1, HandleFrameFun);
handle_inbound_data(_Transport, #stream_connection{data = none} = State, Data, _HandleFrameFun) ->
    State#stream_connection{data = Data};
handle_inbound_data(Transport, #stream_connection{data = Leftover} = State, Data, HandleFrameFun) ->
    State1 = State#stream_connection{data = none},
    %% FIXME avoid concatenation to avoid a new binary allocation
    %% see osiris_replica:parse_chunk/3
    handle_inbound_data(Transport, State1, <<Leftover/binary, Data/binary>>, HandleFrameFun).

write_messages(_ClusterLeader, <<>>) ->
    ok;
write_messages(ClusterLeader, <<PublishingId:64, MessageSize:32, Message:MessageSize/binary, Rest/binary>>) ->
    % FIXME handle write error
    ok = osiris:write(ClusterLeader, PublishingId, Message),
    write_messages(ClusterLeader, Rest).

generate_publishing_error_details(Acc, <<>>) ->
    Acc;
generate_publishing_error_details(Acc, <<PublishingId:64, MessageSize:32, _Message:MessageSize/binary, Rest/binary>>) ->
    generate_publishing_error_details(
        <<Acc/binary, PublishingId:64, ?RESPONSE_CODE_TARGET_DOES_NOT_EXIST:16>>,
        Rest).

handle_frame_pre_auth(Transport, #stream_connection{socket = S} = State,
    <<?COMMAND_SASL_HANDSHAKE:16, ?VERSION_0:16, CorrelationId:32>>, Rest) ->

    Mechanisms = auth_mechanisms(S),
    MechanismsFragment = lists:foldl(fun(M, Acc) ->
        Size = byte_size(M),
        <<Acc/binary, Size:16, M:Size/binary>>
                                     end, <<>>, Mechanisms),
    MechanismsCount = length(Mechanisms),
    Frame = <<?COMMAND_SASL_HANDSHAKE:16, ?VERSION_0:16, CorrelationId:32, ?RESPONSE_CODE_OK:16,
        MechanismsCount:32, MechanismsFragment/binary>>,
    FrameSize = byte_size(Frame),

    Transport:send(S, [<<FrameSize:32>>, <<Frame/binary>>]),
    {State, Rest};
handle_frame_pre_auth(Transport, #stream_connection{socket = S, authentication_state = AuthState0} = State,
    <<?COMMAND_SASL_AUTHENTICATE:16, ?VERSION_0:16, CorrelationId:32,
        MechanismLength:16, Mechanism:MechanismLength/binary,
        SaslFragment/binary>>, Rest) ->

    SaslBin = case SaslFragment of
                  <<-1:32/signed>> ->
                      <<>>;
                  <<SaslBinaryLength:32, SaslBinary:SaslBinaryLength/binary>> ->
                      SaslBinary
              end,

    {State1, Rest1} = case auth_mechanism_to_module(Mechanism, S) of
                          {ok, AuthMechanism} ->
                              AuthState = case AuthState0 of
                                              none ->
                                                  AuthMechanism:init(S);
                                              AS ->
                                                  AS
                                          end,
                              {S1, FrameFragment} = case AuthMechanism:handle_response(SaslBin, AuthState) of
                                                        {refused, _Username, Msg, Args} ->
                                                            error_logger:warning_msg(Msg, Args),
                                                            {State#stream_connection{connection_step = failure}, <<?RESPONSE_AUTHENTICATION_FAILURE:16>>};
                                                        {protocol_error, Msg, Args} ->
                                                            error_logger:warning_msg(Msg, Args),
                                                            {State#stream_connection{connection_step = failure}, <<?RESPONSE_SASL_ERROR:16>>};
                                                        {challenge, Challenge, AuthState1} ->
                                                            ChallengeSize = byte_size(Challenge),
                                                            {State#stream_connection{authentication_state = AuthState1, connection_step = authenticating},
                                                                <<?RESPONSE_SASL_CHALLENGE:16, ChallengeSize:32, Challenge/binary>>
                                                            };
                                                        {ok, User = #user{username = Username}} ->
                                                            case rabbit_access_control:check_user_loopback(Username, S) of
                                                                ok ->
                                                                    {State#stream_connection{authentication_state = done, user = User, connection_step = authenticated},
                                                                        <<?RESPONSE_CODE_OK:16>>
                                                                    };
                                                                not_allowed ->
                                                                    error_logger:warning_msg("User '~s' can only connect via localhost~n", [Username]),
                                                                    {State#stream_connection{connection_step = failure}, <<?RESPONSE_SASL_AUTHENTICATION_FAILURE_LOOPBACK:16>>}
                                                            end
                                                    end,
                              Frame = <<?COMMAND_SASL_AUTHENTICATE:16, ?VERSION_0:16, CorrelationId:32, FrameFragment/binary>>,
                              frame(Transport, S1, Frame),
                              {S1, Rest};
                          {error, _} ->
                              Frame = <<?COMMAND_SASL_AUTHENTICATE:16, ?VERSION_0:16, CorrelationId:32, ?RESPONSE_SASL_MECHANISM_NOT_SUPPORTED:16>>,
                              frame(Transport, State, Frame),
                              {State#stream_connection{connection_step = failure}, Rest}
                      end,

    {State1, Rest1};
handle_frame_pre_auth(Transport, #stream_connection{helper_sup = SupPid, socket = Sock, name = ConnectionName} = State,
    <<?COMMAND_TUNE:16, ?VERSION_0:16, FrameMax:32, Heartbeat:32>>, Rest) ->
    error_logger:info_msg("Tuning response ~p ~p ~n", [FrameMax, Heartbeat]),


    Frame = <<?COMMAND_HEARTBEAT:16, ?VERSION_0:16>>,
    Parent = self(),
    SendFun =
        fun() ->
            case catch frame(Transport, State, Frame) of
                ok ->
                    ok;
                {error, Reason} ->
                    Parent ! {heartbeat_send_error, Reason};
                Unexpected ->
                    Parent ! {heartbeat_send_error, Unexpected}
            end,
            ok
        end,
    ReceiveFun = fun() -> Parent ! heartbeat_timeout end,
    Heartbeater = rabbit_heartbeat:start(
        SupPid, Sock, ConnectionName,
        Heartbeat, SendFun, Heartbeat, ReceiveFun),


    {State#stream_connection{connection_step = tuned, frame_max = FrameMax, heartbeater = Heartbeater}, Rest};
handle_frame_pre_auth(Transport, #stream_connection{user = User, socket = S} = State, <<?COMMAND_OPEN:16, ?VERSION_0:16, CorrelationId:32,
    VirtualHostLength:16, VirtualHost:VirtualHostLength/binary>>, Rest) ->

    %% FIXME enforce connection limit (see rabbit_reader:is_over_connection_limit/2)

    {State1, Frame} = try
                          case rabbit_access_control:check_vhost_access(User, VirtualHost, {socket, S}, #{}) of
                              ok ->
                                  F = <<?COMMAND_OPEN:16, ?VERSION_0:16, CorrelationId:32, ?RESPONSE_CODE_OK:16>>,
                                  %% FIXME check if vhost is alive (see rabbit_reader:is_vhost_alive/2)
                                  {State#stream_connection{connection_step = opened, virtual_host = VirtualHost}, F};
                              _ ->
                                  F = <<?COMMAND_OPEN:16, ?VERSION_0:16, CorrelationId:32, ?RESPONSE_VHOST_ACCESS_FAILURE:16>>,
                                  {State#stream_connection{connection_step = failure}, F}
                          end
                      catch
                          exit:_ ->
                              Fr = <<?COMMAND_OPEN:16, ?VERSION_0:16, CorrelationId:32, ?RESPONSE_VHOST_ACCESS_FAILURE:16>>,
                              {State#stream_connection{connection_step = failure}, Fr}
                      end,

    frame(Transport, State, Frame),

    {State1, Rest};
handle_frame_pre_auth(_Transport, State, <<?COMMAND_HEARTBEAT:16, ?VERSION_0:16>>, Rest) ->
    error_logger:info_msg("Received heartbeat frame pre auth~n"),
    {State, Rest};
handle_frame_pre_auth(_Transport, State, Frame, Rest) ->
    error_logger:warning_msg("unknown frame ~p ~p, closing connection.~n", [Frame, Rest]),
    {State#stream_connection{connection_step = failure}, Rest}.

handle_frame_post_auth(Transport, #stream_connection{socket = S, credits = Credits} = State,
    <<?COMMAND_PUBLISH:16, ?VERSION_0:16,
        TargetSize:16, Target:TargetSize/binary,
        MessageCount:32, Messages/binary>>, Rest) ->
    case lookup_cluster(Target, State) of
        cluster_not_found ->
            FrameSize = 2 + 2 + 4 + (8 + 2) * MessageCount,
            Details = generate_publishing_error_details(<<>>, Messages),
            Transport:send(S, [<<FrameSize:32, ?COMMAND_PUBLISH_ERROR:16, ?VERSION_0:16,
                MessageCount:32, Details/binary>>]),
            {State, Rest};
        {ClusterLeader, State1} ->
            write_messages(ClusterLeader, Messages),
            sub_credits(Credits, MessageCount),
            {State1, Rest}
    end;
handle_frame_post_auth(Transport, #stream_connection{socket = Socket, consumers = Consumers, target_subscriptions = TargetSubscriptions} = State,
    <<?COMMAND_SUBSCRIBE:16, ?VERSION_0:16, CorrelationId:32, SubscriptionId:32, TargetSize:16, Target:TargetSize/binary, Offset:64/unsigned, Credit:16>>, Rest) ->
    case lookup_cluster(Target, State) of
        cluster_not_found ->
            response(Transport, State, ?COMMAND_SUBSCRIBE, CorrelationId, ?RESPONSE_CODE_TARGET_DOES_NOT_EXIST),
            {State, Rest};
        {ClusterLeader, State1} ->
            % offset message uses a list for the target, so storing this in the state for easier retrieval
            TargetKey = binary_to_list(Target),
            case subscription_exists(TargetSubscriptions, SubscriptionId) of
                true ->
                    response(Transport, State1, ?COMMAND_SUBSCRIBE, CorrelationId, ?RESPONSE_CODE_SUBSCRIPTION_ID_ALREADY_EXISTS),
                    {State1, Rest};
                false ->
                    %% FIXME handle different type of offset (first, last, next, {abs, ...})
                    {ok, Segment} = osiris:init_reader(ClusterLeader, Offset),
                    ConsumerState = #consumer{
                        leader = ClusterLeader, offset = Offset, subscription_id = SubscriptionId, socket = Socket,
                        segment = Segment,
                        credit = Credit,
                        target = TargetKey
                    },
                    error_logger:info_msg("registering consumer ~p in ~p~n", [ConsumerState, self()]),

                    response_ok(Transport, State1, ?COMMAND_SUBSCRIBE, CorrelationId),

                    {{segment, Segment1}, {credit, Credit1}} = send_chunks(
                        Transport,
                        ConsumerState
                    ),
                    Consumers1 = Consumers#{SubscriptionId => ConsumerState#consumer{segment = Segment1, credit = Credit1}},

                    TargetSubscriptions1 =
                        case TargetSubscriptions of
                            #{TargetKey := SubscriptionIds} ->
                                TargetSubscriptions#{TargetKey => [SubscriptionId] ++ SubscriptionIds};
                            _ ->
                                TargetSubscriptions#{TargetKey => [SubscriptionId]}
                        end,
                    {State1#stream_connection{consumers = Consumers1, target_subscriptions = TargetSubscriptions1}, Rest}
            end
    end;
handle_frame_post_auth(Transport, #stream_connection{consumers = Consumers, target_subscriptions = TargetSubscriptions, clusters = Clusters} = State,
    <<?COMMAND_UNSUBSCRIBE:16, ?VERSION_0:16, CorrelationId:32, SubscriptionId:32>>, Rest) ->
    case subscription_exists(TargetSubscriptions, SubscriptionId) of
        false ->
            response(Transport, State, ?COMMAND_UNSUBSCRIBE, CorrelationId, ?RESPONSE_CODE_SUBSCRIPTION_ID_DOES_NOT_EXIST),
            {State, Rest};
        true ->
            #{SubscriptionId := Consumer} = Consumers,
            Target = Consumer#consumer.target,
            #{Target := SubscriptionsForThisTarget} = TargetSubscriptions,
            SubscriptionsForThisTarget1 = lists:delete(SubscriptionId, SubscriptionsForThisTarget),
            {TargetSubscriptions1, Clusters1} =
                case length(SubscriptionsForThisTarget1) of
                    0 ->
                        %% no more subscriptions for this target
                        {maps:remove(Target, TargetSubscriptions),
                            maps:remove(list_to_binary(Target), Clusters)
                        };
                    _ ->
                        {TargetSubscriptions#{Target => SubscriptionsForThisTarget1}, Clusters}
                end,
            Consumers1 = maps:remove(SubscriptionId, Consumers),
            response_ok(Transport, State, ?COMMAND_SUBSCRIBE, CorrelationId),
            {State#stream_connection{consumers = Consumers1,
                target_subscriptions = TargetSubscriptions1,
                clusters = Clusters1
            }, Rest}
    end;
handle_frame_post_auth(Transport, #stream_connection{consumers = Consumers} = State,
    <<?COMMAND_CREDIT:16, ?VERSION_0:16, SubscriptionId:32, Credit:16>>, Rest) ->

    case Consumers of
        #{SubscriptionId := Consumer} ->
            #consumer{credit = AvailableCredit} = Consumer,

            {{segment, Segment1}, {credit, Credit1}} = send_chunks(
                Transport,
                Consumer,
                AvailableCredit + Credit
            ),

            Consumer1 = Consumer#consumer{segment = Segment1, credit = Credit1},
            {State#stream_connection{consumers = Consumers#{SubscriptionId => Consumer1}}, Rest};
        _ ->
            %% FIXME find a way to tell the client it's crediting an unknown subscription
            error_logger:warning_msg("Giving credit to unknown subscription: ~p~n", [SubscriptionId]),
            {State, Rest}
    end;
handle_frame_post_auth(Transport, State,
    <<?COMMAND_CREATE_TARGET:16, ?VERSION_0:16, CorrelationId:32, TargetSize:16, Target:TargetSize/binary>>, Rest) ->
    case rabbit_stream_manager:create(binary_to_list(Target)) of
        {ok, #{leader_pid := LeaderPid, replica_pids := ReturnedReplicas}} ->
            error_logger:info_msg("Created cluster with leader ~p and replicas ~p~n", [LeaderPid, ReturnedReplicas]),
            response_ok(Transport, State, ?COMMAND_CREATE_TARGET, CorrelationId),
            {State, Rest};
        {error, reference_already_exists} ->
            response(Transport, State, ?COMMAND_CREATE_TARGET, CorrelationId, ?RESPONSE_CODE_TARGET_ALREADY_EXISTS),
            {State, Rest}
    end;
handle_frame_post_auth(Transport, #stream_connection{socket = S} = State,
    <<?COMMAND_DELETE_TARGET:16, ?VERSION_0:16, CorrelationId:32, TargetSize:16, Target:TargetSize/binary>>, Rest) ->
    case rabbit_stream_manager:delete(binary_to_list(Target)) of
        {ok, deleted} ->
            response_ok(Transport, State, ?COMMAND_DELETE_TARGET, CorrelationId),
            State1 = case clean_state_after_target_deletion(Target, State) of
                         {cleaned, NewState} ->
                             TargetSize = byte_size(Target),
                             FrameSize = 2 + 2 + 2 + 2 + TargetSize,
                             Transport:send(S, [<<FrameSize:32, ?COMMAND_METADATA_UPDATE:16, ?VERSION_0:16,
                                 ?RESPONSE_CODE_TARGET_DELETED:16, TargetSize:16, Target/binary>>]),
                             NewState;
                         {not_cleaned, SameState} ->
                             SameState
                     end,
            {State1, Rest};
        {error, reference_not_found} ->
            response(Transport, State, ?COMMAND_DELETE_TARGET, CorrelationId, ?RESPONSE_CODE_TARGET_DOES_NOT_EXIST),
            {State, Rest}
    end;
handle_frame_post_auth(Transport, #stream_connection{socket = S} = State,
    <<?COMMAND_METADATA:16, ?VERSION_0:16, CorrelationId:32, TargetCount:32, BinaryTargets/binary>>, Rest) ->
    %% FIXME: rely only on rabbit_networking to discover the listeners
    Nodes = rabbit_mnesia:cluster_nodes(all),
    {NodesInfo, _} = lists:foldl(fun(Node, {Acc, Index}) ->
        {ok, Host} = rpc:call(Node, inet, gethostname, []),
        Port = rpc:call(Node, rabbit_stream, port, []),
        {Acc#{Node => {{index, Index}, {host, list_to_binary(Host)}, {port, Port}}}, Index + 1}
                                 end, {#{}, 0}, Nodes),

    BrokersCount = length(Nodes),
    BrokersBin = maps:fold(fun(_K, {{index, Index}, {host, Host}, {port, Port}}, Acc) ->
        HostLength = byte_size(Host),
        <<Acc/binary, Index:16, HostLength:16, Host:HostLength/binary, Port:32>>
                           end, <<BrokersCount:32>>, NodesInfo),

    Targets = extract_target_list(BinaryTargets, []),

    MetadataBin = lists:foldl(fun(Target, Acc) ->
        TargetLength = byte_size(Target),
        case lookup_cluster(Target, State) of
            cluster_not_found ->
                <<Acc/binary, TargetLength:16, Target:TargetLength/binary, ?RESPONSE_CODE_TARGET_DOES_NOT_EXIST:16,
                    -1:16, 0:32>>;
            {Cluster, _} ->
                LeaderNode = node(Cluster),
                #{LeaderNode := NodeInfo} = NodesInfo,
                {{index, LeaderIndex}, {host, _}, {port, _}} = NodeInfo,
                Replicas = maps:without([LeaderNode], NodesInfo),
                ReplicasBinary = lists:foldl(fun(NI, Bin) ->
                    {{index, ReplicaIndex}, {host, _}, {port, _}} = NI,
                    <<Bin/binary, ReplicaIndex:16>>
                                             end, <<>>, maps:values(Replicas)),
                ReplicasCount = maps:size(Replicas),

                <<Acc/binary, TargetLength:16, Target:TargetLength/binary, ?RESPONSE_CODE_OK:16,
                    LeaderIndex:16, ReplicasCount:32, ReplicasBinary/binary>>
        end

                              end, <<TargetCount:32>>, Targets),
    Frame = <<?COMMAND_METADATA:16, ?VERSION_0:16, CorrelationId:32, BrokersBin/binary, MetadataBin/binary>>,
    FrameSize = byte_size(Frame),
    Transport:send(S, <<FrameSize:32, Frame/binary>>),
    {State, Rest};
handle_frame_post_auth(Transport, State,
    <<?COMMAND_CLOSE:16, ?VERSION_0:16, CorrelationId:32,
        ClosingCode:16, ClosingReasonLength:16, ClosingReason:ClosingReasonLength/binary>>, _Rest) ->
    error_logger:info_msg("Received close command ~p ~p~n", [ClosingCode, ClosingReason]),
    Frame = <<?COMMAND_CLOSE:16, ?VERSION_0:16, CorrelationId:32, ?RESPONSE_CODE_OK:16>>,
    frame(Transport, State, Frame),
    {State#stream_connection{connection_step = closing}, <<>>}; %% we ignore any subsequent frames
handle_frame_post_auth(_Transport, State, <<?COMMAND_HEARTBEAT:16, ?VERSION_0:16>>, Rest) ->
    error_logger:info_msg("Received heartbeat frame post auth~n"),
    {State, Rest};
handle_frame_post_auth(Transport, State, Frame, Rest) ->
    error_logger:warning_msg("unknown frame ~p ~p, sending close command.~n", [Frame, Rest]),
    CloseReason = <<"unknown frame">>,
    CloseReasonLength = byte_size(CloseReason),
    CloseFrame = <<?COMMAND_CLOSE:16, ?VERSION_0:16, 1:32, ?RESPONSE_CODE_UNKNOWN_FRAME:16,
        CloseReasonLength:16, CloseReason:CloseReasonLength/binary>>,
    frame(Transport, State, CloseFrame),
    {State#stream_connection{connection_step = close_sent}, Rest}.

handle_frame_post_close(_Transport, State,
    <<?COMMAND_CLOSE:16, ?VERSION_0:16, _CorrelationId:32, _ResponseCode:16>>, Rest) ->
    {State#stream_connection{connection_step = closing_done}, Rest};
handle_frame_post_close(_Transport, State, <<?COMMAND_HEARTBEAT:16, ?VERSION_0:16>>, Rest) ->
    error_logger:info_msg("Received heartbeat frame post close~n"),
    {State, Rest};
handle_frame_post_close(_Transport, State, Frame, Rest) ->
    error_logger:warning_msg("ignored frame on close ~p ~p.~n", [Frame, Rest]),
    {State, Rest}.

auth_mechanisms(Sock) ->
    {ok, Configured} = application:get_env(rabbit, auth_mechanisms),
    [rabbit_data_coercion:to_binary(Name) || {Name, Module} <- rabbit_registry:lookup_all(auth_mechanism),
        Module:should_offer(Sock), lists:member(Name, Configured)].

auth_mechanism_to_module(TypeBin, Sock) ->
    case rabbit_registry:binary_to_type(TypeBin) of
        {error, not_found} ->
            error_logger:warning_msg("Unknown authentication mechanism '~p'~n", [TypeBin]),
            {error, not_found};
        T ->
            case {lists:member(TypeBin, auth_mechanisms(Sock)),
                rabbit_registry:lookup_module(auth_mechanism, T)} of
                {true, {ok, Module}} ->
                    {ok, Module};
                _ ->
                    error_logger:warning_msg("Invalid authentication mechanism '~p'~n", [T]),
                    {error, invalid}
            end
    end.

extract_target_list(<<>>, Targets) ->
    Targets;
extract_target_list(<<Length:16, Target:Length/binary, Rest/binary>>, Targets) ->
    extract_target_list(Rest, [Target | Targets]).

clean_state_after_target_deletion(Target, #stream_connection{clusters = Clusters, target_subscriptions = TargetSubscriptions,
    consumers = Consumers} = State) ->
    TargetAsList = binary_to_list(Target),
    case maps:is_key(TargetAsList, TargetSubscriptions) of
        true ->
            #{TargetAsList := SubscriptionIds} = TargetSubscriptions,
            {cleaned, State#stream_connection{
                clusters = maps:remove(Target, Clusters),
                target_subscriptions = maps:remove(TargetAsList, TargetSubscriptions),
                consumers = maps:without(SubscriptionIds, Consumers)
            }};
        false ->
            {not_cleaned, State}
    end.

lookup_cluster(Target, #stream_connection{clusters = Clusters} = State) ->
    case maps:get(Target, Clusters, undefined) of
        undefined ->
            case lookup_cluster_from_manager(Target) of
                cluster_not_found ->
                    cluster_not_found;
                ClusterPid ->
                    {ClusterPid, State#stream_connection{clusters = Clusters#{Target => ClusterPid}}}
            end;
        ClusterPid ->
            {ClusterPid, State}
    end.

lookup_cluster_from_manager(Target) ->
    rabbit_stream_manager:lookup(Target).

frame(Transport, #stream_connection{socket = S}, Frame) ->
    FrameSize = byte_size(Frame),
    Transport:send(S, [<<FrameSize:32>>, Frame]).

response_ok(Transport, State, CommandId, CorrelationId) ->
    response(Transport, State, CommandId, CorrelationId, ?RESPONSE_CODE_OK).

response(Transport, #stream_connection{socket = S}, CommandId, CorrelationId, ResponseCode) ->
    Transport:send(S, [<<?RESPONSE_FRAME_SIZE:32, CommandId:16, ?VERSION_0:16>>, <<CorrelationId:32>>, <<ResponseCode:16>>]).

subscription_exists(TargetSubscriptions, SubscriptionId) ->
    SubscriptionIds = lists:flatten(maps:values(TargetSubscriptions)),
    lists:any(fun(Id) -> Id =:= SubscriptionId end, SubscriptionIds).

send_file_callback(Transport, #consumer{socket = S, subscription_id = SubscriptionId}) ->
    fun(Size) ->
        FrameSize = 2 + 2 + 4 + Size,
        FrameBeginning = <<FrameSize:32, ?COMMAND_DELIVER:16, ?VERSION_0:16, SubscriptionId:32>>,
        Transport:send(S, FrameBeginning)
    end.

send_chunks(Transport, #consumer{credit = Credit} = State) ->
    send_chunks(Transport, State, Credit).

send_chunks(_Transport, #consumer{segment = Segment}, 0) ->
    {{segment, Segment}, {credit, 0}};
send_chunks(Transport, #consumer{segment = Segment} = State, Credit) ->
    send_chunks(Transport, State, Segment, Credit, true).

send_chunks(_Transport, _State, Segment, 0 = _Credit, _Retry) ->
    {{segment, Segment}, {credit, 0}};
send_chunks(Transport, #consumer{socket = S} = State, Segment, Credit, Retry) ->
    case osiris_log:send_file(S, Segment, send_file_callback(Transport, State)) of
        {ok, Segment1} ->
            send_chunks(
                Transport,
                State,
                Segment1,
                Credit - 1,
                true
            );
        {end_of_stream, Segment1} ->
            case Retry of
                true ->
                    timer:sleep(1),
                    send_chunks(Transport, State, Segment1, Credit, false);
                false ->
                    #consumer{leader = Leader} = State,
                    osiris:register_offset_listener(Leader, osiris_log:next_offset(Segment1)),
                    {{segment, Segment1}, {credit, Credit}}
            end
    end.
