// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:pigeon/src/ast.dart';
import 'package:pigeon/src/cpp/cpp_ffi_generator.dart';
import 'package:pigeon/src/cpp/cpp_generator.dart';
import 'package:pigeon/src/generator_tools.dart';
import 'package:pigeon/src/pigeon_lib.dart' show Error;
import 'package:test/test.dart';

const String _packageName = 'test_package';
final String _symbolPrefix = makeCppFfiSymbolPrefix(_packageName, 'messages_ffi.h');

void main() {
  final String? compiler = Platform.environment['PIGEON_TEST_CXX'];
  final String? zig = Platform.environment['PIGEON_TEST_ZIG'];
  final String? clientWrapper = Platform.environment['PIGEON_TEST_CPP_CLIENT_WRAPPER'];
  final String? skipReason = (compiler == null && zig == null) || clientWrapper == null
      ? 'Set PIGEON_TEST_CXX (clang++/g++) or PIGEON_TEST_ZIG, and '
            'PIGEON_TEST_CPP_CLIENT_WRAPPER. See cpp_ffi_guide.md#native-regression-tests.'
      : null;

  test(
    'generated C++ FFI preserves session, callback and codec lifetimes',
    () async {
      final wrapper = Directory(clientWrapper!);
      expect(wrapper.existsSync(), isTrue, reason: 'Invalid Flutter client_wrapper directory.');
      final Directory temporary = Directory.systemTemp.createTempSync('pigeon_cpp_ffi_native_');
      try {
        _generateNativeFixture(temporary);
        final fixture = File('test/testdata/cpp_ffi_native/main.cc');
        String source = fixture.readAsStringSync();
        final String prefix = makeCppFfiSymbolPrefix('native_test', 'messages_ffi.h');
        final replacements = <String, String>{
          'FREE': '${prefix}free_buffer',
          'CONNECT': '$prefix${makeCppFfiMemberName('session', 'Api')}_connect',
          'DISCONNECT': '$prefix${makeCppFfiMemberName('session', 'Api')}_disconnect',
          'EVENT_CONNECT':
              '$prefix${makeCppFfiMemberName('event_session', 'Events', 'events')}_connect',
          'EVENT_DISCONNECT':
              '$prefix${makeCppFfiMemberName('event_session', 'Events', 'events')}_disconnect',
          'LISTEN': '$prefix${makeCppFfiMemberName('event', 'Events', 'events')}_listen',
          'CANCEL': '$prefix${makeCppFfiMemberName('event', 'Events', 'events')}_cancel',
          for (final method in <String>['id', 'echo', 'echoAsync', 'hold'])
            method.toUpperCase(): '$prefix${makeCppFfiMemberName('host', 'Api', method)}',
        };
        source = source.replaceAllMapped(
          RegExp(r'\bPIGEON_TEST_([A-Z_]+)\b'),
          (Match match) => replacements[match[1]]!,
        );
        File(path.join(temporary.path, 'main.cc')).writeAsStringSync(source);
        final String executable = path.join(
          temporary.path,
          Platform.isWindows ? 'native.exe' : 'native',
        );
        await _runNativeProcess(compiler ?? zig!, <String>[
          if (compiler == null) 'c++',
          '-std=c++17',
          '-O0',
          if (!Platform.isWindows) '-pthread',
          '-I',
          path.join(wrapper.absolute.path, 'include'),
          'messages.cc',
          'messages_ffi.cc',
          'main.cc',
          path.join(wrapper.absolute.path, 'standard_codec.cc'),
          '-o',
          executable,
        ], temporary);
        final String output = await _runNativeProcess(executable, <String>[], temporary);
        expect(output, contains('All native C++ FFI regression checks passed.'));
      } finally {
        temporary.deleteSync(recursive: true);
      }
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final isNullable in <bool>[false, true]) {
    for (final isAsynchronous in <bool>[false, true]) {
      test('unwraps enum arguments (nullable: $isNullable, async: $isAsynchronous)', () {
        final state = Enum(
          name: 'State',
          members: <EnumMember>[EnumMember(name: 'ready')],
        );
        final root = Root(
          apis: <Api>[
            AstHostApi(
              name: 'Api',
              methods: <Method>[
                Method(
                  name: 'accept',
                  location: ApiLocation.host,
                  returnType: const TypeDeclaration.voidDeclaration(),
                  isAsynchronous: isAsynchronous,
                  parameters: <Parameter>[
                    Parameter(
                      name: 'state',
                      type: TypeDeclaration(
                        baseName: 'State',
                        isNullable: isNullable,
                        associatedEnum: state,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
          classes: <Class>[],
          enums: <Enum>[state],
        );
        final sink = StringBuffer();
        const CppFfiGenerator().generate(
          OutputFileOptions<InternalCppFfiOptions>(
            fileType: FileType.source,
            languageOptions: const InternalCppFfiOptions(
              headerIncludePath: 'messages_ffi.h',
              apiHeaderIncludePath: 'messages.h',
              cppFfiHeaderOut: 'messages_ffi.h',
              cppFfiSourceOut: 'messages_ffi.cc',
            ),
          ),
          root,
          sink,
          dartPackageName: _packageName,
        );
        expect(
          sink.toString(),
          contains(
            'std::any_cast<const State&>(std::get<::flutter::CustomEncodableValue>(encodable_state_arg))',
          ),
        );
        expect(sink.toString(), isNot(contains('encodable_state_arg.LongValue()')));
        if (isNullable) {
          expect(sink.toString(), contains('if (!encodable_state_arg.IsNull())'));
          expect(sink.toString(), contains('const State* state_arg = nullptr;'));
        }
      });
    }
  }

  test('isolates exported symbols for distinct output headers and packages', () {
    final outputs = <String>[];
    final guards = <String>[];
    for (final (String packageName, String header) in <(String, String)>[
      ('video', 'first/messages_ffi.h'),
      ('video', 'first/Messages_ffi.h'),
      ('video', 'second/messages_ffi.h'),
      ('audio', 'first/messages_ffi.h'),
    ]) {
      final sink = StringBuffer();
      const CppFfiGenerator().generate(
        OutputFileOptions<InternalCppFfiOptions>(
          fileType: FileType.header,
          languageOptions: InternalCppFfiOptions(
            headerIncludePath: header,
            apiHeaderIncludePath: 'messages.h',
            cppFfiHeaderOut: header,
            cppFfiSourceOut: 'messages_ffi.cc',
          ),
        ),
        Root.makeEmpty(),
        sink,
        dartPackageName: packageName,
      );
      final code = sink.toString();
      expect(code, contains('#ifndef PIGEON_FFI_ABI_TYPES_'));
      expect(code, contains('#endif  // PIGEON_FFI_ABI_TYPES_'));
      final String freeFunction = RegExp(r'void (\w+free_buffer)\(').firstMatch(code)![1]!;
      outputs.add(freeFunction);
      guards.add(RegExp(r'#ifndef (\w+)').firstMatch(code)![1]!);
    }
    expect(outputs.toSet(), hasLength(4));
    expect(guards.toSet(), hasLength(4));
  });

  test('C++ FFI options merge overrides only supplied values', () {
    const original = CppFfiOptions(
      headerIncludePath: 'messages_ffi.h',
      apiHeaderIncludePath: 'messages.h',
      namespace: 'original',
      copyrightHeader: <String>['Original copyright'],
    );
    final CppFfiOptions merged = original.merge(const CppFfiOptions(namespace: 'updated'));

    expect(merged.namespace, 'updated');
    expect(merged.headerIncludePath, 'messages_ffi.h');
    expect(merged.apiHeaderIncludePath, 'messages.h');
    expect(merged.copyrightHeader, <String>['Original copyright']);
    expect(original.namespace, 'original');
  });

  test('C ABI exports identify a session for every host and event call', () {
    final Root root = _root();
    final String code = _generate(root, FileType.header);
    final String host = makeCppFfiMemberName('host', 'CalculatorApi', 'add');
    final String session = makeCppFfiMemberName('session', 'CalculatorApi');
    final String event = makeCppFfiMemberName('event', 'EventApi', 'streamEvents');
    expect(code, contains('$_symbolPrefix${session}_connect(PigeonFfiBuffer* request)'));
    expect(code, contains('$_symbolPrefix${session}_disconnect(int64_t session_id)'));
    expect(code, contains('$_symbolPrefix$host(int64_t session_id, PigeonFfiBuffer* request)'));
    expect(code, contains('$_symbolPrefix${event}_listen('));
    expect(code, contains('$_symbolPrefix${event}_cancel('));
    expect(code, contains('void TearDownCalculatorApiFfi(const std::string& instance_name = "")'));
    expect(code, contains('const std::string& instance_name = ""'));
    expect(code, isNot(contains('PigeonFfiSyncDispatcher')));
  });

  test('HostApi calls hold registrations and suppress late or duplicate replies', () {
    final String code = _generate(_root(), FileType.source);
    expect(code, contains('session->registration->api->Add(x_arg)'));
    expect(code, isNot(contains('RunSync')));
    expect(code, contains('PigeonFfiLease registration_lease'));
    expect(code, contains('PigeonFfiLease session_lease'));
    expect(code, contains('FFI session has been disconnected.'));
    expect(code, contains('sent_.exchange(true)'));
    expect(code, contains('reply_state->Send('));
    expect(code, contains('catch (const std::exception& exception)'));
    expect(code, contains('catch (...)'));
    expect(code, isNot(contains('g_calculator_api_api')));
    expect(code, isNot(contains('dispatcher')));
  });

  test('named registration teardown closes gates before releasing borrowed implementations', () {
    final String code = _generate(_root(), FileType.source);
    expect(code, contains('const std::string& instance_name)'));
    expect(code, contains('.SetUp(api, instance_name)'));
    expect(code, contains('.TearDown(instance_name)'));
    expect(code, contains('idle_.wait(lock, [this] { return calls_ == 0; })'));
    expect(code, contains('Cannot close an FFI registration from its active call.'));
    expect(code, contains('session_->registration->gate'));
    expect(code, contains('session_->gate'));
    expect(code, contains('session->CancelStream(sink_id,'));
  });

  for (final asynchronous in <bool>[false, true]) {
    test('nullable int accepts both codec integer widths (async: $asynchronous)', () {
      final api = AstHostApi(
        name: 'Api',
        methods: <Method>[
          Method(
            name: 'accept',
            location: ApiLocation.host,
            isAsynchronous: asynchronous,
            returnType: const TypeDeclaration.voidDeclaration(),
            parameters: <Parameter>[
              Parameter(
                name: 'value',
                type: const TypeDeclaration(baseName: 'int', isNullable: true),
              ),
            ],
          ),
        ],
      );
      final root = Root(apis: <Api>[api], classes: <Class>[], enums: <Enum>[]);
      final String code = _generate(root, FileType.source);
      expect(code, contains('encodable_value_arg.LongValue()'));
      expect(code, contains('encodable_value_arg.IsNull() ? nullptr : &value_arg_value'));
      expect(code, isNot(contains('std::get_if<int64_t>(&encodable_value_arg)')));
    });
  }

  test('API and method boundaries cannot collide in C exports or C++ helpers', () {
    final root = Root(
      apis: <Api>[
        for (final (String api, String method) in <(String, String)>[
          ('FooBar', 'baz'),
          ('Foo', 'barBaz'),
          ('Api', 'freeBuffer'),
        ])
          AstHostApi(
            name: api,
            methods: <Method>[
              Method(
                name: method,
                location: ApiLocation.host,
                returnType: const TypeDeclaration.voidDeclaration(),
                parameters: <Parameter>[],
              ),
            ],
          ),
      ],
      classes: <Class>[],
      enums: <Enum>[],
    );
    final String header = _generate(root, FileType.header);
    final String source = _generate(root, FileType.source);
    final names = <String>{};
    for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
      final String name = makeCppFfiMemberName('host', api.name, api.methods.single.name);
      names.add(name);
      expect(header, contains('$_symbolPrefix$name(int64_t session_id,'));
      expect(source, contains('Pigeon_$name('));
    }
    expect(names, hasLength(3));
    expect(header, contains('${_symbolPrefix}free_buffer(PigeonFfiBuffer* buffer)'));
  });

  test('validates unsupported api shapes', () {
    final root = Root(
      apis: <Api>[
        AstHostApi(
          name: 'AsyncApi',
          methods: <Method>[
            Method(
              name: 'doIt',
              parameters: <Parameter>[],
              location: ApiLocation.host,
              returnType: const TypeDeclaration(baseName: 'void', isNullable: false),
              isAsynchronous: true,
            ),
          ],
        ),
        AstFlutterApi(name: 'CallbackApi', methods: <Method>[]),
        AstEventChannelApi(
          name: 'EventApi',
          methods: <Method>[
            Method(
              name: 'streamEvents',
              parameters: <Parameter>[],
              location: ApiLocation.host,
              returnType: const TypeDeclaration(baseName: 'void', isNullable: false),
            ),
          ],
        ),
      ],
      classes: <Class>[],
      enums: <Enum>[],
      containsEventChannel: true,
    );

    final List<Error> errors = validateCppFfi(
      const InternalCppFfiOptions(
        headerIncludePath: 'messages_ffi.h',
        apiHeaderIncludePath: 'messages.h',
        cppFfiHeaderOut: 'messages_ffi.h',
        cppFfiSourceOut: 'messages_ffi.cc',
      ),
      root,
    );

    expect(
      errors.map((Error error) => error.message),
      containsAll(<String>[
        'C++ FFI does not support FlutterApi "CallbackApi"',
        'C++ FFI does not support void EventChannelApi method "streamEvents"',
      ]),
    );
    expect(
      errors.map((Error error) => error.message),
      isNot(contains('C++ FFI does not support async HostApi method "doIt"')),
    );
  });
}

Root _root() => Root(
  apis: <Api>[
    AstHostApi(
      name: 'CalculatorApi',
      methods: <Method>[
        for (final asynchronous in <bool>[false, true])
          Method(
            name: asynchronous ? 'addAsync' : 'add',
            location: ApiLocation.host,
            isAsynchronous: asynchronous,
            returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
            parameters: <Parameter>[
              Parameter(
                name: 'x',
                type: const TypeDeclaration(baseName: 'int', isNullable: false),
              ),
            ],
          ),
      ],
    ),
    AstEventChannelApi(
      name: 'EventApi',
      methods: <Method>[
        Method(
          name: 'streamEvents',
          location: ApiLocation.host,
          returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
          parameters: <Parameter>[],
        ),
      ],
    ),
  ],
  classes: <Class>[],
  enums: <Enum>[],
  containsHostApi: true,
  containsEventChannel: true,
);

String _generate(
  Root root,
  FileType type, {
  String namespace = 'test',
  String dartPackageName = _packageName,
}) {
  final sink = StringBuffer();
  const CppFfiGenerator().generate(
    OutputFileOptions<InternalCppFfiOptions>(
      fileType: type,
      languageOptions: InternalCppFfiOptions(
        cppFfiHeaderOut: 'messages_ffi.h',
        cppFfiSourceOut: 'messages_ffi.cc',
        headerIncludePath: 'messages_ffi.h',
        apiHeaderIncludePath: 'messages.h',
        namespace: namespace,
      ),
    ),
    root,
    sink,
    dartPackageName: dartPackageName,
  );
  return sink.toString();
}

Future<String> _runNativeProcess(
  String executable,
  List<String> arguments,
  Directory workingDirectory,
) async {
  final Process process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory.path,
  );
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(minutes: 2));
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    fail('Native command timed out: $executable\n${await stdout}\n${await stderr}');
  }
  final output = '${await stdout}\n${await stderr}';
  expect(exitCode, 0, reason: 'Native command failed: $executable\n$output');
  return output;
}

void _generateNativeFixture(Directory output) {
  const intType = TypeDeclaration(baseName: 'int', isNullable: false);
  const nullableIntType = TypeDeclaration(baseName: 'int', isNullable: true);
  final root = Root(
    apis: <Api>[
      AstHostApi(
        name: 'Api',
        methods: <Method>[
          for (final method in <String>['id', 'hold'])
            Method(
              name: method,
              location: ApiLocation.host,
              isAsynchronous: method == 'hold',
              returnType: intType,
              parameters: <Parameter>[],
            ),
          for (final asynchronous in <bool>[false, true])
            Method(
              name: asynchronous ? 'echoAsync' : 'echo',
              location: ApiLocation.host,
              isAsynchronous: asynchronous,
              returnType: nullableIntType,
              parameters: <Parameter>[Parameter(name: 'value', type: nullableIntType)],
            ),
        ],
      ),
      AstEventChannelApi(
        name: 'Events',
        methods: <Method>[
          Method(
            name: 'events',
            location: ApiLocation.host,
            returnType: intType,
            parameters: <Parameter>[],
          ),
        ],
      ),
    ],
    classes: <Class>[],
    enums: <Enum>[],
    containsHostApi: true,
    containsEventChannel: true,
  );
  for (final type in <FileType>[FileType.header, FileType.source]) {
    final api = StringBuffer();
    const CppGenerator().generate(
      OutputFileOptions<InternalCppOptions>(
        fileType: type,
        languageOptions: const InternalCppOptions(
          headerIncludePath: 'messages.h',
          cppHeaderOut: 'messages.h',
          cppSourceOut: 'messages.cc',
          namespace: 'native_test',
        ),
      ),
      root,
      api,
      dartPackageName: 'native_test',
    );
    File(
      path.join(output.path, type == FileType.header ? 'messages.h' : 'messages.cc'),
    ).writeAsStringSync(api.toString());
    File(
      path.join(output.path, type == FileType.header ? 'messages_ffi.h' : 'messages_ffi.cc'),
    ).writeAsStringSync(
      _generate(root, type, namespace: 'native_test', dartPackageName: 'native_test'),
    );
  }
}
