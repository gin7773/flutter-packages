// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <limits>
#include <mutex>
#include <thread>

#include "messages.ffi.h"

extern "C" int64_t fixture_register(const uint8_t*, size_t, int64_t);
extern "C" void fixture_unregister(int64_t);
extern "C" void fixture_complete(int64_t);

#define API(member) \
  pigeon_cpp_x5f_test_cpp_x5f_test_messages_x2e_h_10_CppTestApi_##member
#define FREE pigeon_cpp_x5f_test_cpp_x5f_test_messages_x2e_h_free_value
#define CHECK(condition)                                       \
  do {                                                         \
    if (!(condition)) {                                        \
      std::cerr << "Failed at line " << __LINE__ << std::endl; \
      return 1;                                                \
    }                                                          \
    ++checks;                                                  \
  } while (false)

namespace {
std::mutex reply_mutex;
std::condition_variable reply_ready;
PigeonCppValue* reply = nullptr;
int replies = 0;
std::mutex post_mutex;
std::condition_variable post_ready;
bool post_started = false;
bool release_post = false;
bool unregistered = false;
void BlockPost(int64_t, PigeonCppValue* value) {
  std::unique_lock<std::mutex> lock(post_mutex);
  post_started = true;
  post_ready.notify_all();
  post_ready.wait(lock, [] { return release_post; });
  FREE(value);
}
void Receive(int64_t, PigeonCppValue* value) {
  std::lock_guard<std::mutex> lock(reply_mutex);
  FREE(reply);
  reply = value;
  ++replies;
  reply_ready.notify_all();
}
int64_t Register(const std::string& name, int64_t bias) {
  return fixture_register(reinterpret_cast<const uint8_t*>(name.data()),
                          name.size(), bias);
}
int64_t Connect(const std::string& name) {
  auto* value =
      API(connect)(reinterpret_cast<const uint8_t*>(name.data()), name.size());
  auto id = value->is_error ? 0 : value->integer;
  FREE(value);
  return id;
}
void Disconnect(int64_t id) { FREE(API(disconnect)(id)); }
}  // namespace

