// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <future>
#include <iostream>
#include <map>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

#include "messages_ffi.h"

using namespace native_test;
using flutter::EncodableList;
using flutter::EncodableValue;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "Native regression failure: " << message << std::endl;
    std::exit(1);
  }
}

struct Request {
  explicit Request(const EncodableList& value)
      : bytes(Api::GetCodec().EncodeMessage(EncodableValue(value))),
        buffer{bytes->data(), bytes->size()} {}
  std::unique_ptr<std::vector<uint8_t>> bytes;
  PigeonFfiBuffer buffer;
};

EncodableValue Decode(PigeonFfiBuffer* buffer) {
  Check(buffer != nullptr, "null response buffer");
  auto value = Api::GetCodec().DecodeMessage(buffer->data, buffer->length);
  PIGEON_TEST_FREE(buffer);
  Check(value != nullptr, "undecodable response");
  return std::move(*value);
}

EncodableValue Success(PigeonFfiBuffer* buffer) {
  auto value = Decode(buffer);
  auto* list = std::get_if<EncodableList>(&value);
  Check(list && list->size() == 1, "expected success envelope");
  return list->front();
}

void Failure(PigeonFfiBuffer* buffer) {
  auto value = Decode(buffer);
  auto* list = std::get_if<EncodableList>(&value);
  Check(list && list->size() == 3 &&
            std::holds_alternative<std::string>(list->front()),
        "expected error envelope");
}

int64_t Connect(const std::string& name, bool event = false) {
  Request request(EncodableList{EncodableValue(name)});
  return Success(event ? PIGEON_TEST_EVENT_CONNECT(&request.buffer)
                       : PIGEON_TEST_CONNECT(&request.buffer))
      .LongValue();
}

class Impl : public Api {
 public:
  explicit Impl(int64_t id) : id_(id) {}
  ErrorOr<int64_t> Id() override {
    id_thread = std::this_thread::get_id();
    ++id_calls;
    return id_;
  }
  ErrorOr<std::optional<int64_t>> Echo(const int64_t* value) override {
    return value ? std::optional<int64_t>(*value) : std::nullopt;
  }
  void EchoAsync(
      const int64_t* value,
      std::function<void(ErrorOr<std::optional<int64_t>>)> reply) override {
    reply(value ? std::optional<int64_t>(*value) : std::nullopt);
  }
  void Hold(std::function<void(ErrorOr<int64_t>)> reply) override {
    hold_thread = std::this_thread::get_id();
    pending = std::move(reply);
  }
  std::function<void(ErrorOr<int64_t>)> pending;
  int id_calls = 0;
  std::thread::id id_thread;
  std::thread::id hold_thread;

 private:
  int64_t id_;
};

class ThrowingImpl : public Impl {
 public:
  using Impl::Impl;
  ErrorOr<int64_t> Id() override { throw std::runtime_error("native failure"); }
  void Hold(std::function<void(ErrorOr<int64_t>)> reply) override { throw 42; }
};

class BlockingImpl : public Impl {
 public:
  using Impl::Impl;
  ErrorOr<int64_t> Id() override {
    std::unique_lock<std::mutex> lock(mutex);
    entered = true;
    changed.notify_all();
    changed.wait(lock, [this] { return released; });
    return Impl::Id();
  }
  std::mutex mutex;
  std::condition_variable changed;
  bool entered = false;
  bool released = false;
};

// The implementation owns scheduling; the generated adapter only carries
// replies.
class PostingImpl : public Impl {
 public:
  using Impl::Impl;
  void Hold(std::function<void(ErrorOr<int64_t>)> reply) override {
    hold_thread = std::this_thread::get_id();
    worker = std::thread(
        [reply = std::move(reply), ready = released.get_future()]() mutable {
          ready.wait();
          reply(int64_t(77));
        });
  }
  std::promise<void> released;
  std::thread worker;
};

class NestedImpl : public Impl {
 public:
  using Impl::Impl;
  ErrorOr<int64_t> Id() override {
    on_id();
    return Impl::Id();
  }
  std::function<void()> on_id;
};

