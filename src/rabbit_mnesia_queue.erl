%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc. All rights reserved.
%%

-module(rabbit_mnesia_queue).

-export(
   [start/1, stop/0, init/5, terminate/1, delete_and_terminate/1, purge/1,
    publish/3, publish_delivered/4, drain_confirmed/1, fetch/2, ack/2,
    tx_publish/4, tx_ack/3, tx_rollback/2, tx_commit/4, requeue/3, len/1,
    is_empty/1, dropwhile/2, set_ram_duration_target/2, ram_duration/1,
    needs_idle_timeout/1, idle_timeout/1, handle_pre_hibernate/1, status/1]).

%% ----------------------------------------------------------------------------
%% This is a simple implementation of the rabbit_backing_queue
%% behavior, with all msgs in Mnesia.
%% ----------------------------------------------------------------------------

-behaviour(rabbit_backing_queue).

-record(state, { q_table, p_table, next_seq_id, confirmed, txn_dict }).

-record(msg_status, { seq_id, msg, props, is_delivered }).

-record(tx, { to_pub, to_ack }).

-record(q_record, { seq_id, msg_status }).

-record(p_record, { seq_id, msg_status }).

-include("rabbit.hrl").

-type(maybe(T) :: nothing | {just, T}).

-type(seq_id() :: non_neg_integer()).
-type(ack() :: seq_id()).

-type(state() :: #state { q_table :: atom(),
                          p_table :: atom(),
                          next_seq_id :: seq_id(),
                          confirmed :: gb_set(),
                          txn_dict :: dict() }).

-type(msg_status() :: #msg_status { msg :: rabbit_types:basic_message(),
                                    seq_id :: seq_id(),
                                    props :: rabbit_types:message_properties(),
                                    is_delivered :: boolean() }).

-type(tx() :: #tx { to_pub :: [pub()],
                    to_ack :: [seq_id()] }).

-type(pub() :: { rabbit_types:basic_message(),
                 rabbit_types:message_properties() }).

-include("rabbit_backing_queue_spec.hrl").

start(_DurableQueues) -> ok.

stop() -> ok.

init(QueueName, IsDurable, Recover, _AsyncCallback, _SyncCallback) ->
    {QTable, PTable} = tables(QueueName),
    case Recover of
        false -> {atomic, ok} = mnesia:delete_table(QTable),
                 {atomic, ok} = mnesia:delete_table(PTable);
        true -> ok
    end,
    create_table(QTable, 'q_record', 'ordered_set', record_info(fields,
                                                                q_record)),
    create_table(PTable, 'p_record', 'set', record_info(fields, p_record)),
    {atomic, State} =
        mnesia:transaction(
          fun () ->
                  case IsDurable of
                      false -> clear_table(QTable),
                               clear_table(PTable);
                      true -> delete_nonpersistent_msgs(QTable)
                  end,
                  NextSeqId = case mnesia:first(QTable) of
                                  '$end_of_table' -> 0;
                                  SeqId -> SeqId
                              end,
                  #state { q_table = QTable,
                           p_table = PTable,
                           next_seq_id = NextSeqId,
                           confirmed = gb_sets:new(),
                           txn_dict = dict:new() }
          end),
    State.

