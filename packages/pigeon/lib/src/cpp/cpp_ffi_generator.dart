// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:path/path.dart' as path;

import '../ast.dart';
import '../generator.dart';
import '../generator_tools.dart';
import '../pigeon_lib.dart';
import 'cpp_ffi_runtime.dart';

const String _codecSerializerName = '${classNamePrefix}CodecSerializer';

/// Options that control how C++ FFI adapter code will be generated.
class CppFfiOptions {
  /// Creates a [CppFfiOptions] object.
  const CppFfiOptions({
    this.headerIncludePath,
    this.apiHeaderIncludePath,
    this.namespace,
    this.copyrightHeader,
  });

  /// The generated FFI header include path used by the generated FFI source.
  final String? headerIncludePath;

  /// The generated C++ API header include path used by the generated FFI header.
  final String? apiHeaderIncludePath;

  /// The namespace where the generated C++ API lives.
  final String? namespace;

  /// A copyright header that will get prepended to generated code.
  final Iterable<String>? copyrightHeader;

  /// Creates a [CppFfiOptions] from a Map representation where:
  /// `x = CppFfiOptions.fromMap(x.toMap())`.
  static CppFfiOptions fromMap(Map<String, Object> map) {
    return CppFfiOptions(
      headerIncludePath: map['headerIncludePath'] as String?,
      apiHeaderIncludePath: map['apiHeaderIncludePath'] as String?,
      namespace: map['namespace'] as String?,
      copyrightHeader: map['copyrightHeader'] as Iterable<String>?,
    );
  }

  /// Converts a [CppFfiOptions] to a Map representation where:
  /// `x = CppFfiOptions.fromMap(x.toMap())`.
  Map<String, Object> toMap() {
    return <String, Object>{
      if (headerIncludePath != null) 'headerIncludePath': headerIncludePath!,
      if (apiHeaderIncludePath != null) 'apiHeaderIncludePath': apiHeaderIncludePath!,
      if (namespace != null) 'namespace': namespace!,
      if (copyrightHeader != null) 'copyrightHeader': copyrightHeader!,
    };
  }

  /// Overrides any non-null parameters from [options] into this to make a new
  /// [CppFfiOptions].
  CppFfiOptions merge(CppFfiOptions options) {
    return CppFfiOptions.fromMap(mergePigeonMaps(toMap(), options.toMap()));
  }
}

/// Options that control how C++ FFI adapter code will be generated.
///
/// For internal use only.
class InternalCppFfiOptions extends InternalOptions {
  /// Creates an [InternalCppFfiOptions] object.
  const InternalCppFfiOptions({
    required this.headerIncludePath,
    required this.apiHeaderIncludePath,
    required this.cppFfiHeaderOut,
    required this.cppFfiSourceOut,
    this.namespace,
    this.copyrightHeader,
  });

  /// Creates [InternalCppFfiOptions] from [CppFfiOptions].
  InternalCppFfiOptions.fromCppFfiOptions(
    CppFfiOptions options, {
    required this.cppFfiHeaderOut,
    required this.cppFfiSourceOut,
    required String fallbackApiHeaderIncludePath,
    String? fallbackNamespace,
    Iterable<String>? copyrightHeader,
  }) : headerIncludePath = options.headerIncludePath ?? path.basename(cppFfiHeaderOut),
       apiHeaderIncludePath = options.apiHeaderIncludePath ?? fallbackApiHeaderIncludePath,
       namespace = options.namespace ?? fallbackNamespace,
       copyrightHeader = options.copyrightHeader ?? copyrightHeader;

  /// The generated FFI header include path used by the generated FFI source.
  final String headerIncludePath;

  /// The generated C++ API header include path used by the generated FFI header.
  final String apiHeaderIncludePath;

  /// Path to the ".h" C++ FFI adapter file that will be generated.
  final String cppFfiHeaderOut;

  /// Path to the ".cpp" C++ FFI adapter file that will be generated.
  final String cppFfiSourceOut;

  /// The namespace where the generated C++ API lives.
  final String? namespace;

  /// A copyright header that will get prepended to generated code.
  final Iterable<String>? copyrightHeader;
}

/// Class that manages all C++ FFI adapter code generation.
class CppFfiGenerator extends Generator<OutputFileOptions<InternalCppFfiOptions>> {
  /// Constructor.
  const CppFfiGenerator();

  /// Generates C++ FFI adapter file of type specified in [generatorOptions].
  @override
  void generate(
    OutputFileOptions<InternalCppFfiOptions> generatorOptions,
    Root root,
    StringSink sink, {
    required String dartPackageName,
  }) {
    assert(
      generatorOptions.fileType == FileType.header || generatorOptions.fileType == FileType.source,
    );

    final indent = Indent();
    final String symbolPrefix = makeCppFfiSymbolPrefix(
      dartPackageName,
      generatorOptions.languageOptions.cppFfiHeaderOut,
    );
    _writeFilePrologue(generatorOptions.languageOptions, indent);
    if (generatorOptions.fileType == FileType.header) {
      _writeHeader(generatorOptions.languageOptions, root, indent, symbolPrefix);
    } else {
      _writeSource(generatorOptions.languageOptions, root, indent, symbolPrefix);
    }
    sink.write(indent.toString());
  }
}

void _writeFilePrologue(InternalCppFfiOptions generatorOptions, Indent indent) {
  if (generatorOptions.copyrightHeader != null) {
    addLines(indent, generatorOptions.copyrightHeader!, linePrefix: '// ');
  }
  indent.writeln('// ${getGeneratedCodeWarning()}');
  indent.writeln('// $seeAlsoWarning');
  indent.newln();
}

