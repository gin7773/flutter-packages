// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

/// Integration test schema for C++ FFI backend verification.
///
/// This schema tests all FFI-specific scenarios:
/// - Primitive types
/// - Nullable types
/// - Custom classes
/// - Enums
/// - Collections (List/Map)
/// - Error returns

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'test/generated/cpp_ffi_test_messages.dart',
    dartOptions: DartOptions(),
    cppHeaderOut: 'test/generated/cpp_ffi_test_messages.h',
    cppSourceOut: 'test/generated/cpp_ffi_test_messages.cc',
    cppOptions: CppOptions(
      namespace: 'pigeon_test',
      useFfi: true,
      ffiHeaderOut: 'test/generated/cpp_ffi_test_messages_ffi.h',
      ffiSourceOut: 'test/generated/cpp_ffi_test_messages.cc',
      ffiBindingOut: 'test/generated/cpp_ffi_test_messages.g.ffi.dart',
      symbolPrefix: 'FfiTest_',
    ),
  ),
)
/// Test enum for FFI backend verification.
enum TestStatus { pending, active, inactive, error }

/// Test data class for FFI backend verification.
class TestData {
  TestData(this.id, this.name, this.value);

  final int id;
  final String name;
  final double value;
}

/// Host API for testing primitive types.
@HostApi()
abstract class PrimitiveApi {
  /// Test int parameter and return.
  int addNumbers(int a, int b);

  /// Test double parameter and return.
  double multiplyDoubles(double x, double y);

  /// Test bool parameter and return.
  bool negateBool(bool value);

  /// Test String parameter and return.
  String echoString(String input);
}

/// Host API for testing nullable types.
@HostApi()
abstract class NullableApi {
  /// Test nullable String parameter.
  String? processNullableString(String? input);

  /// Test nullable return value.
  String? getNullableString();

  /// Test nullable int parameter.
  int? addNullableInt(int? a, int? b);
}

/// Host API for testing custom classes.
@HostApi()
abstract class CustomClassApi {
  /// Test custom class as parameter.
  int getDataId(TestData data);

  /// Test custom class as return value.
  TestData createTestData(int id, String name, double value);

  /// Test custom class with nullable fields.
  TestData updateTestData(TestData data, String newName);
}

/// Host API for testing enum types.
@HostApi()
abstract class EnumApi {
  /// Test enum parameter.
  bool isActive(TestStatus status);

  /// Test enum return value.
  TestStatus getCurrentStatus();

  /// Test enum transformation.
  TestStatus toggleStatus(TestStatus status);
}

/// Host API for testing collection types.
@HostApi()
abstract class CollectionApi {
  /// Test List<int> parameter.
  int sumList(List<int> numbers);

  /// Test List<String> parameter and return.
  List<String> reverseStrings(List<String> items);

  /// Test Map<String, int> parameter.
  int sumMapValues(Map<String, int> data);

  /// Test Map<String, String> return.
  Map<String, String> transformMap(Map<String, String> input);
}

/// Host API for testing error returns.
@HostApi()
abstract class ErrorApi {
  /// Test successful ErrorOr return.
  int getSuccessValue();

  /// Test error ErrorOr return.
  int getErrorValue();

  /// Test ErrorOr with custom class.
  TestData getTestDataWithError(bool shouldFail);

  /// Test ErrorOr with nullable return.
  String? getNullableWithError(bool shouldFail);
}