std::mutex replies_mutex;
std::map<int64_t, std::vector<EncodableValue>> replies;
void Receive(int64_t id, PigeonFfiBuffer* buffer) {
  auto value = Decode(buffer);
  std::lock_guard<std::mutex> lock(replies_mutex);
  replies[id].push_back(std::move(value));
}
size_t ReplyCount(int64_t id) {
  std::lock_guard<std::mutex> lock(replies_mutex);
  return replies[id].size();
}
EncodableValue ReplyValue(int64_t id) {
  std::lock_guard<std::mutex> lock(replies_mutex);
  Check(replies[id].size() == 1, "expected exactly one reply");
  auto& list = std::get<EncodableList>(replies[id].front());
  Check(list.size() == 1, "expected async success envelope");
  return list.front();
}

class Handler : public PigeonEventsEventsStreamHandler {
 public:
  std::optional<FlutterError> OnListen(
      const std::string& name,
      std::unique_ptr<PigeonEventsEventsEventSink> sink) override {
    listen_thread = std::this_thread::get_id();
    if (fail_next_listen) {
      fail_next_listen = false;
      return FlutterError("listen", "temporary listen failure");
    }
    sinks[name] = std::move(sink);
    return std::nullopt;
  }
  std::optional<FlutterError> OnCancel(const std::string& name) override {
    cancel_thread = std::this_thread::get_id();
    if (block_cancel) {
      std::unique_lock<std::mutex> lock(cancel_mutex);
      cancel_entered = true;
      cancel_changed.notify_all();
      cancel_changed.wait(lock, [this] { return cancel_released; });
    }
    ++cancels;
    auto it = sinks.find(name);
    if (it != sinks.end()) {
      retired.push_back(std::move(it->second));
      sinks.erase(it);
    }
    if (name == fail_cancel_name) {
      throw std::runtime_error("one producer failed to stop");
    }
    return std::nullopt;
  }
  bool fail_next_listen = false;
  bool block_cancel = false;
  std::string fail_cancel_name;
  std::mutex cancel_mutex;
  std::condition_variable cancel_changed;
  bool cancel_entered = false;
  bool cancel_released = false;
  int cancels = 0;
  std::thread::id listen_thread;
  std::thread::id cancel_thread;
  std::map<std::string, std::unique_ptr<PigeonEventsEventsEventSink>> sinks;
  std::vector<std::unique_ptr<PigeonEventsEventsEventSink>> retired;
};

int event_a = 0;
int event_b = 0;
int event_errors = 0;
int event_done = 0;
void EventA(int64_t id, PigeonFfiBuffer* buffer) {
  Check(id == 1 && Decode(buffer).LongValue() == 11, "engine A event routing");
  ++event_a;
}
void EventB(int64_t id, PigeonFfiBuffer* buffer) {
  Check(id == 1 && Decode(buffer).LongValue() == 22, "engine B event routing");
  ++event_b;
}
void EventError(int64_t id, PigeonFfiBuffer* buffer) {
  Failure(buffer);
  ++event_errors;
}
void EventDone(int64_t id) { ++event_done; }

std::mutex callback_mutex;
std::condition_variable callback_changed;
bool callback_entered = false;
bool callback_released = false;
void BlockingReply(int64_t id, PigeonFfiBuffer* buffer) {
  Receive(id, buffer);
  std::unique_lock<std::mutex> lock(callback_mutex);
  callback_entered = true;
  callback_changed.notify_all();
  callback_changed.wait(lock, [] { return callback_released; });
}

int64_t reentrant_session;
void ReentrantReply(int64_t id, PigeonFfiBuffer* buffer) {
  Receive(id, buffer);
  Failure(PIGEON_TEST_DISCONNECT(reentrant_session));
}

