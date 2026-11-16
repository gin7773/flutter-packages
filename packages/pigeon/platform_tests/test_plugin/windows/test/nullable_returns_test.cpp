// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <gtest/gtest.h>

#include <limits>
#include <optional>

#include "pigeon/nullable_returns.gen.h"
#include "test/utils/fake_host_messenger.h"

namespace nullable_returns_pigeontest {

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using testing::FakeHostMessenger;

class TestNullableArgHostApi : public NullableArgHostApi {
 public:
  TestNullableArgHostApi() {}
  virtual ~TestNullableArgHostApi() {}

 protected:
  ErrorOr<int64_t> Doit(const int64_t* x) override {
    return x == nullptr ? 42 : *x;
  }
};

class TestNullableReturnHostApi : public NullableReturnHostApi {
 public:
  TestNullableReturnHostApi(std::optional<int64_t> return_value)
      : value_(return_value) {}
  virtual ~TestNullableReturnHostApi() {}

 protected:
  ErrorOr<std::optional<int64_t>> Doit() override { return value_; }

 private:
  std::optional<int64_t> value_;
};

const EncodableValue& GetResult(const EncodableValue& pigeon_response) {
  return std::get<EncodableList>(pigeon_response)[0];
}

class NullableIntegerTest : public testing::TestWithParam<EncodableValue> {};

// Replies with a codec value of the requested width, as Dart's codec would.
class IntegerReplyMessenger : public flutter::BinaryMessenger {
 public:
  explicit IntegerReplyMessenger(const EncodableValue& value) : value_(value) {}

  void Send(const std::string& channel, const uint8_t* message,
            size_t message_size, flutter::BinaryReply reply) const override {
    const auto encoded = NullableReturnFlutterApi::GetCodec().EncodeMessage(
        EncodableValue(EncodableList{value_}));
    reply(encoded->data(), encoded->size());
  }

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {}

 private:
  EncodableValue value_;
};
}  // namespace

TEST_P(NullableIntegerTest, HostNullableArg) {
  FakeHostMessenger messenger(&NullableArgHostApi::GetCodec());
  TestNullableArgHostApi api;
  NullableArgHostApi::SetUp(&messenger, &api);

  std::optional<int64_t> result;
  messenger.SendHostMessage(
      "dev.flutter.pigeon.pigeon_integration_tests.NullableArgHostApi.doit",
      EncodableValue(EncodableList{GetParam()}),
      [&result](const EncodableValue& reply) {
        result = GetResult(reply).LongValue();
      });

  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(*result, GetParam().IsNull() ? 42 : GetParam().LongValue());
}

TEST_P(NullableIntegerTest, FlutterNullableReturn) {
  IntegerReplyMessenger messenger(GetParam());
  NullableReturnFlutterApi api(&messenger);

  bool replied = false;
  api.Doit(
      [&replied](const int64_t* result) {
        replied = true;
        if (GetParam().IsNull()) {
          EXPECT_EQ(result, nullptr);
        } else {
          ASSERT_NE(result, nullptr);
          EXPECT_EQ(*result, GetParam().LongValue());
        }
      },
      [](const FlutterError& error) { FAIL() << error.code(); });

  EXPECT_TRUE(replied);
}

INSTANTIATE_TEST_SUITE_P(
    CodecIntegerWidths, NullableIntegerTest,
    testing::Values(EncodableValue(), EncodableValue(int32_t{0}),
                    EncodableValue(int32_t{7}), EncodableValue(int32_t{-7}),
                    EncodableValue(std::numeric_limits<int32_t>::min()),
                    EncodableValue(std::numeric_limits<int32_t>::max()),
                    EncodableValue(int64_t{7}),
                    EncodableValue(std::numeric_limits<int64_t>::min()),
                    EncodableValue(std::numeric_limits<int64_t>::max())));

TEST(NullableReturns, HostNullableReturnNull) {
  FakeHostMessenger messenger(&NullableReturnHostApi::GetCodec());
  TestNullableReturnHostApi api(std::nullopt);
  NullableReturnHostApi::SetUp(&messenger, &api);

  // Initialize to a non-null value to ensure that it's actually set to null,
  // rather than just never set.
  EncodableValue result(true);
  messenger.SendHostMessage(
      "dev.flutter.pigeon.pigeon_integration_tests.NullableReturnHostApi.doit",
      EncodableValue(EncodableList({})),
      [&result](const EncodableValue& reply) { result = GetResult(reply); });

  EXPECT_TRUE(result.IsNull());
}

TEST(NullableReturns, HostNullableReturnNonNull) {
  FakeHostMessenger messenger(&NullableReturnHostApi::GetCodec());
  TestNullableReturnHostApi api(42);
  NullableReturnHostApi::SetUp(&messenger, &api);

  EncodableValue result;
  messenger.SendHostMessage(
      "dev.flutter.pigeon.pigeon_integration_tests.NullableReturnHostApi.doit",
      EncodableValue(EncodableList({})),
      [&result](const EncodableValue& reply) { result = GetResult(reply); });

  EXPECT_FALSE(result.IsNull());
  EXPECT_EQ(result.LongValue(), 42);
}

// TODO(stuartmorgan): Add FlutterApi versions of the tests.

}  // namespace nullable_returns_pigeontest