void _writeHeader(InternalCppFfiOptions options, Root root, Indent indent, String symbolPrefix) {
  final String guardName = _getGuardName(symbolPrefix);
  indent.writeln('#ifndef $guardName');
  indent.writeln('#define $guardName');
  indent.newln();
  indent.writeln('#include <stddef.h>');
  indent.writeln('#include <stdint.h>');
  indent.newln();
  indent.writeln('#ifdef __cplusplus');
  indent.writeln('#include <memory>');
  indent.writeln('#include <optional>');
  indent.writeln('#include <string>');
  indent.writeln('#include <vector>');
  indent.writeln('#include "${options.apiHeaderIncludePath}"');
  indent.writeln('#endif');
  indent.newln();
  indent.format(r'''
#if defined(_WIN32)
#define PIGEON_FFI_EXPORT __declspec(dllexport)
#else
#define PIGEON_FFI_EXPORT __attribute__((visibility("default")))
#endif
''');
  indent.writeln('#ifdef __cplusplus');
  indent.writeln('extern "C" {');
  indent.writeln('#endif');
  indent.newln();
  indent.format(r'''
#ifndef PIGEON_FFI_ABI_TYPES_
#define PIGEON_FFI_ABI_TYPES_
typedef struct PigeonFfiBuffer {
  uint8_t* data;
  size_t length;
} PigeonFfiBuffer;

typedef void (*PigeonFfiReplyCallback)(int64_t reply_id, PigeonFfiBuffer* reply);
typedef void (*PigeonFfiEventCallback)(int64_t sink_id, PigeonFfiBuffer* event);
typedef void (*PigeonFfiDoneCallback)(int64_t sink_id);
#endif  // PIGEON_FFI_ABI_TYPES_
''');
  indent.writeln('// Frees a buffer returned by a generated FFI function.');
  indent.writeln('PIGEON_FFI_EXPORT void ${symbolPrefix}free_buffer(PigeonFfiBuffer* buffer);');
  indent.writeln(
    '// The caller owns request; free returned buffers with ${symbolPrefix}free_buffer.',
  );
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    _writeSessionDeclarations(indent, symbolPrefix, _hostSessionName(api));
    for (final Method method in api.methods) {
      if (method.isAsynchronous || method.isAsynchronousCallback) {
        indent.writeln('PIGEON_FFI_EXPORT void ${_ffiFunctionName(api, method, symbolPrefix)}(');
        indent.nest(1, () {
          indent.writeln('int64_t session_id,');
          indent.writeln('PigeonFfiBuffer* request,');
          indent.writeln('int64_t reply_id,');
          indent.writeln('PigeonFfiReplyCallback on_reply);');
        });
      } else {
        indent.writeln(
          'PIGEON_FFI_EXPORT PigeonFfiBuffer* ${_ffiFunctionName(api, method, symbolPrefix)}(int64_t session_id, PigeonFfiBuffer* request);',
        );
      }
    }
  }
  for (final AstEventChannelApi api in root.apis.whereType<AstEventChannelApi>()) {
    for (final Method method in api.methods) {
      _writeSessionDeclarations(indent, symbolPrefix, _eventSessionName(api, method));
      indent.writeln(
        'PIGEON_FFI_EXPORT PigeonFfiBuffer* ${_eventListenFunctionName(api, method, symbolPrefix)}(',
      );
      indent.nest(1, () {
        indent.writeln('int64_t session_id,');
        indent.writeln('PigeonFfiBuffer* request,');
        indent.writeln('int64_t sink_id,');
        indent.writeln('PigeonFfiEventCallback on_event,');
        indent.writeln('PigeonFfiEventCallback on_error,');
        indent.writeln('PigeonFfiDoneCallback on_done);');
      });
      indent.writeln(
        'PIGEON_FFI_EXPORT PigeonFfiBuffer* ${_eventCancelFunctionName(api, method, symbolPrefix)}(',
      );
      indent.nest(1, () {
        indent.writeln('int64_t session_id,');
        indent.writeln('PigeonFfiBuffer* request,');
        indent.writeln('int64_t sink_id);');
      });
    }
  }
  indent.newln();
  indent.writeln('#ifdef __cplusplus');
  indent.writeln('}');
  indent.writeln('#endif');
  indent.newln();
  indent.writeln('#ifdef __cplusplus');
  _writeCppSetUpDeclarations(options, root, indent);
  indent.writeln('#endif');
  indent.newln();
  indent.writeln('#endif  // $guardName');
}

void _writeSessionDeclarations(Indent indent, String prefix, String name) {
  indent.writeln(
    'PIGEON_FFI_EXPORT PigeonFfiBuffer* $prefix${name}_connect(PigeonFfiBuffer* request);',
  );
  indent.writeln(
    'PIGEON_FFI_EXPORT PigeonFfiBuffer* $prefix${name}_disconnect(int64_t session_id);',
  );
}

void _writeCppSetUpDeclarations(InternalCppFfiOptions options, Root root, Indent indent) {
  final List<AstHostApi> hostApis = root.apis.whereType<AstHostApi>().toList();
  final List<AstEventChannelApi> eventChannelApis = root.apis
      .whereType<AstEventChannelApi>()
      .toList();

  void writeDeclarations() {
    indent.writeln("// FFI calls run on the caller's thread. Implementations own thread dispatch.");
    for (final api in hostApis) {
      indent.writeln('void SetUp${api.name}Ffi(');
      indent.nest(1, () {
        indent.writeln('${api.name}* api,');
        indent.writeln('const std::string& instance_name = "");');
      });
      indent.writeln('void TearDown${api.name}Ffi(const std::string& instance_name = "");');
    }
    for (final api in eventChannelApis) {
      for (final Method method in api.methods) {
        _writeEventChannelSetUpDeclaration(indent, api, method);
      }
    }
  }

  if (options.namespace == null) {
    writeDeclarations();
    return;
  }
  indent.writeln('namespace ${options.namespace} {');
  indent.nest(1, writeDeclarations);
  indent.writeln('}  // namespace ${options.namespace}');
}

void _writeEventChannelSetUpDeclaration(Indent indent, AstEventChannelApi api, Method method) {
  final HostDatatype eventType = getHostDatatype(method.returnType, _baseCppTypeForBuiltinDartType);
  final String sinkName = _eventSinkName(api, method);
  final String handlerName = _eventStreamHandlerName(api, method);
  indent.newln();
  indent.writeln('class $sinkName {');
  indent.nest(1, () {
    indent.writeln('public:');
    indent.nest(1, () {
      indent.writeln('virtual ~$sinkName() = default;');
      indent.writeln('virtual void Success(${_eventSinkParameterType(eventType)}) = 0;');
      indent.writeln('virtual void Error(const FlutterError& error) = 0;');
      indent.writeln('virtual void EndOfStream() = 0;');
    });
  });
  indent.writeln('};');
  indent.newln();
  indent.writeln('class $handlerName {');
  indent.nest(1, () {
    indent.writeln('public:');
    indent.nest(1, () {
      indent.writeln('virtual ~$handlerName() = default;');
      indent.writeln('virtual std::optional<FlutterError> OnListen(');
      indent.nest(1, () {
        indent.writeln('const std::string& instance_name,');
        indent.writeln('std::unique_ptr<$sinkName> sink) {');
      });
      indent.nest(1, () {
        indent.writeln('(void)instance_name;');
        indent.writeln('(void)sink;');
        indent.writeln('return std::nullopt;');
      });
      indent.writeln('}');
      indent.writeln('virtual std::optional<FlutterError> OnCancel(');
      indent.nest(1, () {
        indent.writeln('const std::string& instance_name) {');
      });
      indent.nest(1, () {
        indent.writeln('(void)instance_name;');
        indent.writeln('return std::nullopt;');
      });
      indent.writeln('}');
    });
  });
  indent.writeln('};');
  indent.newln();
  indent.writeln('void SetUp${api.name}${_methodName(method)}Ffi(');
  indent.nest(1, () {
    indent.writeln('$handlerName* handler,');
    indent.writeln('const std::string& instance_name = "");');
  });
  indent.writeln(
    'void TearDown${api.name}${_methodName(method)}Ffi(const std::string& instance_name = "");',
  );
}