terminate(State = #state { q_table = QTable, p_table = PTable }) ->
    {atomic, ok} = mnesia:clear_table(PTable),
    {atomic, ok} = mnesia:dump_tables([QTable, PTable]),
    State.

delete_and_terminate(State = #state { q_table = QTable, p_table = PTable }) ->
    {atomic, _} =
        mnesia:transaction(fun () -> clear_table(QTable),
                                     clear_table(PTable)
                           end),
    {atomic, ok} = mnesia:dump_tables([QTable, PTable]),
    State.

purge(State = #state { q_table = QTable }) ->
    {atomic, Result} =
        mnesia:transaction(fun () -> LQ = length(mnesia:all_keys(QTable)),
                                     clear_table(QTable),
                                     {LQ, State}
                           end),
    Result.

publish(Msg, Props, State) ->
    {atomic, State1} =
        mnesia:transaction(
          fun () -> internal_publish(Msg, Props, false, State) end),
    confirm([{Msg, Props}], State1).

publish_delivered(false, Msg, Props, State) ->
    {undefined, confirm([{Msg, Props}], State)};
publish_delivered(true,
                  Msg,
                  Props,
                  State = #state { next_seq_id = SeqId }) ->
    MsgStatus = #msg_status { seq_id = SeqId,
                              msg = Msg,
                              props = Props,
                              is_delivered = true },
    {atomic, State1} =
        mnesia:transaction(
          fun () ->
                  add_pending_ack(MsgStatus, State),
                  State #state { next_seq_id = SeqId + 1 }
          end),
    {SeqId, confirm([{Msg, Props}], State1)}.

drain_confirmed(State = #state { confirmed = Confirmed }) ->
    {gb_sets:to_list(Confirmed), State #state { confirmed = gb_sets:new() }}.

dropwhile(Pred, State) ->
    {atomic, Result} =
        mnesia:transaction(fun () -> internal_dropwhile(Pred, State) end),
    Result.

fetch(AckRequired, State) ->
    {atomic, FetchResult} =
        mnesia:transaction(fun () -> internal_fetch(AckRequired, State) end),
    {FetchResult, State}.

ack(SeqIds, State) ->
    {atomic, Result} =
        mnesia:transaction(fun () -> internal_ack(SeqIds, State) end),
    Result.

tx_publish(Txn, Msg, Props, State = #state { txn_dict = TxnDict}) ->
    Tx = #tx { to_pub = Pubs } = lookup_tx(Txn, TxnDict),
    State #state {
      txn_dict =
          store_tx(Txn, Tx #tx { to_pub = [{Msg, Props} | Pubs] }, TxnDict) }.

tx_ack(Txn, SeqIds, State = #state { txn_dict = TxnDict }) ->
    Tx = #tx { to_ack = SeqIds0 } = lookup_tx(Txn, TxnDict),
    State #state {
      txn_dict =
          store_tx(Txn, Tx #tx { to_ack = SeqIds ++ SeqIds0 }, TxnDict) }.

tx_rollback(Txn, State = #state { txn_dict = TxnDict }) ->
    #tx { to_ack = SeqIds } = lookup_tx(Txn, TxnDict),
    {SeqIds, State #state { txn_dict = erase_tx(Txn, TxnDict) }}.

tx_commit(Txn, F, PropsF, State = #state { txn_dict = TxnDict }) ->
    #tx { to_ack = SeqIds, to_pub = Pubs } = lookup_tx(Txn, TxnDict),
    {atomic, State1} = mnesia:transaction(
                         fun () ->
                                 internal_tx_commit(
                                   Pubs,
                                   SeqIds,
                                   PropsF,
                                   State #state { txn_dict = erase_tx(Txn, TxnDict) })
                         end),
    F(),
    {SeqIds, confirm(Pubs, State1)}.

requeue(SeqIds, PropsF, State) ->
    {atomic, Result} =
        mnesia:transaction(
          fun () -> del_pending_acks(
                      fun (#msg_status { msg = Msg, props = Props }, S) ->
                              internal_publish(
                                Msg, PropsF(Props), true, S)
                      end,
                      SeqIds,
                      State)
          end),
    Result.

len(#state { q_table = QTable }) ->
    {atomic, Result} =
        mnesia:transaction(fun () -> length(mnesia:all_keys(QTable)) end),
    Result.

is_empty(#state { q_table = QTable }) ->
    {atomic, Result} =
        mnesia:transaction(fun () -> 0 == length(mnesia:all_keys(QTable)) end),
    Result.

set_ram_duration_target(_, State) -> State.

ram_duration(State) -> {0, State}.

needs_idle_timeout(_) -> false.

idle_timeout(State) -> State.

handle_pre_hibernate(State) -> State.

status(#state { q_table = QTable,
                p_table = PTable,
                next_seq_id = NextSeqId }) ->
    {atomic, Result} =
        mnesia:transaction(
          fun () -> LQ = length(mnesia:all_keys(QTable)),
                    LP = length(mnesia:all_keys(PTable)),
                    [{len, LQ}, {next_seq_id, NextSeqId}, {acks, LP}]
          end),
    Result.

-spec create_table(atom(), atom(), atom(), [atom()]) -> ok.

create_table(Table, RecordName, Type, Attributes) ->
    case mnesia:create_table(Table, [{record_name, RecordName},
                                     {type, Type},
                                     {attributes, Attributes},
                                     {ram_copies, [node()]}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Table}} ->
            RecordName = mnesia:table_info(Table, record_name),
            Type = mnesia:table_info(Table, type),
            Attributes = mnesia:table_info(Table, attributes),
            ok
    end.

-spec clear_table(atom()) -> ok.

clear_table(Table) ->
    case mnesia:first(Table) of
        '$end_of_table' -> ok;
        Key -> ok = mnesia:delete(Table, Key, 'write'),
               clear_table(Table)
    end.

-spec delete_nonpersistent_msgs(atom()) -> ok.

delete_nonpersistent_msgs(QTable) ->
    lists:foreach(
      fun (Key) ->
              [#q_record { seq_id = Key, msg_status = MsgStatus }] =
                  mnesia:read(QTable, Key, 'read'),
              case MsgStatus of
                  #msg_status { msg = #basic_message {
                                  is_persistent = true }} -> ok;
                  _ -> ok = mnesia:delete(QTable, Key, 'write')
              end
      end,
      mnesia:all_keys(QTable)).

-spec(internal_fetch(true, state()) -> fetch_result(ack());
          (false, state()) -> fetch_result(undefined)).

internal_fetch(AckRequired, State) ->
    case q_pop(State) of
        nothing -> empty;
        {just, MsgStatus} -> post_pop(AckRequired, MsgStatus, State)
    end.

-spec internal_tx_commit([pub()],
                         [seq_id()],
                         message_properties_transformer(),
                         state()) ->
                                state().

internal_tx_commit(Pubs, SeqIds, PropsF, State) ->
    State1 = internal_ack(SeqIds, State),
    lists:foldl(
      fun ({Msg, Props}, S) ->
              internal_publish(Msg, PropsF(Props), false, S)
      end,
      State1,
      lists:reverse(Pubs)).

-spec internal_publish(rabbit_types:basic_message(),
                       rabbit_types:message_properties(),
                       boolean(),
                       state()) ->
                              state().

internal_publish(Msg,
                 Props,
                 IsDelivered,
                 State = #state { q_table = QTable, next_seq_id = SeqId }) ->
    MsgStatus = #msg_status {
      seq_id = SeqId,
      msg = Msg,
      props = Props,
      is_delivered = IsDelivered },
    ok = mnesia:write(
           QTable,
           #q_record { seq_id = SeqId, msg_status = MsgStatus },
           'write'),
    State #state { next_seq_id = SeqId + 1 }.

-spec(internal_ack/2 :: ([seq_id()], state()) -> state()).

internal_ack(SeqIds, State) ->
    del_pending_acks(fun (_, S) -> S end, SeqIds, State).

-spec(internal_dropwhile/2 ::
        (fun ((rabbit_types:message_properties()) -> boolean()), state())
        -> state()).

internal_dropwhile(Pred, State) ->
    case q_peek(State) of
        nothing -> State;
        {just, MsgStatus = #msg_status { props = Props }} ->
            case Pred(Props) of
                true -> _ = q_pop(State),
                        _ = post_pop(false, MsgStatus, State),
                        internal_dropwhile(Pred, State);
                false -> State
            end
    end.

-spec q_pop(state()) -> maybe(msg_status()).

q_pop(#state { q_table = QTable }) ->
    case mnesia:first(QTable) of
        '$end_of_table' -> nothing;
        SeqId -> [#q_record { seq_id = SeqId, msg_status = MsgStatus }] =
                     mnesia:read(QTable, SeqId, 'read'),
                 ok = mnesia:delete(QTable, SeqId, 'write'),
                 {just, MsgStatus}
    end.

-spec q_peek(state()) -> maybe(msg_status()).

q_peek(#state { q_table = QTable }) ->
    case mnesia:first(QTable) of
        '$end_of_table' -> nothing;
        SeqId -> [#q_record { seq_id = SeqId, msg_status = MsgStatus }] =
                     mnesia:read(QTable, SeqId, 'read'),
                 {just, MsgStatus}
    end.

-spec(post_pop(true, msg_status(), state()) -> fetch_result(ack());
              (false, msg_status(), state()) -> fetch_result(undefined)).

post_pop(true,
         MsgStatus = #msg_status {
           seq_id = SeqId, msg = Msg, is_delivered = IsDelivered },
         State = #state { q_table = QTable }) ->
    LQ = length(mnesia:all_keys(QTable)),
    add_pending_ack(MsgStatus #msg_status { is_delivered = true }, State),
    {Msg, IsDelivered, SeqId, LQ};
post_pop(false,
         #msg_status { msg = Msg, is_delivered = IsDelivered },
         #state { q_table = QTable }) ->
    LQ = length(mnesia:all_keys(QTable)),
    {Msg, IsDelivered, undefined, LQ}.

-spec add_pending_ack(msg_status(), state()) -> ok.

add_pending_ack(MsgStatus = #msg_status { seq_id = SeqId },
                #state { p_table = PTable }) ->
    ok = mnesia:write(PTable,
                      #p_record { seq_id = SeqId, msg_status = MsgStatus },
                      'write'),
    ok.

-spec del_pending_acks(fun ((msg_status(), state()) -> state()),
                       [seq_id()],
                       state()) ->
                              state().

del_pending_acks(F, SeqIds, State = #state { p_table = PTable }) ->
    lists:foldl(
      fun (SeqId, S) ->
              [#p_record { msg_status = MsgStatus }] =
                  mnesia:read(PTable, SeqId, 'read'),
              ok = mnesia:delete(PTable, SeqId, 'write'),
              F(MsgStatus, S)
      end,
      State,
      SeqIds).

-spec tables({resource, binary(), queue, binary()}) -> {atom(), atom()}.

tables({resource, VHost, queue, Name}) ->
    VHost2 = re:split(binary_to_list(VHost), "[/]", [{return, list}]),
    Name2 = re:split(binary_to_list(Name), "[/]", [{return, list}]),
    Str = lists:flatten(io_lib:format("~999999999p", [{VHost2, Name2}])),
    {list_to_atom("q" ++ Str), list_to_atom("p" ++ Str)}.

-spec lookup_tx(rabbit_types:txn(), dict()) -> tx().

lookup_tx(Txn, TxnDict) ->
    case dict:find(Txn, TxnDict) of
        error -> #tx { to_pub = [], to_ack = [] };
        {ok, Tx} -> Tx
    end.

-spec store_tx(rabbit_types:txn(), tx(), dict()) -> dict().

store_tx(Txn, Tx, TxnDict) -> dict:store(Txn, Tx, TxnDict).

-spec erase_tx(rabbit_types:txn(), dict()) -> dict().

erase_tx(Txn, TxnDict) -> dict:erase(Txn, TxnDict).

-spec confirm([pub()], state()) -> state().

confirm(Pubs, State = #state { confirmed = Confirmed }) ->
    MsgIds =
        [MsgId || {#basic_message { id = MsgId },
                   #message_properties { needs_confirming = true }} <- Pubs],
    case MsgIds of
        [] -> State;
        _ -> State #state {
               confirmed =
                   gb_sets:union(Confirmed, gb_sets:from_list(MsgIds)) }
    end.