void TestCallerThreadExecution(const std::string& name, int64_t reply_id) {
  const auto caller = std::this_thread::get_id();
  PostingImpl api(77);
  SetUpApiFfi(&api, name);
  const int64_t session = Connect(name);
  Check(Success(PIGEON_TEST_ID(session, nullptr)).LongValue() == 77 &&
            api.id_thread == caller,
        "sync HostApi did not execute on the calling thread");
  PIGEON_TEST_HOLD(session, nullptr, reply_id, Receive);
  Check(api.hold_thread == caller && ReplyCount(reply_id) == 0,
        "async startup changed threads or waited for the final reply");
  api.released.set_value();
  api.worker.join();
  Check(ReplyCount(reply_id) == 1 && ReplyValue(reply_id).LongValue() == 77,
        "implementation-owned asynchronous work did not reply");
  Success(PIGEON_TEST_DISCONNECT(session));
  TearDownApiFfi(name);

  Handler handler;
  SetUpEventsEventsFfi(&handler, name);
  const int64_t event_session = Connect(name, true);
  Request request(EncodableList{EncodableValue("caller-stream")});
  auto listen = [&](int64_t owner) {
    Success(PIGEON_TEST_LISTEN(owner, &request.buffer, 1, EventA, EventError,
                               EventDone));
    Check(handler.listen_thread == caller,
          "event listen did not execute on the calling thread");
  };
  listen(event_session);
  Success(PIGEON_TEST_CANCEL(event_session, &request.buffer, 1));
  Check(handler.cancels == 1 && handler.cancel_thread == caller,
        "event cancel did not execute on the calling thread");
  listen(event_session);
  Success(PIGEON_TEST_EVENT_DISCONNECT(event_session));
  Check(handler.cancels == 2 && handler.cancel_thread == caller,
        "event disconnect cleanup changed threads");
  const int64_t remaining = Connect(name, true);
  listen(remaining);
  TearDownEventsEventsFfi(name);
  Check(handler.cancels == 3 && handler.cancel_thread == caller,
        "event teardown cleanup changed threads");
}

void TestSharedHostRegistration() {
  Impl shared(66), replacement(77);
  SetUpApiFfi(&shared);
  const int64_t first = Connect("");
  const int64_t second = Connect("");
  Check(first != second, "shared implementation needs independent sessions");
  Check(Success(PIGEON_TEST_ID(first, nullptr)).LongValue() == 66 &&
            Success(PIGEON_TEST_ID(second, nullptr)).LongValue() == 66,
        "both sessions must reach the shared implementation");

  bool duplicate_rejected = false;
  try {
    SetUpApiFfi(&replacement);
  } catch (const std::invalid_argument&) {
    duplicate_rejected = true;
  }
  Check(duplicate_rejected, "duplicate default registration was accepted");
  Check(Success(PIGEON_TEST_ID(second, nullptr)).LongValue() == 66,
        "duplicate setup replaced the shared implementation");

  PIGEON_TEST_HOLD(first, nullptr, 100, Receive);
  auto first_reply = std::move(shared.pending);
  PIGEON_TEST_HOLD(second, nullptr, 101, Receive);
  auto second_reply = std::move(shared.pending);
  Success(PIGEON_TEST_DISCONNECT(first));
  Success(PIGEON_TEST_DISCONNECT(first));
  first_reply(int64_t(1));
  second_reply(int64_t(2));
  Check(ReplyCount(100) == 0 && ReplyValue(101).LongValue() == 2,
        "disconnect crossed sessions of the shared implementation");
  Failure(PIGEON_TEST_ID(first, nullptr));
  Check(Success(PIGEON_TEST_ID(second, nullptr)).LongValue() == 66,
        "surviving shared session stopped accepting calls");

  const int64_t third = Connect("");
  PIGEON_TEST_HOLD(second, nullptr, 102, Receive);
  second_reply = std::move(shared.pending);
  PIGEON_TEST_HOLD(third, nullptr, 103, Receive);
  auto third_reply = std::move(shared.pending);
  TearDownApiFfi();
  second_reply(int64_t(3));
  third_reply(int64_t(4));
  Check(ReplyCount(102) == 0 && ReplyCount(103) == 0,
        "shared teardown did not revoke every session");
  Failure(PIGEON_TEST_ID(second, nullptr));
  Failure(PIGEON_TEST_ID(third, nullptr));
  Request request(EncodableList{EncodableValue("")});
  Failure(PIGEON_TEST_CONNECT(&request.buffer));

  SetUpApiFfi(&replacement);
  const int64_t fresh = Connect("");
  Check(fresh != first && fresh != second && fresh != third,
        "shared registration reused a stale session identifier");
  Check(Success(PIGEON_TEST_ID(fresh, nullptr)).LongValue() == 77,
        "replacement shared implementation was not connected");
  Failure(PIGEON_TEST_ID(second, nullptr));
  Success(PIGEON_TEST_DISCONNECT(fresh));
  const int64_t reopened = Connect("");
  Check(Success(PIGEON_TEST_ID(reopened, nullptr)).LongValue() == 77,
        "disconnecting the last session unregistered the shared service");
  Success(PIGEON_TEST_DISCONNECT(reopened));
  TearDownApiFfi();
}