void _writeSource(InternalCppFfiOptions options, Root root, Indent indent, String symbolPrefix) {
  indent.writeln('#include "${options.headerIncludePath}"');
  indent.newln();
  indent.writeln('#include <any>');
  indent.writeln('#include <atomic>');
  indent.writeln('#include <condition_variable>');
  indent.writeln('#include <cstdio>');
  indent.writeln('#include <cstring>');
  indent.writeln('#include <exception>');
  indent.writeln('#include <functional>');
  indent.writeln('#include <memory>');
  indent.writeln('#include <limits>');
  indent.writeln('#include <map>');
  indent.writeln('#include <mutex>');
  indent.writeln('#include <set>');
  indent.writeln('#include <stdexcept>');
  indent.writeln('#include <string>');
  indent.writeln('#include <utility>');
  indent.writeln('#include <vector>');
  indent.newln();
  indent.writeln('namespace {');
  indent.nest(1, () {
    indent.format(cppFfiRuntime);
    indent.format('''
PigeonFfiBuffer* PigeonFfiMakeBuffer(const std::vector<uint8_t>& message) {
  auto* buffer = new PigeonFfiBuffer();
  buffer->length = message.size();
  buffer->data = nullptr;
  if (!message.empty()) {
    buffer->data = new uint8_t[message.size()];
    std::memcpy(buffer->data, message.data(), message.size());
  }
  return buffer;
}

PigeonFfiBuffer* PigeonFfiEncodeMessage(
    const ::flutter::StandardMessageCodec& codec,
    const ::flutter::EncodableValue& value) {
  std::unique_ptr<std::vector<uint8_t>> message = codec.EncodeMessage(value);
  return PigeonFfiMakeBuffer(*message);
}

PigeonFfiBuffer* PigeonFfiEncodeError(
    const ::flutter::StandardMessageCodec& codec,
    const ::flutter::EncodableValue& error) {
  return PigeonFfiEncodeMessage(codec, error);
}

PigeonFfiBuffer* PigeonFfiEncodeErrorMessage(
    const ::flutter::StandardMessageCodec& codec,
    const std::string& message) {
  return PigeonFfiEncodeError(
      codec,
      ::flutter::EncodableValue(::flutter::EncodableList{
          ::flutter::EncodableValue("error"),
          ::flutter::EncodableValue(message),
          ::flutter::EncodableValue()}));
}

class PigeonFfiReplyState {
 public:
  PigeonFfiReplyState(int64_t id, PigeonFfiReplyCallback callback,
      std::shared_ptr<PigeonFfiGate> registration,
      std::shared_ptr<PigeonFfiGate> session)
      : id_(id), callback_(callback), registration_(std::move(registration)),
        session_(std::move(session)) {}
  void Send(PigeonFfiBuffer* reply) {
    PigeonFfiLease registration_lease(registration_);
    PigeonFfiLease session_lease(session_);
    if (sent_.exchange(true) || !callback_ ||
        (registration_ && !registration_lease) || (session_ && !session_lease)) {
      ${symbolPrefix}free_buffer(reply);
      return;
    }
    callback_(id_, reply);
  }
 private:
  int64_t id_;
  PigeonFfiReplyCallback callback_;
  std::shared_ptr<PigeonFfiGate> registration_;
  std::shared_ptr<PigeonFfiGate> session_;
  std::atomic<bool> sent_{false};
};
''');
  });
  indent.writeln('}  // namespace');
  indent.newln();
  indent.format('''
void ${symbolPrefix}free_buffer(PigeonFfiBuffer* buffer) {
  PigeonFfiDestroyBuffer(buffer);
}
''');

  if (options.namespace != null) {
    indent.writeln('namespace ${options.namespace} {');
  }
  indent.writeln('namespace {');
  _writeEventChannelUtilities(indent);
  indent.writeln('}  // namespace');
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    _writeApiSource(indent, api);
  }
  for (final AstEventChannelApi api in root.apis.whereType<AstEventChannelApi>()) {
    _writeEventChannelApiSource(indent, api);
  }
  if (options.namespace != null) {
    indent.writeln('}  // namespace ${options.namespace}');
    indent.newln();
  }

  String qualify(String name) => options.namespace == null ? name : '${options.namespace}::$name';
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    _writeSessionExports(
      indent,
      symbolPrefix,
      _hostSessionName(api),
      qualify(_registryName(api.name)),
      '${qualify(api.name)}::GetCodec()',
      qualify('PigeonFfiDecodeInstanceName'),
    );
    for (final Method method in api.methods) {
      final String helper = qualify(_ffiHelperName(api, method));
      final String registry = qualify(_registryName(api.name));
      if (method.isAsynchronous || method.isAsynchronousCallback) {
        indent.format('''
extern "C" void ${_ffiFunctionName(api, method, symbolPrefix)}(
    int64_t session_id, PigeonFfiBuffer* request, int64_t reply_id,
    PigeonFfiReplyCallback on_reply) {
  const auto& codec = ${qualify(api.name)}::GetCodec();
  auto session = $registry.Get(session_id);
  auto reply_state = std::make_shared<PigeonFfiReplyState>(reply_id, on_reply,
      session ? session->registration->gate : nullptr, session ? session->gate : nullptr);
  try {
    $helper(session, request, reply_state);
  } catch (const std::exception& error) {
    reply_state->Send(PigeonFfiEncodeErrorMessage(codec, error.what()));
  } catch (...) {
    reply_state->Send(PigeonFfiEncodeErrorMessage(codec, "Unknown native exception."));
  }
}
''');
      } else {
        indent.format('''
extern "C" PigeonFfiBuffer* ${_ffiFunctionName(api, method, symbolPrefix)}(
    int64_t session_id, PigeonFfiBuffer* request) {
  const auto& codec = ${qualify(api.name)}::GetCodec();
  try {
    return $helper($registry.Get(session_id), request);
  } catch (const std::exception& error) {
    return PigeonFfiEncodeErrorMessage(codec, error.what());
  } catch (...) {
    return PigeonFfiEncodeErrorMessage(codec, "Unknown native exception.");
  }
}
''');
      }
    }
  }
  for (final AstEventChannelApi api in root.apis.whereType<AstEventChannelApi>()) {
    for (final Method method in api.methods) {
      final String registry = qualify(_registryName(_eventSessionName(api, method)));
      _writeSessionExports(
        indent,
        symbolPrefix,
        _eventSessionName(api, method),
        registry,
        '${qualify('PigeonFfiGetCodec')}()',
        qualify('PigeonFfiDecodeInstanceName'),
      );
      for (final listen in <bool>[true, false]) {
        final String name = listen
            ? _eventListenFunctionName(api, method, symbolPrefix)
            : _eventCancelFunctionName(api, method, symbolPrefix);
        final String helper = qualify(
          listen ? _eventListenHelperName(api, method) : _eventCancelHelperName(api, method),
        );
        indent.format('''
extern "C" PigeonFfiBuffer* $name(
    int64_t session_id, PigeonFfiBuffer* request, int64_t sink_id${listen ? ', PigeonFfiEventCallback on_event, PigeonFfiEventCallback on_error, PigeonFfiDoneCallback on_done' : ''}) {
  const auto& codec = ${qualify('PigeonFfiGetCodec')}();
  try {
    return $helper($registry.Get(session_id), request, sink_id${listen ? ', on_event, on_error, on_done' : ''});
  } catch (const std::exception& error) {
    return PigeonFfiEncodeErrorMessage(codec, error.what());
  } catch (...) {
    return PigeonFfiEncodeErrorMessage(codec, "Unknown native exception.");
  }
}
''');
      }
    }
  }
}

