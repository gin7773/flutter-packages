// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <map>
#include <mutex>
#include <thread>

#include "messages.ffi.h"

namespace cpp_test {
class Implementation : public CppTestApi {
 public:
  explicit Implementation(int64_t bias) : bias_(bias) {}
  ~Implementation() { Join(); }
  void Join() {
    for (auto& worker : workers_) worker.join();
    workers_.clear();
  }
  ErrorOr<int64_t> Add(int64_t value) override { return value + bias_; }
  ErrorOr<int64_t> SumWithNames(int64_t result, int64_t args, int64_t arena,
                                int64_t bytes, int64_t id) override {
    return result + args + arena + bytes + id;
  }
  ErrorOr<std::optional<int64_t>> EchoInt(const int64_t* value) override {
    return value ? std::optional<int64_t>(*value) : std::nullopt;
  }
  ErrorOr<bool> EchoBool(bool value) override { return value; }
  ErrorOr<double> EchoDouble(double value) override { return value; }
  ErrorOr<std::optional<std::string>> EchoString(
      const std::string* value) override {
    return value ? std::optional<std::string>(*value) : std::nullopt;
  }
  ErrorOr<std::vector<uint8_t>> EchoBytes(
      const std::vector<uint8_t>& value) override {
    return value;
  }
  ErrorOr<std::optional<std::vector<int32_t>>> EchoInt32(
      const std::vector<int32_t>* value) override {
    return value ? std::optional<std::vector<int32_t>>(*value) : std::nullopt;
  }
  ErrorOr<std::vector<int64_t>> EchoInt64(
      const std::vector<int64_t>& value) override {
    return value;
  }
  ErrorOr<std::vector<double>> EchoFloat64(
      const std::vector<double>& value) override {
    return value;
  }
  ErrorOr<std::optional<Choice>> EchoEnum(const Choice* value) override {
    return value ? std::optional<Choice>(*value) : std::nullopt;
  }
  ErrorOr<Box> EchoBox(const Box& value) override { return value; }
  ErrorOr<Box> Mixed(int64_t increment, const Box& value,
                     const std::string& label) override {
    return Box(value.value() + increment, &label);
  }
  ErrorOr<flutter::EncodableList> EchoList(
      const flutter::EncodableList& value) override {
    return value;
  }
  ErrorOr<flutter::EncodableMap> EchoMap(
      const flutter::EncodableMap& value) override {
    return value;
  }
  ErrorOr<std::optional<flutter::EncodableValue>> EchoObject(
      const flutter::EncodableValue* value) override {
    return value && !value->IsNull()
               ? std::optional<flutter::EncodableValue>(*value)
               : std::nullopt;
  }
  std::optional<FlutterError> Ping() override { return std::nullopt; }
  std::optional<FlutterError> Fail() override {
    throw std::runtime_error("fixture failure");
  }
  void Delayed(int64_t value,
               std::function<void(ErrorOr<int64_t>)> reply) override {
    std::lock_guard<std::mutex> lock(mutex_);
    // Copy all inputs before returning from the FFI entry.
    workers_.emplace_back([value, reply] { reply(value); });
  }
  void Pending(int64_t value,
               std::function<void(ErrorOr<int64_t>)> reply) override {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_ = [value, reply] {
      reply(value);
      reply(value + 1);
    };
  }
  void Complete() {
    std::function<void()> pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending.swap(pending_);
    }
    if (pending) pending();
  }
  void AsyncBox(const Box& value,
                std::function<void(ErrorOr<Box>)> reply) override {
    reply(value);
  }
  void AsyncVoid(
      std::function<void(std::optional<FlutterError>)> reply) override {
    reply(std::nullopt);
  }
  void Abandoned(std::function<void(std::optional<FlutterError>)>) override {}

 private:
  int64_t bias_;
  std::mutex mutex_;
  std::vector<std::thread> workers_;
  std::function<void()> pending_;
};
std::mutex fixture_mutex;
std::map<int64_t, std::unique_ptr<Implementation>> implementations;
}  // namespace cpp_test

// Test-only management ABI. Return 0 for a rejected registration.
extern "C" PIGEON_CPP_EXPORT int64_t fixture_register(const uint8_t* name,
                                                      size_t length,
                                                      int64_t bias) {
  try {
    std::lock_guard<std::mutex> lock(cpp_test::fixture_mutex);
    auto api = std::make_unique<cpp_test::Implementation>(bias);
    auto id = cpp_test::RegisterCppTestApiFfi(
        api.get(), std::string(reinterpret_cast<const char*>(name), length));
    cpp_test::implementations.emplace(id, std::move(api));
    return id;
  } catch (...) {
    return 0;
  }
}
extern "C" PIGEON_CPP_EXPORT void fixture_unregister(int64_t id) {
  std::lock_guard<std::mutex> lock(cpp_test::fixture_mutex);
  cpp_test::UnregisterCppTestApiFfi(id);
  auto it = cpp_test::implementations.find(id);
  if (it != cpp_test::implementations.end()) {
    it->second->Join();
    it->second->Complete();  // Deliberately deliver after unregister to test
                             // the fence.
    cpp_test::implementations.erase(it);
  }
}
extern "C" PIGEON_CPP_EXPORT void fixture_complete(int64_t id) {
  std::lock_guard<std::mutex> lock(cpp_test::fixture_mutex);
  auto it = cpp_test::implementations.find(id);
  if (it != cpp_test::implementations.end()) it->second->Complete();
}