void TestSharedEventRegistration() {
  Handler shared;
  SetUpEventsEventsFfi(&shared);
  const int64_t first = Connect("", true);
  const int64_t second = Connect("", true);
  Request first_stream(EncodableList{EncodableValue("shared-first")});
  Request second_stream(EncodableList{EncodableValue("shared-second")});
  Success(PIGEON_TEST_LISTEN(first, &first_stream.buffer, 1, EventA, EventError,
                             EventDone));
  Success(PIGEON_TEST_LISTEN(second, &second_stream.buffer, 1, EventB,
                             EventError, EventDone));

  // A different session cannot claim a stream already owned by this handler.
  const int64_t duplicate = Connect("", true);
  Failure(PIGEON_TEST_LISTEN(duplicate, &second_stream.buffer, 1, EventB,
                             EventError, EventDone));
  Success(PIGEON_TEST_EVENT_DISCONNECT(duplicate));
  Success(PIGEON_TEST_EVENT_DISCONNECT(first));
  Check(shared.cancels == 1 && shared.sinks.count("shared-second") == 1,
        "shared event disconnect canceled another session's stream");
  const int before_a = event_a;
  const int before_b = event_b;
  shared.retired.back()->Success(11);
  shared.sinks.at("shared-second")->Success(22);
  Check(event_a == before_a && event_b == before_b + 1,
        "surviving shared event session did not remain active");

  const int64_t third = Connect("", true);
  Success(PIGEON_TEST_LISTEN(third, &first_stream.buffer, 1, EventA, EventError,
                             EventDone));
  TearDownEventsEventsFfi();
  Check(shared.cancels == 3 && shared.sinks.empty(),
        "shared event teardown did not stop every remaining stream");
  for (const auto& sink : shared.retired) {
    sink->Success(11);
    sink->Error(FlutterError("late"));
    sink->EndOfStream();
  }
  Check(event_a == before_a && event_b == before_b + 1 && event_errors == 0 &&
            event_done == 0,
        "shared event teardown allowed a late native notification");
  Success(PIGEON_TEST_EVENT_DISCONNECT(second));
  Success(PIGEON_TEST_EVENT_DISCONNECT(third));
}

void TestNestedRegistrationCalls() {
  NestedImpl outer(88), inner(99);
  SetUpApiFfi(&outer, "outer");
  SetUpApiFfi(&inner, "inner");
  const int64_t outer_session = Connect("outer");
  const int64_t inner_session = Connect("inner");
  inner.on_id = [&] {
    bool rejected = false;
    try {
      TearDownApiFfi("outer");
    } catch (const std::logic_error&) {
      rejected = true;
    }
    Check(rejected, "nested call failed to reject reentrant outer teardown");
    Failure(PIGEON_TEST_DISCONNECT(outer_session));
  };
  outer.on_id = [&] {
    Check(Success(PIGEON_TEST_ID(inner_session, nullptr)).LongValue() == 99,
          "nested call failed to reach the inner implementation");
  };
  Check(Success(PIGEON_TEST_ID(outer_session, nullptr)).LongValue() == 88,
        "reentrant teardown invalidated the active outer registration");
  // All nested leases have unwound, so ordinary teardown must still succeed.
  TearDownApiFfi("outer");
  TearDownApiFfi("inner");
}