void _writeSessionExports(
  Indent indent,
  String prefix,
  String name,
  String registry,
  String codec,
  String decode,
) {
  indent.format('''
extern "C" PigeonFfiBuffer* $prefix${name}_connect(PigeonFfiBuffer* request) {
  const auto& codec = $codec;
  try {
    std::string name;
    auto* error = $decode(codec, request, &name);
    if (error) return error;
    const int64_t id = $registry.Connect(name);
    return PigeonFfiEncodeMessage(codec, ::flutter::EncodableValue(::flutter::EncodableList{::flutter::EncodableValue(id)}));
  } catch (const std::exception& error) {
    return PigeonFfiEncodeErrorMessage(codec, error.what());
  } catch (...) {
    return PigeonFfiEncodeErrorMessage(codec, "Unknown native exception.");
  }
}
extern "C" PigeonFfiBuffer* $prefix${name}_disconnect(int64_t session_id) {
  const auto& codec = $codec;
  try {
    $registry.Disconnect(session_id);
    return PigeonFfiEncodeMessage(codec, ::flutter::EncodableValue(::flutter::EncodableList{::flutter::EncodableValue()}));
  } catch (const std::exception& error) {
    return PigeonFfiEncodeErrorMessage(codec, error.what());
  } catch (...) {
    return PigeonFfiEncodeErrorMessage(codec, "Unknown native exception.");
  }
}
''');
}

void _writeApiSource(Indent indent, AstHostApi api) {
  final String registry = _registryName(api.name);
  indent.format('''
namespace {
PigeonFfiRegistry<${api.name}> $registry;
}
void SetUp${api.name}Ffi(${api.name}* api, const std::string& instance_name) {
  $registry.SetUp(api, instance_name);
}
void TearDown${api.name}Ffi(const std::string& instance_name) {
  $registry.TearDown(instance_name);
}
''');
  for (final Method method in api.methods) {
    if (method.isAsynchronous || method.isAsynchronousCallback) {
      _writeAsyncMethodSource(indent, api, method);
    } else {
      _writeMethodSource(indent, api, method);
    }
  }
}

void _writeEventChannelUtilities(Indent indent) {
  indent.newln();
  indent.format('''
const ::flutter::StandardMessageCodec& PigeonFfiGetCodec() {
\treturn ::flutter::StandardMessageCodec::GetInstance(
\t\t\t&$_codecSerializerName::GetInstance());
}

PigeonFfiBuffer* PigeonFfiEncodeFlutterError(
\t\tconst ::flutter::StandardMessageCodec& codec,
\t\tconst FlutterError& error) {
\treturn PigeonFfiEncodeError(
\t\t\tcodec,
\t\t\t::flutter::EncodableValue(::flutter::EncodableList{
\t\t\t\t\t::flutter::EncodableValue(error.code()),
\t\t\t\t\t::flutter::EncodableValue(error.message()),
\t\t\t\t\terror.details()}));
}

PigeonFfiBuffer* PigeonFfiDecodeInstanceName(
\t\tconst ::flutter::StandardMessageCodec& codec,
\t\tPigeonFfiBuffer* request,
\t\tstd::string* instance_name) {
\tif (request == nullptr || request->data == nullptr) {
\t\treturn PigeonFfiEncodeErrorMessage(codec, "Request buffer is null.");
\t}
\tstd::unique_ptr<::flutter::EncodableValue> message =
\t\t\tcodec.DecodeMessage(request->data, request->length);
\tif (!message) {
\t\treturn PigeonFfiEncodeErrorMessage(codec, "Unable to decode request.");
\t}
\tconst auto* args = std::get_if<::flutter::EncodableList>(message.get());
\tif (args == nullptr || args->size() != 1) {
\t\treturn PigeonFfiEncodeErrorMessage(
\t\t\t\tcodec, "Unexpected event channel listen arguments.");
\t}
\tconst auto* instance_name_arg = std::get_if<std::string>(&args->at(0));
\tif (instance_name_arg == nullptr) {
\t\treturn PigeonFfiEncodeErrorMessage(codec, "Instance name must be a string.");
\t}
\t*instance_name = *instance_name_arg;
\treturn nullptr;
}
''');
}

void _writeEventChannelApiSource(Indent indent, AstEventChannelApi api) {
  for (final Method method in api.methods) {
    _writeEventChannelMethodSource(indent, api, method);
  }
}

