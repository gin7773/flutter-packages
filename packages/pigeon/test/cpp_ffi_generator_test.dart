// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/src/ast.dart';
import 'package:pigeon/src/cpp/cpp_ffi_generator.dart';
import 'package:pigeon/src/generator_tools.dart';
import 'package:pigeon/src/pigeon_lib.dart' show Error;
import 'package:test/test.dart';

const String _packageName = 'test_package';
final String _symbolPrefix = makeCppFfiSymbolPrefix(_packageName, 'messages_ffi.h');

void main() {
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

  test('generates C ABI header for sync HostApi', () {
    final root = Root(
      apis: <Api>[
        AstHostApi(
          name: 'CalculatorApi',
          methods: <Method>[
            Method(
              name: 'add',
              parameters: <Parameter>[
                Parameter(
                  type: const TypeDeclaration(baseName: 'int', isNullable: false),
                  name: 'x',
                ),
                Parameter(
                  type: const TypeDeclaration(baseName: 'int', isNullable: false),
                  name: 'y',
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

    final sink = StringBuffer();
    const CppFfiGenerator().generate(
      OutputFileOptions<InternalCppFfiOptions>(
        fileType: FileType.header,
        languageOptions: const InternalCppFfiOptions(
          headerIncludePath: 'messages_ffi.h',
          apiHeaderIncludePath: 'messages.h',
          cppFfiHeaderOut: 'messages_ffi.h',
          cppFfiSourceOut: 'messages_ffi.cc',
          namespace: 'test',
        ),
      ),
      root,
      sink,
      dartPackageName: _packageName,
    );

    final code = sink.toString();
    expect(code, contains('typedef struct PigeonFfiBuffer'));
    expect(code, contains('extern "C"'));
    expect(
      code,
      contains(
        'PIGEON_FFI_EXPORT PigeonFfiBuffer* ${_symbolPrefix}calculator_api_add(PigeonFfiBuffer* request);',
      ),
    );
    expect(code, contains('#include "messages.h"'));
    expect(code, contains('#include <functional>'));
    expect(code, contains('namespace test {'));
    expect(code, contains('class PigeonFfiSyncDispatcher'));
    expect(code, contains('virtual ::PigeonFfiBuffer* RunSync'));
    expect(code, contains('void SetUpCalculatorApiFfi('));
    expect(code, contains('CalculatorApi* api,'));
    expect(code, contains('PigeonFfiSyncDispatcher* dispatcher = nullptr);'));
  });

  test('generates C++ source dispatch for sync HostApi', () {
    final root = Root(
      apis: <Api>[
        AstHostApi(
          name: 'CalculatorApi',
          methods: <Method>[
            Method(
              name: 'add',
              parameters: <Parameter>[
                Parameter(
                  type: const TypeDeclaration(baseName: 'int', isNullable: false),
                  name: 'x',
                ),
                Parameter(
                  type: const TypeDeclaration(baseName: 'int', isNullable: false),
                  name: 'y',
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

    final sink = StringBuffer();
    const CppFfiGenerator().generate(
      OutputFileOptions<InternalCppFfiOptions>(
        fileType: FileType.source,
        languageOptions: const InternalCppFfiOptions(
          headerIncludePath: 'messages_ffi.h',
          apiHeaderIncludePath: 'messages.h',
          cppFfiHeaderOut: 'messages_ffi.h',
          cppFfiSourceOut: 'messages_ffi.cc',
          namespace: 'test',
        ),
      ),
      root,
      sink,
      dartPackageName: _packageName,
    );

    final code = sink.toString();
    expect(code, contains('#include "messages_ffi.h"'));
    expect(code, contains('namespace test {'));
    expect(code, contains('CalculatorApi* g_calculator_api_api = nullptr;'));
    expect(code, contains('PigeonFfiSyncDispatcher* g_calculator_api_dispatcher = nullptr;'));
    expect(code, contains('void SetUpCalculatorApiFfi('));
    expect(code, contains('PigeonFfiSyncDispatcher* dispatcher)'));
    expect(code, contains('g_calculator_api_dispatcher = dispatcher;'));
    expect(
      code,
      contains('std::unique_ptr<::flutter::EncodableValue> message = codec.DecodeMessage'),
    );
    expect(code, contains('const int64_t x_arg = encodable_x_arg.LongValue();'));
    expect(code, contains('ErrorOr<int64_t> output = g_calculator_api_api->Add(x_arg, y_arg);'));
    expect(code, contains('::flutter::EncodableValue(output.value())'));
    expect(code, contains('return PigeonFfiEncodeMessage'));
    expect(code, contains('PigeonCalculatorApiAddFfiDispatch(PigeonFfiBuffer* request)'));
    expect(code, contains('if (g_calculator_api_dispatcher != nullptr)'));
    expect(code, contains('return g_calculator_api_dispatcher->RunSync([request]() {'));
    expect(code, contains('return PigeonCalculatorApiAddFfi(request);'));
    expect(code, isNot(contains('TakeValue()')));
    expect(code, contains('}  // namespace test'));
    expect(
      code,
      contains(
        'extern "C" PigeonFfiBuffer* ${_symbolPrefix}calculator_api_add(PigeonFfiBuffer* request)',
      ),
    );
    expect(code, contains('return test::PigeonCalculatorApiAddFfiDispatch(request);'));
    expect(code, isNot(contains('TODO')));
  });

  test('generates C ABI adapter for async HostApi', () {
    final root = Root(
      apis: <Api>[
        AstHostApi(
          name: 'CalculatorApi',
          methods: <Method>[
            Method(
              name: 'add',
              parameters: <Parameter>[
                Parameter(
                  type: const TypeDeclaration(baseName: 'int', isNullable: false),
                  name: 'x',
                ),
                Parameter(
                  type: const TypeDeclaration(baseName: 'int', isNullable: false),
                  name: 'y',
                ),
              ],
              location: ApiLocation.host,
              returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
              isAsynchronous: true,
            ),
          ],
        ),
      ],
      classes: <Class>[],
      enums: <Enum>[],
    );

    final headerSink = StringBuffer();
    const CppFfiGenerator().generate(
      OutputFileOptions<InternalCppFfiOptions>(
        fileType: FileType.header,
        languageOptions: const InternalCppFfiOptions(
          headerIncludePath: 'messages_ffi.h',
          apiHeaderIncludePath: 'messages.h',
          cppFfiHeaderOut: 'messages_ffi.h',
          cppFfiSourceOut: 'messages_ffi.cc',
          namespace: 'test',
        ),
      ),
      root,
      headerSink,
      dartPackageName: _packageName,
    );

    final headerCode = headerSink.toString();
    expect(headerCode, contains('typedef void (*PigeonFfiReplyCallback)'));
    expect(headerCode, contains('PIGEON_FFI_EXPORT void ${_symbolPrefix}calculator_api_add('));
    expect(headerCode, contains('int64_t reply_id,'));
    expect(headerCode, contains('PigeonFfiReplyCallback on_reply);'));

    final sourceSink = StringBuffer();
    const CppFfiGenerator().generate(
      OutputFileOptions<InternalCppFfiOptions>(
        fileType: FileType.source,
        languageOptions: const InternalCppFfiOptions(
          headerIncludePath: 'messages_ffi.h',
          apiHeaderIncludePath: 'messages.h',
          cppFfiHeaderOut: 'messages_ffi.h',
          cppFfiSourceOut: 'messages_ffi.cc',
          namespace: 'test',
        ),
      ),
      root,
      sourceSink,
      dartPackageName: _packageName,
    );

    final sourceCode = sourceSink.toString();
    expect(sourceCode, contains('void PigeonFfiSendReply('));
    expect(sourceCode, contains('void PigeonCalculatorApiAddFfi('));
    expect(sourceCode, contains('[reply_id, on_reply](ErrorOr<int64_t>&& output)'));
    expect(sourceCode, contains('PigeonFfiSendReply(reply_id, on_reply'));
    expect(sourceCode, contains('void PigeonCalculatorApiAddFfiDispatch('));
    expect(
      sourceCode,
      contains('PigeonFfiBuffer* dispatch_error = g_calculator_api_dispatcher->RunSync([=]() {'),
    );
    expect(sourceCode, contains('return static_cast<PigeonFfiBuffer*>(nullptr);'));
    expect(sourceCode, contains('extern "C" void ${_symbolPrefix}calculator_api_add('));
    expect(
      sourceCode,
      contains('test::PigeonCalculatorApiAddFfiDispatch(request, reply_id, on_reply);'),
    );
  });

  test('generates C ABI adapter for EventChannelApi', () {
    final root = Root(
      apis: <Api>[
        AstEventChannelApi(
          name: 'EventApi',
          methods: <Method>[
            Method(
              name: 'streamEvents',
              parameters: <Parameter>[],
              location: ApiLocation.host,
              returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
            ),
          ],
        ),
      ],
      classes: <Class>[],
      enums: <Enum>[],
      containsEventChannel: true,
    );

    final headerSink = StringBuffer();
    const CppFfiGenerator().generate(
      OutputFileOptions<InternalCppFfiOptions>(
        fileType: FileType.header,
        languageOptions: const InternalCppFfiOptions(
          headerIncludePath: 'messages_ffi.h',
          apiHeaderIncludePath: 'messages.h',
          cppFfiHeaderOut: 'messages_ffi.h',
          cppFfiSourceOut: 'messages_ffi.cc',
          namespace: 'test',
        ),
      ),
      root,
      headerSink,
      dartPackageName: _packageName,
    );

    final headerCode = headerSink.toString();
    expect(headerCode, contains('typedef void (*PigeonFfiEventCallback)'));
    expect(headerCode, contains('${_symbolPrefix}event_api_stream_events_listen'));
    expect(headerCode, contains('${_symbolPrefix}event_api_stream_events_cancel'));
    expect(headerCode, contains('class PigeonEventApiStreamEventsEventSink'));
    expect(headerCode, contains('class PigeonEventApiStreamEventsStreamHandler'));
    expect(headerCode, contains('void SetUpEventApiStreamEventsFfi('));
    expect(headerCode, contains('PigeonFfiSyncDispatcher* dispatcher = nullptr);'));

    final sourceSink = StringBuffer();
    const CppFfiGenerator().generate(
      OutputFileOptions<InternalCppFfiOptions>(
        fileType: FileType.source,
        languageOptions: const InternalCppFfiOptions(
          headerIncludePath: 'messages_ffi.h',
          apiHeaderIncludePath: 'messages.h',
          cppFfiHeaderOut: 'messages_ffi.h',
          cppFfiSourceOut: 'messages_ffi.cc',
          namespace: 'test',
        ),
      ),
      root,
      sourceSink,
      dartPackageName: _packageName,
    );

    final sourceCode = sourceSink.toString();
    expect(sourceCode, contains('const ::flutter::StandardMessageCodec& PigeonFfiGetCodec()'));
    expect(
      sourceCode,
      contains(
        'PigeonEventApiStreamEventsStreamHandler* g_event_api_stream_events_handler = nullptr;',
      ),
    );
    expect(
      sourceCode,
      contains('PigeonFfiSyncDispatcher* g_event_api_stream_events_dispatcher = nullptr;'),
    );
    expect(sourceCode, contains('class PigeonEventApiStreamEventsEventSinkImpl'));
    expect(sourceCode, contains('handler->OnListen(instance_name, std::move(sink));'));
    expect(sourceCode, contains('handler->OnCancel(instance_name);'));
    expect(sourceCode, contains('return g_event_api_stream_events_dispatcher->RunSync([=]() {'));
    expect(sourceCode, contains('return test::PigeonEventApiStreamEventsListenFfiDispatch'));
    expect(sourceCode, contains('return test::PigeonEventApiStreamEventsCancelFfiDispatch'));
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