int main() {
  Impl a(11), b(22), replacement(33);
  ThrowingImpl throwing(44);
  BlockingImpl blocking(55);
  SetUpApiFfi(&a, "A");
  SetUpApiFfi(&b, "B");
  const int64_t session_a = Connect("A");
  const int64_t session_b = Connect("B");
  Check(session_a != session_b, "sessions must be distinct");
  Check(Success(PIGEON_TEST_ID(session_a, nullptr)).LongValue() == 11,
        "engine A routing");
  Check(Success(PIGEON_TEST_ID(session_b, nullptr)).LongValue() == 22,
        "engine B routing");
  TearDownApiFfi("A");
  Check(Success(PIGEON_TEST_ID(session_b, nullptr)).LongValue() == 22,
        "teardown A affects B");
  SetUpApiFfi(&replacement, "A");
  Failure(PIGEON_TEST_ID(session_a, nullptr));
  const int64_t replacement_session = Connect("A");
  Check(Success(PIGEON_TEST_ID(replacement_session, nullptr)).LongValue() == 33,
        "new registration should have a new session");

  const std::vector<EncodableValue> integers{EncodableValue(int32_t(7)),
                                             EncodableValue(int64_t(1) << 35),
                                             EncodableValue()};
  int64_t reply_id = 10;
  for (const auto& input : integers) {
    Request request(EncodableList{input});
    const auto result = Success(PIGEON_TEST_ECHO(session_b, &request.buffer));
    Check(input.IsNull() ? result.IsNull()
                         : result.LongValue() == input.LongValue(),
          "nullable integer sync round trip");
    PIGEON_TEST_ECHOASYNC(session_b, &request.buffer, reply_id, Receive);
    const auto async_result = ReplyValue(reply_id++);
    Check(input.IsNull() ? async_result.IsNull()
                         : async_result.LongValue() == input.LongValue(),
          "nullable integer async round trip");
  }

  PIGEON_TEST_HOLD(replacement_session, nullptr, 20, Receive);
  Success(PIGEON_TEST_DISCONNECT(replacement_session));
  replacement.pending(int64_t(99));
  Check(ReplyCount(20) == 0, "disconnect must revoke pending callback");
  const int64_t teardown_session = Connect("A");
  PIGEON_TEST_HOLD(teardown_session, nullptr, 21, Receive);
  TearDownApiFfi("A");
  replacement.pending(int64_t(99));
  Check(ReplyCount(21) == 0, "teardown must revoke pending callback");
  PIGEON_TEST_HOLD(session_b, nullptr, 22, Receive);
  b.pending(int64_t(99));
  b.pending(int64_t(100));
  Check(ReplyCount(22) == 1 && ReplyValue(22).LongValue() == 99,
        "duplicate native replies must be ignored");

  SetUpApiFfi(&throwing, "throw");
  const int64_t throwing_session = Connect("throw");
  Failure(PIGEON_TEST_ID(throwing_session, nullptr));
  PIGEON_TEST_HOLD(throwing_session, nullptr, 23, Receive);
  Check(ReplyCount(23) == 1 &&
            std::get<EncodableList>(replies[23].front()).size() == 3,
        "unknown native exception must become an async error envelope");
  TearDownApiFfi("throw");

  Handler handler_a, handler_b;
  SetUpEventsEventsFfi(&handler_a, "A");
  SetUpEventsEventsFfi(&handler_b, "B");
  const int64_t event_session_a = Connect("A", true);
  const int64_t event_session_b = Connect("B", true);
  Request event_request(EncodableList{EncodableValue("same-player")});
  Success(PIGEON_TEST_LISTEN(event_session_a, &event_request.buffer, 1, EventA,
                             EventError, EventDone));
  Success(PIGEON_TEST_LISTEN(event_session_b, &event_request.buffer, 1, EventB,
                             EventError, EventDone));
  handler_a.sinks.at("same-player")->Success(11);
  handler_b.sinks.at("same-player")->Success(22);
  Success(PIGEON_TEST_CANCEL(event_session_a, &event_request.buffer, 1));
  Check(handler_a.cancels == 1 && handler_b.cancels == 0,
        "event cancellation crossed registrations");
  handler_b.sinks.at("same-player")->Success(22);
  Check(event_a == 1 && event_b == 2,
        "event B should survive cancellation of A");
  TearDownEventsEventsFfi("B");
  Check(handler_b.cancels == 1, "teardown must stop native event producer");
  handler_b.retired.back()->Success(22);
  handler_b.retired.back()->Error(FlutterError("late"));
  handler_b.retired.back()->EndOfStream();
  Check(event_b == 2 && event_errors == 0 && event_done == 0,
        "teardown must revoke success, error and done notifications");
  Success(PIGEON_TEST_EVENT_DISCONNECT(event_session_a));
  handler_a.retired.back()->Success(11);
  Check(event_a == 1, "disconnect must revoke native event sends");
  TearDownEventsEventsFfi("A");

  Handler retry;
  SetUpEventsEventsFfi(&retry, "retry");
  const int64_t retry_session = Connect("retry", true);
  retry.fail_next_listen = true;
  Failure(PIGEON_TEST_LISTEN(retry_session, &event_request.buffer, 1, EventA,
                             EventError, EventDone));
  Success(PIGEON_TEST_EVENT_DISCONNECT(retry_session));
  const int64_t retried_session = Connect("retry", true);
  Success(PIGEON_TEST_LISTEN(retried_session, &event_request.buffer, 1, EventA,
                             EventError, EventDone));
  Success(PIGEON_TEST_CANCEL(retried_session, &event_request.buffer, 1));
  TearDownEventsEventsFfi("retry");

  Handler cancel_race;
  cancel_race.block_cancel = true;
  SetUpEventsEventsFfi(&cancel_race, "cancel-race");
  const int64_t cancelling_session = Connect("cancel-race", true);
  const int64_t waiting_session = Connect("cancel-race", true);
  Success(PIGEON_TEST_LISTEN(cancelling_session, &event_request.buffer, 1,
                             EventA, EventError, EventDone));
  std::thread cancel([&] {
    Success(PIGEON_TEST_CANCEL(cancelling_session, &event_request.buffer, 1));
  });
  {
    std::unique_lock<std::mutex> lock(cancel_race.cancel_mutex);
    Check(cancel_race.cancel_changed.wait_for(
              lock, std::chrono::seconds(5),
              [&] { return cancel_race.cancel_entered; }),
          "native OnCancel did not start");
  }
  Failure(PIGEON_TEST_LISTEN(waiting_session, &event_request.buffer, 1, EventA,
                             EventError, EventDone));
  {
    std::lock_guard<std::mutex> lock(cancel_race.cancel_mutex);
    cancel_race.cancel_released = true;
  }
  cancel_race.cancel_changed.notify_all();
  cancel.join();
  Success(PIGEON_TEST_LISTEN(waiting_session, &event_request.buffer, 1, EventA,
                             EventError, EventDone));
  cancel_race.block_cancel = false;
  Success(PIGEON_TEST_CANCEL(waiting_session, &event_request.buffer, 1));
  TearDownEventsEventsFfi("cancel-race");

  Handler cleanup;
  cleanup.fail_cancel_name = "one";
  SetUpEventsEventsFfi(&cleanup, "cleanup");
  const int64_t cleanup_session = Connect("cleanup", true);
  Request first_stream(EncodableList{EncodableValue("one")});
  Request second_stream(EncodableList{EncodableValue("two")});
  Success(PIGEON_TEST_LISTEN(cleanup_session, &first_stream.buffer, 1, EventA,
                             EventError, EventDone));
  Success(PIGEON_TEST_LISTEN(cleanup_session, &second_stream.buffer, 2, EventA,
                             EventError, EventDone));
  Failure(PIGEON_TEST_EVENT_DISCONNECT(cleanup_session));
  Check(
      cleanup.cancels == 2 && cleanup.sinks.empty(),
      "one cancellation exception prevented cleanup of other native producers");
  cleanup.fail_cancel_name.clear();
  const int64_t cleaned_session = Connect("cleanup", true);
  Success(PIGEON_TEST_LISTEN(cleaned_session, &first_stream.buffer, 1, EventA,
                             EventError, EventDone));
  Success(PIGEON_TEST_LISTEN(cleaned_session, &second_stream.buffer, 2, EventA,
                             EventError, EventDone));
  Success(PIGEON_TEST_EVENT_DISCONNECT(cleaned_session));
  TearDownEventsEventsFfi("cleanup");

  PIGEON_TEST_HOLD(session_b, nullptr, 30, BlockingReply);
  std::thread completion([&] { b.pending(int64_t(7)); });
  {
    std::unique_lock<std::mutex> lock(callback_mutex);
    Check(callback_changed.wait_for(lock, std::chrono::seconds(5),
                                    [] { return callback_entered; }),
          "reply callback did not start");
  }
  std::atomic<bool> disconnected{false};
  std::thread disconnect([&] {
    Success(PIGEON_TEST_DISCONNECT(session_b));
    disconnected = true;
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(25));
  const bool waited_for_callback = !disconnected.load();
  {
    std::lock_guard<std::mutex> lock(callback_mutex);
    callback_released = true;
  }
  callback_changed.notify_all();
  completion.join();
  disconnect.join();
  Check(waited_for_callback,
        "disconnect returned while callback was still running");

  reentrant_session = Connect("B");
  PIGEON_TEST_HOLD(reentrant_session, nullptr, 31, ReentrantReply);
  b.pending(int64_t(7));
  Check(ReplyCount(31) == 1,
        "reentrant close should return an error without deadlocking");
  Check(Success(PIGEON_TEST_ID(reentrant_session, nullptr)).LongValue() == 22,
        "rejected reentrant close corrupted the session");
  Success(PIGEON_TEST_DISCONNECT(reentrant_session));
  TearDownApiFfi("B");

  SetUpApiFfi(&blocking, "blocking");
  const int64_t blocked_session = Connect("blocking");
  std::thread call([&] {
    Check(Success(PIGEON_TEST_ID(blocked_session, nullptr)).LongValue() == 55,
          "active native call failed during teardown");
  });
  {
    std::unique_lock<std::mutex> lock(blocking.mutex);
    Check(blocking.changed.wait_for(lock, std::chrono::seconds(5),
                                    [&] { return blocking.entered; }),
          "native call did not start");
  }
  std::promise<void> closing;
  auto closed = std::async(std::launch::async, [&] {
    closing.set_value();
    TearDownApiFfi("blocking");
  });
  closing.get_future().wait();
  const bool waited_for_call = closed.wait_for(std::chrono::milliseconds(25)) ==
                               std::future_status::timeout;
  {
    std::lock_guard<std::mutex> lock(blocking.mutex);
    blocking.released = true;
  }
  blocking.changed.notify_all();
  call.join();
  closed.get();
  Check(waited_for_call && blocking.id_calls == 1,
        "teardown did not wait for the active native implementation");
  Failure(PIGEON_TEST_ID(blocked_session, nullptr));

  TestCallerThreadExecution("caller-main", 40);
  std::thread caller([] { TestCallerThreadExecution("caller-worker", 41); });
  caller.join();
  TestSharedHostRegistration();
  TestSharedEventRegistration();
  TestNestedRegistrationCalls();
  std::cout << "All native C++ FFI regression checks passed." << std::endl;
}