void _writeEventChannelMethodSource(Indent indent, AstEventChannelApi api, Method method) {
  final HostDatatype eventType = getHostDatatype(method.returnType, _baseCppTypeForBuiltinDartType);
  final String sinkName = _eventSinkName(api, method);
  final String sinkImplName = _eventSinkImplName(api, method);
  final String handlerName = _eventStreamHandlerName(api, method);
  final String registry = _registryName(_eventSessionName(api, method));
  indent.format('''
namespace {
PigeonFfiRegistry<$handlerName> $registry;
}
void SetUp${api.name}${_methodName(method)}Ffi($handlerName* handler, const std::string& instance_name) {
  $registry.SetUp(handler, instance_name,
      []($handlerName* handler, const std::string& name) {
        auto error = handler->OnCancel(name);
        if (error) throw std::runtime_error(error->message());
      });
}
void TearDown${api.name}${_methodName(method)}Ffi(const std::string& instance_name) {
  $registry.TearDown(instance_name);
}
''');
  _writeEventSinkImpl(indent, sinkName, sinkImplName, eventType, handlerName);
  _writeEventListenSource(indent, api, method, sinkImplName, 'session->registration->api');
  _writeEventCancelSource(indent, api, method, 'session->registration->api');
}

void _writeSessionLeases(Indent indent, {bool asynchronous = false}) {
  indent.format('''
PigeonFfiLease registration_lease(session ? session->registration->gate : nullptr);
PigeonFfiLease session_lease(session ? session->gate : nullptr);
if (!registration_lease || !session_lease) {
  ${asynchronous ? 'reply_state->Send(PigeonFfiEncodeErrorMessage(codec, "FFI session has been disconnected."));\n  return;' : 'return PigeonFfiEncodeErrorMessage(codec, "FFI session has been disconnected.");'}
}
''');
}

void _writeEventSinkImpl(
  Indent indent,
  String sinkName,
  String sinkImplName,
  HostDatatype eventType,
  String handlerName,
) {
  final String eventValueExpression = _eventEncodableValueExpression(eventType, 'event');
  final String nullableEventValueExpression = _eventEncodableValueExpression(eventType, '*event');
  indent.writeln('class $sinkImplName : public $sinkName {');
  indent.nest(1, () {
    indent.writeln('public:');
    indent.nest(1, () {
      indent.writeln(
        '$sinkImplName(std::shared_ptr<PigeonFfiSession<$handlerName>> session, int64_t sink_id, PigeonFfiEventCallback on_event, '
        'PigeonFfiEventCallback on_error, PigeonFfiDoneCallback on_done)',
      );
      indent.nest(2, () {
        indent.writeln(': session_(std::move(session)), sink_id_(sink_id),');
        indent.writeln('  on_event_(on_event),');
        indent.writeln('  on_error_(on_error),');
        indent.writeln('  on_done_(on_done) {}');
      });
      indent.newln();
      indent.writeln('void Success(${_eventSinkParameterType(eventType)}) override {');
      indent.nest(1, () {
        _writeEventCallbackLeases(indent);
        indent.writeScoped('if (on_event_ == nullptr) {', '}', () {
          indent.writeln('return;');
        });
        indent.writeln('const auto& codec = PigeonFfiGetCodec();');
        if (eventType.isNullable) {
          indent.writeScoped('if (event == nullptr) {', '}', () {
            indent.writeln(
              'on_event_(sink_id_, PigeonFfiEncodeMessage(codec, ::flutter::EncodableValue()));',
            );
            indent.writeln('return;');
          });
          indent.writeln(
            'on_event_(sink_id_, PigeonFfiEncodeMessage(codec, '
            '$nullableEventValueExpression));',
          );
        } else {
          indent.writeln(
            'on_event_(sink_id_, PigeonFfiEncodeMessage(codec, '
            '$eventValueExpression));',
          );
        }
      });
      indent.writeln('}');
      indent.newln();
      indent.writeln('void Error(const FlutterError& error) override {');
      indent.nest(1, () {
        _writeEventCallbackLeases(indent);
        indent.writeScoped('if (on_error_ == nullptr) {', '}', () {
          indent.writeln('return;');
        });
        indent.writeln(
          'on_error_(sink_id_, PigeonFfiEncodeFlutterError(PigeonFfiGetCodec(), error));',
        );
      });
      indent.writeln('}');
      indent.newln();
      indent.writeln('void EndOfStream() override {');
      indent.nest(1, () {
        _writeEventCallbackLeases(indent);
        indent.writeScoped('if (on_done_ != nullptr) {', '}', () {
          indent.writeln('on_done_(sink_id_);');
        });
      });
      indent.writeln('}');
      indent.newln();
      indent.writeln('private:');
      indent.nest(1, () {
        indent.writeln('std::shared_ptr<PigeonFfiSession<$handlerName>> session_;');
        indent.writeln('int64_t sink_id_;');
        indent.writeln('PigeonFfiEventCallback on_event_;');
        indent.writeln('PigeonFfiEventCallback on_error_;');
        indent.writeln('PigeonFfiDoneCallback on_done_;');
      });
    });
  });
  indent.writeln('};');
  indent.newln();
}

void _writeEventCallbackLeases(Indent indent) {
  indent.format('''
PigeonFfiLease registration_lease(session_->registration->gate);
PigeonFfiLease session_lease(session_->gate);
if (!registration_lease || !session_lease) return;
''');
}

void _writeEventListenSource(
  Indent indent,
  AstEventChannelApi api,
  Method method,
  String sinkImplName,
  String handlerVariable,
) {
  indent.writeln('PigeonFfiBuffer* ${_eventListenHelperName(api, method)}(');
  indent.nest(1, () {
    indent.writeln(
      'std::shared_ptr<PigeonFfiSession<${_eventStreamHandlerName(api, method)}>> session,',
    );
    indent.writeln('PigeonFfiBuffer* request,');
    indent.writeln('int64_t sink_id,');
    indent.writeln('PigeonFfiEventCallback on_event,');
    indent.writeln('PigeonFfiEventCallback on_error,');
    indent.writeln('PigeonFfiDoneCallback on_done) {');
  });
  indent.nest(1, () {
    indent.writeln('const auto& codec = PigeonFfiGetCodec();');
    _writeSessionLeases(indent);
    indent.writeScoped('try {', '}', () {
      indent.writeln('std::string instance_name;');
      indent.writeln(
        'PigeonFfiBuffer* decode_error = PigeonFfiDecodeInstanceName(codec, request, &instance_name);',
      );
      indent.writeScoped('if (decode_error != nullptr) {', '}', () {
        indent.writeln('return decode_error;');
      });
      indent.writeln(
        'session->Listen(sink_id, instance_name);\nauto sink = std::make_unique<$sinkImplName>(session, sink_id, on_event, on_error, on_done);',
      );
      indent.writeln(
        'std::optional<FlutterError> output = $handlerVariable->OnListen(instance_name, std::move(sink));',
      );
      indent.writeScoped('if (output.has_value()) {', '}', () {
        indent.writeln('return PigeonFfiEncodeFlutterError(codec, output.value());');
      });
      _writeNullSuccess(indent);
    }, addTrailingNewline: false);
    indent.add(' catch (const std::exception& exception) ');
    indent.addScoped('{', '}', () {
      indent.writeln('return PigeonFfiEncodeErrorMessage(codec, exception.what());');
    });
  });
  indent.writeln('}');
  indent.newln();
}

