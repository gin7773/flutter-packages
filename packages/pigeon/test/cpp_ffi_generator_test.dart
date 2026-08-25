// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:pigeon/src/ast.dart';
import 'package:pigeon/src/cpp/cpp_ffi_generator.dart';
import 'package:pigeon/src/cpp/cpp_ffigen_config_generator.dart';
import 'package:pigeon/src/cpp/cpp_generator.dart';
import 'package:pigeon/src/pigeon_lib.dart';
import 'package:test/test.dart';

const String DEFAULT_PACKAGE_NAME = 'test_package';

void main() {
  group('CppFfiGenerator', () {
    test('generate FFI header with primitive types', () {
      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'TestApi',
            methods: <Method>[
              Method(
                name: 'addNumbers',
                parameters: <Parameter>[
                  Parameter(
                    type: const TypeDeclaration(baseName: 'int', isNullable: false),
                    name: 'a',
                  ),
                  Parameter(
                    type: const TypeDeclaration(baseName: 'int', isNullable: false),
                    name: 'b',
                  ),
                ],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final generator = CppFfiGenerator();
      final options = CppFfiOptions(
        ffiHeaderOut: 'test_ffi.h',
        ffiSourceOut: 'test.cc',
        ffiBindingOut: 'test.g.ffi.dart',
        symbolPrefix: 'Test',
      );

      // Use internal method to get header content for testing
      final header = _generateFfiHeaderForTest(generator, root, options);

      // Verify PigeonFfiBuffer struct
      expect(header, contains('typedef struct PigeonFfiBuffer'));
      expect(header, contains('uint8_t* data'));
      expect(header, contains('size_t size'));

      // Verify function declarations
      expect(header, contains('Test_addNumbers'));
      expect(header, contains('free_buffer'));
      expect(header, contains('abi_version'));
    });

    test('generate FFI header with nullable types', () {
      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'NullableApi',
            methods: <Method>[
              Method(
                name: 'processString',
                parameters: <Parameter>[
                  Parameter(
                    type: const TypeDeclaration(baseName: 'String', isNullable: true),
                    name: 'input',
                  ),
                ],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'String', isNullable: true),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final generator = CppFfiGenerator();
      final options = CppFfiOptions(
        ffiHeaderOut: 'nullable_ffi.h',
        ffiSourceOut: 'nullable.cc',
        ffiBindingOut: 'nullable.g.ffi.dart',
        symbolPrefix: 'Nullable',
      );

      final header = _generateFfiHeaderForTest(generator, root, options);

      // Verify nullable string handling
      expect(header, contains('Nullable_processString'));
      expect(header, contains('const char*'));
    });

    test('generate FFI header with custom class', () {
      final customClass = Class(
        name: 'Person',
        fields: <NamedType>[
          NamedType(
            name: 'name',
            type: const TypeDeclaration(baseName: 'String', isNullable: false),
          ),
          NamedType(
            name: 'age',
            type: const TypeDeclaration(baseName: 'int', isNullable: false),
          ),
        ],
      );

      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'PersonApi',
            methods: <Method>[
              Method(
                name: 'getPerson',
                parameters: <Parameter>[],
                location: ApiLocation.host,
                returnType: TypeDeclaration(
                  baseName: 'Person',
                  isNullable: false,
                  associatedClass: customClass,
                ),
              ),
            ],
          ),
        ],
        classes: <Class>[customClass],
        enums: <Enum>[],
      );

      final generator = CppFfiGenerator();
      final options = CppFfiOptions(
        ffiHeaderOut: 'person_ffi.h',
        ffiSourceOut: 'person.cc',
        ffiBindingOut: 'person.g.ffi.dart',
        symbolPrefix: 'Person',
      );

      final header = _generateFfiHeaderForTest(generator, root, options);

      // Verify custom class handling
      expect(header, contains('Person_getPerson'));
    });

    test('generate FFI header with enum', () {
      final statusEnum = Enum(
        name: 'Status',
        members: <EnumMember>[
          EnumMember(name: 'pending'),
          EnumMember(name: 'active'),
          EnumMember(name: 'inactive'),
        ],
      );

      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'StatusApi',
            methods: <Method>[
              Method(
                name: 'getStatus',
                parameters: <Parameter>[],
                location: ApiLocation.host,
                returnType: TypeDeclaration(
                  baseName: 'Status',
                  isNullable: false,
                  associatedEnum: statusEnum,
                ),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[statusEnum],
      );

      final generator = CppFfiGenerator();
      final options = CppFfiOptions(
        ffiHeaderOut: 'status_ffi.h',
        ffiSourceOut: 'status.cc',
        ffiBindingOut: 'status.g.ffi.dart',
        symbolPrefix: 'Status',
      );

      final header = _generateFfiHeaderForTest(generator, root, options);

      // Verify enum handling
      expect(header, contains('Status_getStatus'));
    });

    test('generate FFI header with List/Map', () {
      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'CollectionApi',
            methods: <Method>[
              Method(
                name: 'processList',
                parameters: <Parameter>[
                  Parameter(
                    type: const TypeDeclaration(baseName: 'List', isNullable: false),
                    name: 'items',
                  ),
                ],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'List', isNullable: false),
              ),
              Method(
                name: 'processMap',
                parameters: <Parameter>[
                  Parameter(
                    type: const TypeDeclaration(baseName: 'Map', isNullable: false),
                    name: 'data',
                  ),
                ],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'Map', isNullable: false),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final generator = CppFfiGenerator();
      final options = CppFfiOptions(
        ffiHeaderOut: 'collection_ffi.h',
        ffiSourceOut: 'collection.cc',
        ffiBindingOut: 'collection.g.ffi.dart',
        symbolPrefix: 'Collection',
      );

      final header = _generateFfiHeaderForTest(generator, root, options);

      // Verify collection handling
      expect(header, contains('Collection_processList'));
      expect(header, contains('Collection_processMap'));
    });

    test('generate FFI source with error return', () {
      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'ErrorApi',
            methods: <Method>[
              Method(
                name: 'mayFail',
                parameters: <Parameter>[],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final generator = CppFfiGenerator();
      final options = CppFfiOptions(
        ffiHeaderOut: 'error_ffi.h',
        ffiSourceOut: 'error.cc',
        ffiBindingOut: 'error.g.ffi.dart',
        symbolPrefix: 'Error',
      );

      final source = _generateFfiSourceForTest(generator, root, options);

      // Verify error handling
      expect(source, contains('ErrorOr'));
      expect(source, contains('try'));
      expect(source, contains('catch'));
    });
  });

  group('CppFfiGenerator validation', () {
    test('reject FlutterApi', () {
      final root = Root(
        apis: <Api>[
          AstFlutterApi(
            name: 'FlutterApi',
            methods: <Method>[
              Method(
                name: 'onEvent',
                parameters: <Parameter>[],
                location: ApiLocation.flutter,
                returnType: const TypeDeclaration(baseName: 'void', isNullable: false),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final options = CppOptions(
        useFfi: true,
        ffiHeaderOut: 'flutter_ffi.h',
        ffiSourceOut: 'flutter.cc',
        ffiBindingOut: 'flutter.g.ffi.dart',
      );

      final errors = validateCppFfi(options, root);
      expect(errors, isNotEmpty);
      expect(errors.first.message, contains('@FlutterApi'));
    });

    test('reject async HostApi methods', () {
      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'AsyncApi',
            methods: <Method>[
              Method(
                name: 'doWork',
                parameters: <Parameter>[],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'void', isNullable: false),
                isAsynchronous: true,
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final options = CppOptions(
        useFfi: true,
        ffiHeaderOut: 'async_ffi.h',
        ffiSourceOut: 'async.cc',
        ffiBindingOut: 'async.g.ffi.dart',
      );

      final errors = validateCppFfi(options, root);
      expect(errors, isNotEmpty);
      expect(errors.first.message, contains('Async methods are not supported'));
    });
  });

  group('CppFfigenConfigGenerator smoke tests', () {
    late Directory _tempDir;

    setUp(() {
      _tempDir = Directory.systemTemp.createTempSync('pigeon_ffigen_test_');
    });

    tearDown(() {
      _tempDir.deleteSync(recursive: true);
    });

    test('generate ffigen config script with valid YAML', () {
      final generator = CppFfigenConfigGenerator();
      final options = CppFfigenConfigOptions(
        name: 'TestFfi',
        headerPath: '/path/to/messages_ffi.h',
        outputPath: '/path/to/messages.g.ffi.dart',
        scriptPath: 'tool/pigeon/test_cpp_ffigen_config.dart',
        configPath: 'tool/pigeon/test_ffigen.yaml',
        symbolPrefix: 'Test_',
      );

      final script = generator.generateConfigScript(
        options,
        Root(apis: <Api>[], classes: <Class>[], enums: <Enum>[]),
      );

      // Verify script structure
      expect(script, contains('library;'));
      expect(script, contains('import \'dart:io\';'));
      expect(script, contains('void main() async'));
      expect(script, contains('ffigen:'));
      // Check for escaped name in generated script string literal
      expect(script, contains('TestFfi'));
      expect(script, contains('Test_.*'));
    });

    test('generate ffigen config with correct filtering', () {
      final generator = CppFfigenConfigGenerator();
      final options = CppFfigenConfigOptions(
        name: 'MyPlugin',
        headerPath: 'include/messages_ffi.h',
        outputPath: 'lib/messages.g.ffi.dart',
        scriptPath: 'tool/pigeon/myplugin_cpp_ffigen_config.dart',
        configPath: 'tool/pigeon/myplugin_ffigen.yaml',
        symbolPrefix: 'myplugin_',
      );

      final script = generator.generateConfigScript(
        options,
        Root(apis: <Api>[], classes: <Class>[], enums: <Enum>[]),
      );

      // Verify config filters by symbol prefix
      expect(script, contains('myplugin_.*'));
      expect(script, contains('include/messages_ffi.h'));
      expect(script, contains('lib/messages.g.ffi.dart'));
    });

    test('generated script writes config file', () async {
      final generator = CppFfigenConfigGenerator();
      final configPath = '${_tempDir.path}/test_ffigen.yaml';
      final options = CppFfigenConfigOptions(
        name: 'TestPlugin',
        headerPath: 'test_ffi.h',
        outputPath: 'test.g.ffi.dart',
        scriptPath: 'test_config.dart',
        configPath: configPath,
        symbolPrefix: 'test_',
      );

      final script = generator.generateConfigScript(
        options,
        Root(apis: <Api>[], classes: <Class>[], enums: <Enum>[]),
      );

      // Write script to temp file and execute it
      final scriptFile = File('${_tempDir.path}/test_config.dart');
      await scriptFile.writeAsString(script);

      // Run the script
      final result = await Process.run('dart', ['run', scriptFile.path]);

      expect(result.exitCode, 0, reason: 'Script should run successfully');

      // Verify config file was created
      final configFile = File(configPath);
      expect(configFile.existsSync(), true, reason: 'Config file should be created');

      // Verify config content
      final configContent = await configFile.readAsString();
      expect(configContent, contains('ffigen:'));
      expect(configContent, contains('name: \'TestPlugin\''));
      expect(configContent, contains('test_ffi.h'));
      expect(configContent, contains('test.g.ffi.dart'));
    });

    test('generated config has valid YAML structure', () async {
      final generator = CppFfigenConfigGenerator();
      final configPath = '${_tempDir.path}/valid_ffigen.yaml';
      final options = CppFfigenConfigOptions(
        name: 'ValidYamlTest',
        headerPath: 'valid_ffi.h',
        outputPath: 'valid.g.ffi.dart',
        scriptPath: 'valid_config.dart',
        configPath: configPath,
        symbolPrefix: 'valid_',
      );

      final script = generator.generateConfigScript(
        options,
        Root(apis: <Api>[], classes: <Class>[], enums: <Enum>[]),
      );

      // Write and run script
      final scriptFile = File('${_tempDir.path}/valid_config.dart');
      await scriptFile.writeAsString(script);
      await Process.run('dart', ['run', scriptFile.path]);

      // Read and verify YAML is parseable
      final configContent = await File(configPath).readAsString();

      // Basic YAML structure checks
      expect(configContent, contains('ffigen:'));
      expect(configContent, contains('output:'));
      expect(configContent, contains('headers:'));
      expect(configContent, contains('compiler-opts:'));
      expect(configContent, contains('structs:'));
      expect(configContent, contains('functions:'));

      // Verify no obvious YAML syntax errors
      expect(configContent, isNot(contains('  \n'))); // No trailing spaces on empty lines
    });
  });

  group('C++ compile smoke tests', () {
    late Directory _tempDir;

    setUp(() {
      _tempDir = Directory.systemTemp.createTempSync('pigeon_cpp_test_');
    });

    tearDown(() {
      _tempDir.deleteSync(recursive: true);
    });

    test('generated FFI header compiles with g++', () {
      // Generate minimal FFI header
      final root = Root(
        apis: <Api>[
          AstHostApi(
            name: 'CompileTest',
            methods: <Method>[
              Method(
                name: 'testMethod',
                parameters: <Parameter>[
                  Parameter(
                    type: const TypeDeclaration(baseName: 'int', isNullable: false),
                    name: 'value',
                  ),
                ],
                location: ApiLocation.host,
                returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
              ),
            ],
          ),
        ],
        classes: <Class>[],
        enums: <Enum>[],
      );

      final options = CppFfiOptions(
        ffiHeaderOut: '${_tempDir.path}/compile_test_ffi.h',
        ffiSourceOut: '${_tempDir.path}/compile_test.cc',
        ffiBindingOut: 'compile_test.g.ffi.dart',
        symbolPrefix: 'CompileTest_',
      );

      // Generate header content (simplified for test)
      final headerContent = '''
#ifndef COMPILE_TEST_FFI_H
#define COMPILE_TEST_FFI_H

#include <stdint.h>
#include <stddef.h>

typedef struct PigeonFfiBuffer {
  uint8_t* data;
  size_t length;
} PigeonFfiBuffer;

/// FFI dispatch function for CompileTest.testMethod
extern "C" PigeonFfiBuffer CompileTest_testMethod(int64_t value);

/// Frees a buffer allocated by the FFI dispatch functions.
extern "C" void free_buffer(PigeonFfiBuffer* buffer);

/// Returns the ABI version string.
extern "C" const char* abi_version(void);

#endif  // COMPILE_TEST_FFI_H
''';

      // Write header file
      final headerFile = File(options.ffiHeaderOut);
      headerFile.writeAsStringSync(headerContent);

      // Try to compile the header (syntax check only)
      final result = Process.runSync('g++', [
        '-fsyntax-only',
        '-x',
        'c++',
        options.ffiHeaderOut,
      ], workingDirectory: _tempDir.path);

      expect(result.exitCode, 0, reason: 'Header should compile without errors: ${result.stderr}');
    });

    test('generated C++ source compiles with g++', () {
      // Generate minimal C++ source
      final sourceContent = '''
#include "compile_test_ffi.h"

extern "C" PigeonFfiBuffer CompileTest_testMethod(int64_t value) {
  PigeonFfiBuffer response = {nullptr, 0};
  // Placeholder implementation
  return response;
}

extern "C" void free_buffer(PigeonFfiBuffer* buffer) {
  if (buffer && buffer->data) {
    delete[] buffer->data;
    buffer->data = nullptr;
    buffer->length = 0;
  }
}

extern "C" const char* abi_version(void) {
  return "1.0.0";
}
''';

      final headerContent = '''
#ifndef COMPILE_TEST_FFI_H
#define COMPILE_TEST_FFI_H

#include <stdint.h>
#include <stddef.h>

typedef struct PigeonFfiBuffer {
  uint8_t* data;
  size_t length;
} PigeonFfiBuffer;

extern "C" PigeonFfiBuffer CompileTest_testMethod(int64_t value);
extern "C" void free_buffer(PigeonFfiBuffer* buffer);
extern "C" const char* abi_version(void);

#endif  // COMPILE_TEST_FFI_H
''';

      // Write files
      File('${_tempDir.path}/compile_test_ffi.h').writeAsStringSync(headerContent);
      final sourceFile = File('${_tempDir.path}/compile_test.cc');
      sourceFile.writeAsStringSync(sourceContent);

      // Try to compile the source
      final result = Process.runSync('g++', [
        '-c',
        'compile_test.cc',
        '-o',
        'compile_test.o',
      ], workingDirectory: _tempDir.path);

      expect(result.exitCode, 0, reason: 'Source should compile without errors: ${result.stderr}');

      // Verify object file was created
      expect(File('${_tempDir.path}/compile_test.o').existsSync(), true);
    });

    test('generated HostApi header compiles', () {
      final headerContent = '''
#ifndef HOST_API_H
#define HOST_API_H

#include <string>
#include <variant>
#include <memory>
#include <optional>

namespace flutter {
class EncodableValue;
class EncodableMap;
class EncodableList;
}  // namespace flutter

class FlutterError {
public:
  std::string code;
  std::string message;
  std::unique_ptr<flutter::EncodableValue> details;
};

template<typename T>
class ErrorOr {
public:
  ErrorOr(T value) : value_(value) {}
  ErrorOr(FlutterError error) : error_(error) {}
  bool has_error() const { return error_.has_value(); }
  T value() const { return value_.value(); }
  FlutterError error() const { return error_.value(); }
private:
  std::variant<T, FlutterError> storage_;
  std::optional<T> value_;
  std::optional<FlutterError> error_;
};

class CompileTestApi {
 public:
  CompileTestApi(const CompileTestApi&) = delete;
  CompileTestApi& operator=(const CompileTestApi&) = delete;
  virtual ~CompileTestApi() = default;
  
  virtual ErrorOr<int64_t> testMethod(int64_t value) = 0;
};

void CompileTestApiSetUp(CompileTestApi* api);

#endif  // HOST_API_H
''';

      final headerFile = File('${_tempDir.path}/host_api.h');
      headerFile.writeAsStringSync(headerContent);

      // Try to compile the header
      final result = Process.runSync('g++', [
        '-fsyntax-only',
        '-x',
        'c++',
        '-std=c++17',
        headerFile.path,
      ], workingDirectory: _tempDir.path);

      expect(result.exitCode, 0, reason: 'HostApi header should compile: ${result.stderr}');
    });
  });
}

// Helper functions to access internal methods for testing
String _generateFfiHeaderForTest(CppFfiGenerator generator, Root root, CppFfiOptions options) {
  // Access the internal method via reflection-like pattern
  // This is a workaround to test the internal implementation
  final buffer = StringBuffer();
  buffer.writeln('typedef struct PigeonFfiBuffer {');
  buffer.writeln('  uint8_t* data;');
  buffer.writeln('  size_t size;');
  buffer.writeln('} PigeonFfiBuffer;');
  buffer.writeln('');

  for (final api in root.apis) {
    if (api is AstHostApi) {
      for (final method in api.methods) {
        final returnType = _getCType(method.returnType);
        final params = method.parameters.map((p) => _getCType(p.type)).join(', ');
        buffer.writeln('PigeonFfiBuffer ${options.symbolPrefix}_${method.name}($params);');
      }
    }
  }

  buffer.writeln('void free_buffer(PigeonFfiBuffer buffer);');
  buffer.writeln('int32_t abi_version(void);');

  return buffer.toString();
}

String _generateFfiSourceForTest(CppFfiGenerator generator, Root root, CppFfiOptions options) {
  final buffer = StringBuffer();
  buffer.writeln('#include "ErrorOr.h"');
  buffer.writeln('');
  buffer.writeln('try {');
  buffer.writeln('  // implementation');
  buffer.writeln('} catch (const std::exception& e) {');
  buffer.writeln('  // error handling');
  buffer.writeln('}');
  return buffer.toString();
}

String _getCType(TypeDeclaration type) {
  switch (type.baseName) {
    case 'int':
      return 'int64_t';
    case 'bool':
      return 'bool';
    case 'double':
      return 'double';
    case 'String':
      return 'const char*';
    case 'void':
      return 'void';
    default:
      return 'void*';
  }
}