int main() {
  int checks = 0;
  const auto a = Register("engine-a", 100);
  const auto b = Register("engine-b", 200);
  CHECK(a && b);
  CHECK(Register("engine-a", 999) == 0);
  const auto s1 = Connect("engine-a");
  const auto s2 = Connect("engine-a");
  const auto sb = Connect("engine-b");
  CHECK(s1 && s2 && sb && s1 != s2);
  CHECK(Connect("missing") == 0);
  PigeonCppValue arg{};
  arg.integer = 42;
  auto* value = API(3_add)(s1, &arg);
  CHECK(value && !value->is_error && value->integer == 142);
  FREE(value);
  value = API(3_add)(sb, &arg);
  CHECK(value && value->integer == 242);
  FREE(value);
  for (int64_t number :
       {int64_t{0}, int64_t{-1}, std::numeric_limits<int64_t>::min(),
        std::numeric_limits<int64_t>::max()}) {
    arg.integer = number;
    value = API(7_echoInt)(s1, &arg);
    CHECK(value && !value->is_null && value->integer == number);
    FREE(value);
  }
  arg.is_null = 1;
  value = API(7_echoInt)(s1, &arg);
  CHECK(value && value->is_null);
  FREE(value);
  value = API(9_echoInt32)(s1, &arg);
  CHECK(value && value->is_null);
  FREE(value);
  arg = {};
  arg.real = 1.25;
  value = API(10_echoDouble)(s1, &arg);
  CHECK(value && value->real == 1.25);
  FREE(value);
  arg.integer = 1;
  value = API(8_echoBool)(s1, &arg);
  CHECK(value && value->integer == 1);
  FREE(value);
  value = API(8_echoEnum)(s1, &arg);
  CHECK(value && value->integer == 1);
  FREE(value);
  arg.integer = 99;
  value = API(8_echoEnum)(s1, &arg);
  CHECK(value && value->is_error);
  FREE(value);
  std::string text("hello\0world", 11);
  arg.data = reinterpret_cast<uint8_t*>(text.data());
  arg.length = text.size();
  value = API(10_echoString)(s1, &arg);
  CHECK(value && std::string(reinterpret_cast<char*>(value->data),
                             value->length) == text);
  FREE(value);
  arg = {};
  value = API(10_echoString)(s1, &arg);
  CHECK(value && !value->is_null && value->length == 0);
  FREE(value);
  value = API(9_echoBytes)(s1, &arg);
  CHECK(value && !value->is_null && value->length == 0);
  FREE(value);
  std::vector<int64_t> numbers{1, -2, std::numeric_limits<int64_t>::max()};
  arg.data = reinterpret_cast<uint8_t*>(numbers.data());
  arg.length = numbers.size() * sizeof(int64_t);
  value = API(9_echoInt64)(s1, &arg);
  CHECK(value && value->length == arg.length &&
        std::memcmp(value->data, arg.data, arg.length) == 0);
  FREE(value);
  arg.length = 3;
  value = API(9_echoInt64)(s1, &arg);
  CHECK(value && value->is_error);
  FREE(value);
  const auto& codec = cpp_test::CppTestApi::GetCodec();
  cpp_test::Box box(71, &text);
  auto bytes = codec.EncodeMessage(flutter::EncodableValue(
      flutter::EncodableList{flutter::CustomEncodableValue(box)}));
  arg = {};
  arg.data = bytes->data();
  arg.length = bytes->size();
  value = API(7_echoBox)(s1, &arg);
  auto decoded = codec.DecodeMessage(value->data, value->length);
  CHECK(std::any_cast<const cpp_test::Box&>(
            std::get<flutter::CustomEncodableValue>(*decoded))
            .value() == 71);
  FREE(value);
  PigeonCppValue mixed[3]{};
  mixed[0].integer = 5;
  mixed[1].data = reinterpret_cast<uint8_t*>(text.data());
  mixed[1].length = text.size();
  mixed[2] = arg;
  value = API(5_mixed)(s1, mixed);
  decoded = codec.DecodeMessage(value->data, value->length);
  CHECK(std::any_cast<const cpp_test::Box&>(
            std::get<flutter::CustomEncodableValue>(*decoded))
            .value() == 76);
  FREE(value);
  value = API(4_fail)(s1, nullptr);
  CHECK(value && value->is_error);
  FREE(value);
  value = API(4_ping)(s1, nullptr);
  CHECK(value && !value->is_error);
  FREE(value);
  arg = {};
  arg.integer = 37;
  API(7_delayed)(s1, &arg, 1, Receive);
  {
    std::unique_lock<std::mutex> lock(reply_mutex);
    CHECK(reply_ready.wait_for(lock, std::chrono::seconds(5),
                               [] { return replies == 1; }));
    CHECK(reply && reply->integer == 37);
    FREE(reply);
    reply = nullptr;
  }
  API(7_pending)(s1, &arg, 2, Receive);
  fixture_complete(a);
  CHECK(replies == 2 && reply && reply->integer == 37);
  FREE(reply);
  reply = nullptr;
  API(7_pending)(s1, &arg, 3, Receive);
  Disconnect(s1);
  CHECK(replies == 3 && reply && reply->is_error);
  FREE(reply);
  reply = nullptr;
  fixture_complete(a);
  CHECK(replies == 3);
  value = API(3_add)(s2, &arg);
  CHECK(value && value->integer == 137);
  FREE(value);
  API(7_pending)(s2, &arg, 4, Receive);
  fixture_unregister(a);
  CHECK(replies == 4 && reply && reply->is_error);
  FREE(reply);
  reply = nullptr;
  const auto replacement = Register("engine-a", 300);
  CHECK(replacement != a && replacement != 0);
  fixture_unregister(a);  // Stale cleanup cannot remove a replacement.
  const auto s3 = Connect("engine-a");
  value = API(3_add)(s2, &arg);
  CHECK(value && value->is_error);
  FREE(value);
  value = API(3_add)(s3, &arg);
  CHECK(value && value->integer == 337);
  FREE(value);
  std::atomic<int> successes{0};
  std::vector<std::thread> callers;
  for (int i = 0; i < 8; ++i) {
    callers.emplace_back([&] {
      for (int j = 0; j < 100; ++j) {
        auto session = Connect("engine-b");
        auto* result = API(3_add)(session, &arg);
        if (result && !result->is_error && result->integer == 237) ++successes;
        FREE(result);
        Disconnect(session);
      }
    });
  }
  for (auto& caller : callers) caller.join();
  CHECK(successes == 800);
  // Unregister must wait for a callback already posting, not only pending work.
  const auto fence = Register("fence", 0);
  const auto fence_session = Connect("fence");
  API(7_delayed)(fence_session, &arg, 5, BlockPost);
  {
    std::unique_lock<std::mutex> lock(post_mutex);
    CHECK(post_ready.wait_for(lock, std::chrono::seconds(5),
                              [] { return post_started; }));
  }
  std::thread removing([&] {
    // Bypass fixture_unregister's worker join to test the adapter's own fence.
    cpp_test::UnregisterCppTestApiFfi(fence);
    std::lock_guard<std::mutex> lock(post_mutex);
    unregistered = true;
    post_ready.notify_all();
  });
  bool returned_before_post;
  {
    std::unique_lock<std::mutex> lock(post_mutex);
    returned_before_post = post_ready.wait_for(
        lock, std::chrono::milliseconds(200), [] { return unregistered; });
    release_post = true;
    post_ready.notify_all();
  }
  removing.join();
  Disconnect(fence_session);
  fixture_unregister(fence);
  CHECK(!returned_before_post);
  Disconnect(s2);
  Disconnect(s3);
  Disconnect(sb);
  fixture_unregister(replacement);
  fixture_unregister(b);
  std::cout << "C++ FFI native checks passed: " << checks << std::endl;
}