void _writeEventCancelSource(
  Indent indent,
  AstEventChannelApi api,
  Method method,
  String handlerVariable,
) {
  indent.writeln(
    'PigeonFfiBuffer* ${_eventCancelHelperName(api, method)}(std::shared_ptr<PigeonFfiSession<${_eventStreamHandlerName(api, method)}>> session, PigeonFfiBuffer* request, int64_t sink_id) {',
  );
  indent.nest(1, () {
    indent.writeln('(void)request;');
    indent.writeln('const auto& codec = PigeonFfiGetCodec();');
    _writeSessionLeases(indent);
    indent.writeScoped('try {', '}', () {
      indent.writeln('std::optional<FlutterError> output;');
      indent.writeScoped(
        'session->CancelStream(sink_id, [&](const std::string& instance_name) {',
        '});',
        () {
          indent.writeln('output = $handlerVariable->OnCancel(instance_name);');
        },
      );
      indent.writeScoped('if (output.has_value()) {', '}', () {
        indent.writeln('return PigeonFfiEncodeFlutterError(codec, output.value());');
      });
      _writeNullSuccess(indent);
    }, addTrailingNewline: false);
    indent.add(' catch (const std::exception& exception) ');
    indent.addScoped('{', '}', () {
      indent.writeln('return PigeonFfiEncodeErrorMessage(codec, exception.what());');
    });
  });
  indent.writeln('}');
  indent.newln();
}

void _writeMethodSource(Indent indent, AstHostApi api, Method method) {
  indent.writeln(
    'PigeonFfiBuffer* ${_ffiHelperName(api, method)}(std::shared_ptr<PigeonFfiSession<${api.name}>> session, PigeonFfiBuffer* request) {',
  );
  indent.nest(1, () {
    indent.writeln('const auto& codec = ${api.name}::GetCodec();');
    _writeSessionLeases(indent);
    indent.writeScoped('try {', '}', () {
      final methodArguments = <String>[];
      if (method.parameters.isNotEmpty) {
        indent.writeScoped('if (request == nullptr || request->data == nullptr) {', '}', () {
          indent.writeln(
            'return PigeonFfiEncodeError(codec, ${api.name}::WrapError("Request buffer is null."));',
          );
        });
        indent.writeln(
          'std::unique_ptr<::flutter::EncodableValue> message = codec.DecodeMessage(request->data, request->length);',
        );
        indent.writeScoped('if (!message) {', '}', () {
          indent.writeln(
            'return PigeonFfiEncodeError(codec, ${api.name}::WrapError("Unable to decode request."));',
          );
        });
        indent.writeln('const auto* args = std::get_if<::flutter::EncodableList>(message.get());');
        indent.writeScoped(
          'if (args == nullptr || args->size() != ${method.parameters.length}) {',
          '}',
          () {
            indent.writeln(
              'return PigeonFfiEncodeError(codec, ${api.name}::WrapError("Unexpected request arguments."));',
            );
          },
        );
        for (var index = 0; index < method.parameters.length; index++) {
          final Parameter parameter = method.parameters[index];
          final HostDatatype hostType = getHostDatatype(
            parameter.type,
            _baseCppTypeForBuiltinDartType,
          );
          final String argName = _safeArgumentName(index, parameter);
          final encodableArgName = 'encodable_$argName';
          indent.writeln('const auto& $encodableArgName = args->at($index);');
          if (!parameter.type.isNullable) {
            indent.writeScoped('if ($encodableArgName.IsNull()) {', '}', () {
              indent.writeln(
                'return PigeonFfiEncodeError(codec, ${api.name}::WrapError("$argName unexpectedly null."));',
              );
            });
          }
          _writeEncodableValueArgumentUnwrapping(
            indent,
            hostType,
            argName: argName,
            encodableArgName: encodableArgName,
          );
          methodArguments.add(argName);
        }
      }

      final HostDatatype returnType = getHostDatatype(
        method.returnType,
        _baseCppTypeForBuiltinDartType,
      );
      final String returnTypeName = _hostApiReturnType(returnType);
      final call =
          'session->registration->api->${_methodName(method)}(${methodArguments.join(', ')})';
      indent.writeln('$returnTypeName output = $call;');
      _writeReturnEncoding(indent, method.returnType, returnType, api.name);
    }, addTrailingNewline: false);
    indent.add(' catch (const std::exception& exception) ');
    indent.addScoped('{', '}', () {
      indent.writeln(
        'return PigeonFfiEncodeError(codec, ${api.name}::WrapError(exception.what()));',
      );
    });
  });
  indent.writeln('}');
  indent.newln();
}

