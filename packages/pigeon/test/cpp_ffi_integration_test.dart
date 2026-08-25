// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:test/test.dart';

/// Integration test for C++ FFI backend code generation.
///
/// This test verifies that generated FFI files from the integration schema
/// contain expected content.
void main() {
  group('C++ FFI Integration Test', () {
    test('verify generated C++ header exists and has expected content', () {
      final headerFile = File('test/generated/cpp_ffi_test_messages.h');
      expect(headerFile.existsSync(), true, reason: 'C++ header should be generated');

      final content = headerFile.readAsStringSync();
      expect(content, contains('namespace pigeon_test'));
      expect(content, contains('PrimitiveApi'));
      expect(content, contains('NullableApi'));
      expect(content, contains('CustomClassApi'));
      expect(content, contains('EnumApi'));
      expect(content, contains('CollectionApi'));
      expect(content, contains('ErrorApi'));
    });

    test('verify generated C++ source exists', () {
      final sourceFile = File('test/generated/cpp_ffi_test_messages.cc');
      expect(sourceFile.existsSync(), true, reason: 'C++ source should be generated');

      final content = sourceFile.readAsStringSync();
      expect(content, contains('pigeon_test'));
      expect(content.isNotEmpty, true, reason: 'C++ source should not be empty');
    });

    test('verify generated Dart file exists', () {
      final dartFile = File('test/generated/cpp_ffi_test_messages.dart');
      expect(dartFile.existsSync(), true, reason: 'Dart file should be generated');

      final content = dartFile.readAsStringSync();
      expect(content, contains('PrimitiveApi'));
      expect(content, contains('TestStatus'));
      expect(content, contains('TestData'));
    });

    test('verify generated Dart FFI binding exists', () {
      final dartFfiFile = File('test/generated/cpp_ffi_test_messages.g.dart');
      expect(dartFfiFile.existsSync(), true, reason: 'Dart FFI binding should be generated');

      final content = dartFfiFile.readAsStringSync();
      expect(content.isNotEmpty, true, reason: 'Dart FFI binding should not be empty');
    });

    test('verify integration test schema exists', () {
      final schemaFile = File('pigeons/cpp_ffi_integration_tests.dart');
      expect(schemaFile.existsSync(), true, reason: 'Integration test schema should exist');

      final content = schemaFile.readAsStringSync();
      expect(content, contains('@HostApi()'));
      expect(content, contains('PrimitiveApi'));
      expect(content, contains('NullableApi'));
      expect(content, contains('CustomClassApi'));
      expect(content, contains('EnumApi'));
      expect(content, contains('CollectionApi'));
      expect(content, contains('ErrorApi'));
      expect(content, contains('useFfi: true'));
    });
  });
}