void _writeAsyncMethodSource(Indent indent, AstHostApi api, Method method) {
  indent.writeln('void ${_ffiHelperName(api, method)}(');
  indent.nest(1, () {
    indent.writeln('std::shared_ptr<PigeonFfiSession<${api.name}>> session,');
    indent.writeln('PigeonFfiBuffer* request,');
    indent.writeln('std::shared_ptr<PigeonFfiReplyState> reply_state) {');
  });
  indent.nest(1, () {
    indent.writeln('const auto& codec = ${api.name}::GetCodec();');
    _writeSessionLeases(indent, asynchronous: true);
    indent.writeScoped('try {', '}', () {
      final methodArguments = <String>[];
      if (method.parameters.isNotEmpty) {
        indent.writeScoped('if (request == nullptr || request->data == nullptr) {', '}', () {
          indent.writeln(
            'reply_state->Send(PigeonFfiEncodeError(codec, ${api.name}::WrapError("Request buffer is null.")));',
          );
          indent.writeln('return;');
        });
        indent.writeln(
          'std::unique_ptr<::flutter::EncodableValue> message = codec.DecodeMessage(request->data, request->length);',
        );
        indent.writeScoped('if (!message) {', '}', () {
          indent.writeln(
            'reply_state->Send(PigeonFfiEncodeError(codec, ${api.name}::WrapError("Unable to decode request.")));',
          );
          indent.writeln('return;');
        });
        indent.writeln('const auto* args = std::get_if<::flutter::EncodableList>(message.get());');
        indent.writeScoped(
          'if (args == nullptr || args->size() != ${method.parameters.length}) {',
          '}',
          () {
            indent.writeln(
              'reply_state->Send(PigeonFfiEncodeError(codec, ${api.name}::WrapError("Unexpected request arguments.")));',
            );
            indent.writeln('return;');
          },
        );
        for (var index = 0; index < method.parameters.length; index++) {
          final Parameter parameter = method.parameters[index];
          final HostDatatype hostType = getHostDatatype(
            parameter.type,
            _baseCppTypeForBuiltinDartType,
          );
          final String argName = _safeArgumentName(index, parameter);
          final encodableArgName = 'encodable_$argName';
          indent.writeln('const auto& $encodableArgName = args->at($index);');
          if (!parameter.type.isNullable) {
            indent.writeScoped('if ($encodableArgName.IsNull()) {', '}', () {
              indent.writeln(
                'reply_state->Send(PigeonFfiEncodeError(codec, ${api.name}::WrapError("$argName unexpectedly null.")));',
              );
              indent.writeln('return;');
            });
          }
          _writeEncodableValueArgumentUnwrapping(
            indent,
            hostType,
            argName: argName,
            encodableArgName: encodableArgName,
          );
          methodArguments.add(argName);
        }
      }

      final HostDatatype returnType = getHostDatatype(
        method.returnType,
        _baseCppTypeForBuiltinDartType,
      );
      final String returnTypeName = _hostApiReturnType(returnType);
      indent.writeln('session->registration->api->${_methodName(method)}(');
      indent.nest(1, () {
        for (final argument in methodArguments) {
          indent.writeln('$argument,');
        }
        indent.writeln('[reply_state]($returnTypeName&& output) {');
        indent.nest(1, () {
          indent.writeln('const auto& codec = ${api.name}::GetCodec();');
          _writeAsyncReplyEncoding(indent, method.returnType, returnType, api.name);
        });
        indent.writeln('});');
      });
    }, addTrailingNewline: false);
    indent.add(' catch (const std::exception& exception) ');
    indent.addScoped('{', '}', () {
      indent.writeln(
        'reply_state->Send(PigeonFfiEncodeError(codec, ${api.name}::WrapError(exception.what())));',
      );
    });
  });
  indent.writeln('}');
  indent.newln();
}

void _writeReturnEncoding(
  Indent indent,
  TypeDeclaration dartReturnType,
  HostDatatype hostReturnType,
  String apiName,
) {
  if (dartReturnType.isVoid) {
    indent.writeScoped('if (output.has_value()) {', '}', () {
      indent.writeln('return PigeonFfiEncodeError(codec, $apiName::WrapError(output.value()));');
    });
    _writeNullSuccess(indent);
    return;
  }

  indent.writeScoped('if (output.has_error()) {', '}', () {
    indent.writeln('return PigeonFfiEncodeError(codec, $apiName::WrapError(output.error()));');
  });
  final wrapperType = hostReturnType.isBuiltin
      ? '::flutter::EncodableValue'
      : '::flutter::CustomEncodableValue';
  if (dartReturnType.isNullable) {
    indent.writeScoped('if (output.value()) {', '} else {', () {
      final encodedValue = '$wrapperType(output.value().value())';
      indent.writeln(
        'return PigeonFfiEncodeMessage(codec, '
        '::flutter::EncodableValue(::flutter::EncodableList{$encodedValue}));',
      );
    });
    indent.addScoped(null, '}', () {
      _writeNullSuccess(indent);
    });
    return;
  }
  indent.writeln(
    'return PigeonFfiEncodeMessage(codec, '
    '::flutter::EncodableValue(::flutter::EncodableList{'
    '$wrapperType(output.value())}));',
  );
}

void _writeAsyncReplyEncoding(
  Indent indent,
  TypeDeclaration dartReturnType,
  HostDatatype hostReturnType,
  String apiName,
) {
  if (dartReturnType.isVoid) {
    indent.writeScoped('if (output.has_value()) {', '}', () {
      indent.writeln(
        'reply_state->Send(PigeonFfiEncodeError(codec, $apiName::WrapError(output.value())));',
      );
      indent.writeln('return;');
    });
    indent.writeln(
      'reply_state->Send(PigeonFfiEncodeMessage(codec, ::flutter::EncodableValue(::flutter::EncodableList{::flutter::EncodableValue()})));',
    );
    return;
  }

  indent.writeScoped('if (output.has_error()) {', '}', () {
    indent.writeln(
      'reply_state->Send(PigeonFfiEncodeError(codec, $apiName::WrapError(output.error())));',
    );
    indent.writeln('return;');
  });
  final wrapperType = hostReturnType.isBuiltin
      ? '::flutter::EncodableValue'
      : '::flutter::CustomEncodableValue';
  if (dartReturnType.isNullable) {
    indent.writeScoped('if (output.value()) {', '} else {', () {
      final encodedValue = '$wrapperType(output.value().value())';
      indent.writeln(
        'reply_state->Send(PigeonFfiEncodeMessage(codec, '
        '::flutter::EncodableValue(::flutter::EncodableList{$encodedValue})));',
      );
    });
    indent.addScoped(null, '}', () {
      indent.writeln(
        'reply_state->Send(PigeonFfiEncodeMessage(codec, ::flutter::EncodableValue(::flutter::EncodableList{::flutter::EncodableValue()})));',
      );
    });
    return;
  }
  indent.writeln(
    'reply_state->Send(PigeonFfiEncodeMessage(codec, '
    '::flutter::EncodableValue(::flutter::EncodableList{'
    '$wrapperType(output.value())})));',
  );
}

void _writeNullSuccess(Indent indent) {
  indent.writeln(
    'return PigeonFfiEncodeMessage(codec, '
    '::flutter::EncodableValue(::flutter::EncodableList{::flutter::EncodableValue()}));',
  );
}

void _writeEncodableValueArgumentUnwrapping(
  Indent indent,
  HostDatatype hostType, {
  required String argName,
  required String encodableArgName,
}) {
  if (hostType.isNullable) {
    if (hostType.datatype == 'int64_t') {
      indent.format('''
const int64_t ${argName}_value = $encodableArgName.IsNull() ? 0 : $encodableArgName.LongValue();
const int64_t* $argName = $encodableArgName.IsNull() ? nullptr : &${argName}_value;
''');
    } else if (hostType.datatype == '::flutter::EncodableValue') {
      indent.writeln('const auto* $argName = &$encodableArgName;');
    } else if (hostType.isBuiltin) {
      indent.writeln(
        'const auto* $argName = std::get_if<${hostType.datatype}>(&$encodableArgName);',
      );
    } else if (hostType.isEnum) {
      indent.format('''
${hostType.datatype} ${argName}_value;
const ${hostType.datatype}* $argName = nullptr;
if (!$encodableArgName.IsNull()) {
  ${argName}_value = std::any_cast<const ${hostType.datatype}&>(std::get<::flutter::CustomEncodableValue>($encodableArgName));
  $argName = &${argName}_value;
}''');
    } else {
      final encodableValue = 'std::get<::flutter::CustomEncodableValue>($encodableArgName)';
      final castExpression = 'std::any_cast<const ${hostType.datatype}&>($encodableValue)';
      indent.writeln(
        'const auto* $argName = $encodableArgName.IsNull() ? nullptr : &($castExpression);',
      );
    }
    return;
  }

  if (hostType.datatype == 'int64_t') {
    indent.writeln('const int64_t $argName = $encodableArgName.LongValue();');
  } else if (hostType.datatype == '::flutter::EncodableValue') {
    indent.writeln('const auto& $argName = $encodableArgName;');
  } else if (hostType.isBuiltin) {
    indent.writeln('const auto& $argName = std::get<${hostType.datatype}>($encodableArgName);');
  } else {
    final encodableValue = 'std::get<::flutter::CustomEncodableValue>($encodableArgName)';
    final castExpression = 'std::any_cast<const ${hostType.datatype}&>($encodableValue)';
    indent.writeln('const auto& $argName = $castExpression;');
  }
}

/// Validates whether the C++ FFI generator can support [root].
List<Error> validateCppFfi(InternalCppFfiOptions options, Root root) {
  final errors = <Error>[];
  if (options.apiHeaderIncludePath.isEmpty) {
    errors.add(
      Error(
        message:
            'C++ FFI requires cppHeaderOut or cppFfiOptions.apiHeaderIncludePath '
            'so the adapter can include the generated C++ API header',
      ),
    );
  }
  for (final Api api in root.apis) {
    switch (api) {
      case AstHostApi():
        break;
      case AstFlutterApi():
        errors.add(Error(message: 'C++ FFI does not support FlutterApi "${api.name}"'));
      case AstEventChannelApi():
        for (final Method method in api.methods) {
          if (method.returnType.isVoid) {
            errors.add(
              Error(
                message: 'C++ FFI does not support void EventChannelApi method "${method.name}"',
              ),
            );
          }
        }
      case AstProxyApi():
        errors.add(Error(message: 'C++ FFI does not support ProxyApi "${api.name}"'));
    }
  }
  return errors;
}

String _getGuardName(String symbolPrefix) => '${symbolPrefix.toUpperCase()}HEADER_';

String? _baseCppTypeForBuiltinDartType(TypeDeclaration type) {
  const cppTypeForDartTypeMap = <String, String>{
    'void': 'void',
    'bool': 'bool',
    'int': 'int64_t',
    'String': 'std::string',
    'double': 'double',
    'Uint8List': 'std::vector<uint8_t>',
    'Int32List': 'std::vector<int32_t>',
    'Int64List': 'std::vector<int64_t>',
    'Float64List': 'std::vector<double>',
    'Map': '::flutter::EncodableMap',
    'List': '::flutter::EncodableList',
    'Object': '::flutter::EncodableValue',
  };
  return cppTypeForDartTypeMap[type.baseName];
}

String _hostApiReturnType(HostDatatype type) {
  if (type.datatype == 'void') {
    return 'std::optional<FlutterError>';
  }
  String valueType = type.datatype;
  if (type.isNullable) {
    valueType = 'std::optional<$valueType>';
  }
  return 'ErrorOr<$valueType>';
}

String _methodName(Method method) => method.name[0].toUpperCase() + method.name.substring(1);

String _safeArgumentName(int count, NamedType argument) {
  final String name = argument.name.isEmpty ? 'arg$count' : _makeVariableName(argument.name);
  return '${name}_arg';
}

String _makeVariableName(String name) {
  return name.replaceAllMapped(RegExp(r'[A-Z]'), (Match match) => '_${match[0]!.toLowerCase()}');
}

String _ffiFunctionName(AstHostApi api, Method method, String symbolPrefix) {
  return '$symbolPrefix${makeCppFfiMemberName('host', api.name, method.name)}';
}

String _ffiHelperName(AstHostApi api, Method method) {
  return 'Pigeon_${makeCppFfiMemberName('host', api.name, method.name)}';
}

String _registryName(String name) => 'g_${makeCppFfiMemberName('registry', name)}';

String _hostSessionName(AstHostApi api) => makeCppFfiMemberName('session', api.name);

String _eventSessionName(AstEventChannelApi api, Method method) =>
    makeCppFfiMemberName('event_session', api.name, method.name);

String _eventListenFunctionName(AstEventChannelApi api, Method method, String symbolPrefix) {
  return '$symbolPrefix${makeCppFfiMemberName('event', api.name, method.name)}_listen';
}

String _eventCancelFunctionName(AstEventChannelApi api, Method method, String symbolPrefix) {
  return '$symbolPrefix${makeCppFfiMemberName('event', api.name, method.name)}_cancel';
}

String _eventSinkName(AstEventChannelApi api, Method method) {
  return 'Pigeon${api.name}${_methodName(method)}EventSink';
}

String _eventSinkImplName(AstEventChannelApi api, Method method) {
  return '${_eventSinkName(api, method)}Impl';
}

String _eventStreamHandlerName(AstEventChannelApi api, Method method) {
  return 'Pigeon${api.name}${_methodName(method)}StreamHandler';
}

String _eventListenHelperName(AstEventChannelApi api, Method method) {
  return 'Pigeon${api.name}${_methodName(method)}ListenFfi';
}

String _eventCancelHelperName(AstEventChannelApi api, Method method) {
  return 'Pigeon${api.name}${_methodName(method)}CancelFfi';
}

String _eventSinkParameterType(HostDatatype type) {
  if (type.isNullable) {
    return 'const ${type.datatype}* event';
  }
  return 'const ${type.datatype}& event';
}

String _eventEncodableValueExpression(HostDatatype type, String value) {
  final wrapperType = type.isBuiltin
      ? '::flutter::EncodableValue'
      : '::flutter::CustomEncodableValue';
  return '$wrapperType($value)';
}
