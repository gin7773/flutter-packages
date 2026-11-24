// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:path/path.dart' as path;

import '../ast.dart';
import '../generator_tools.dart';
import 'cpp_ffi_runtime.dart';
import 'cpp_generator.dart';

/// C ABI symbol prefix, independent of the checkout's absolute location.
String cppFfiPrefix(String package, String header, {String? namespace}) {
  String escape(String value) => value.runes
      .map(
        (int c) => (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
            ? String.fromCharCode(c)
            : '_x${c.toRadixString(16)}_',
      )
      .join();
  return 'pigeon_${escape(package)}_${namespace == null ? '' : '${escape(namespace)}_'}${escape(path.posix.basename(header.replaceAll(r'\', '/')))}_';
}

/// Unambiguous member name, including API and method boundaries.
String cppFfiMember(String api, [String? method]) =>
    '${api.length}_$api${method == null ? '' : '_${method.length}_$method'}';

/// Path of the C ABI header generated alongside the normal C++ header.
String cppFfiHeader(String header) => '${path.withoutExtension(header)}.ffi.h';

/// Path of the adapter generated alongside the normal C++ source.
String cppFfiSource(String source) => '${path.withoutExtension(source)}.ffi.cpp';

/// Path of the ffigen configuration generated alongside the C ABI header.
String cppFfiConfig(String header) => '${path.withoutExtension(header)}.ffigen.yaml';

/// Path of the C bindings, separate from Swift's .ffi.dart bindings.
String cppFfiDart(String dartOut) => '${path.withoutExtension(dartOut)}.cpp_ffi.dart';

/// Writes a C ABI adapter using the shared native interop type classification.
void generateCppFfi(
  InternalCppOptions options,
  Root root,
  StringSink sink, {
  required String package,
  required FileType fileType,
}) {
  final out = Indent();
  final String prefix = cppFfiPrefix(package, options.cppHeaderOut, namespace: options.namespace);
  if (options.copyrightHeader != null) {
    addLines(out, options.copyrightHeader!, linePrefix: '// ');
  }
  out.writeln('// ${getGeneratedCodeWarning()}');
  if (fileType == FileType.header) {
    _header(options, root, out, prefix);
  } else {
    _source(options, root, out, prefix);
  }
  sink.write(out.toString());
}

void _header(InternalCppOptions options, Root root, Indent out, String prefix) {
  final guard = '${prefix.toUpperCase()}FFI_H_';
  out.format('''
#ifndef $guard
#define $guard
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32)
#define PIGEON_CPP_EXPORT __declspec(dllexport)
#else
#define PIGEON_CPP_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
#include "${path.basename(options.cppHeaderOut)}"
extern "C" {
#endif
#ifndef PIGEON_CPP_FFI_ABI_V1_
#define PIGEON_CPP_FFI_ABI_V1_
// data is owned by the caller for arguments and by the adapter for results.
// length is in bytes, including for typed arrays. Null is independent of length.
typedef struct PigeonCppValue {
  int64_t integer;
  double real;
  uint8_t* data;
  size_t length;
  int32_t is_null;
  int32_t is_error;
} PigeonCppValue;
typedef void (*PigeonCppReply)(int64_t reply_id, PigeonCppValue* result);
#endif
PIGEON_CPP_EXPORT void ${prefix}free_value(PigeonCppValue* value);
''');
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    final String member = cppFfiMember(api.name);
    out.writeln(
      'PIGEON_CPP_EXPORT PigeonCppValue* $prefix${member}_connect(const uint8_t* name, size_t length);',
    );
    out.writeln('PIGEON_CPP_EXPORT PigeonCppValue* $prefix${member}_disconnect(int64_t session);');
    for (final Method method in api.methods) {
      out.writeln(
        'PIGEON_CPP_EXPORT ${method.isAsynchronous ? 'void' : 'PigeonCppValue*'} $prefix${cppFfiMember(api.name, method.name)}(int64_t session, const PigeonCppValue* args${method.isAsynchronous ? ', int64_t reply_id, PigeonCppReply callback' : ''});',
      );
    }
  }
  out.format('''
#ifdef __cplusplus
}
${options.namespace == null ? '' : 'namespace ${options.namespace} {'}
// Calls execute on the calling thread. Implementations own asynchronous dispatch.
// Each engine must use a unique name unless sharing a thread-safe implementation.
// The API is borrowed: unregister, stop/join its async work, then destroy it.
''');
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    out.writeln(
      'int64_t Register${api.name}Ffi(${api.name}* api, const std::string& name = "$defaultNativeInteropInstanceName");',
    );
    out.writeln('void Unregister${api.name}Ffi(int64_t registration_id);');
  }
  out.format('''
${options.namespace == null ? '' : '}  // namespace ${options.namespace}'}
#endif
#endif  // $guard
''');
}

void _source(InternalCppOptions options, Root root, Indent out, String prefix) {
  out.format('''
#include "${path.relative(cppFfiHeader(options.cppHeaderOut), from: path.dirname(options.cppSourceOut)).replaceAll(r'\', '/')}"
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <map>
#include <mutex>
#include <stdexcept>
#include <utility>
namespace {
''');
  out.format(cppFfiRuntime);
  out.writeln('}  // namespace');
  out.writeln(
    'extern "C" void ${prefix}free_value(PigeonCppValue* value) { PigeonDestroyValue(value); }',
  );
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    final type = '${options.namespace == null ? '' : '${options.namespace}::'}${api.name}';
    final String member = cppFfiMember(api.name);
    final registry = 'pigeon_registry_$member';
    out.writeln('namespace { PigeonRegistry<$type> $registry; }');
    final scope = options.namespace == null ? '' : '${options.namespace}::';
    out.writeln(
      'int64_t ${scope}Register${api.name}Ffi($type* api, const std::string& name) { return $registry.Register(api, name); }',
    );
    out.writeln('void ${scope}Unregister${api.name}Ffi(int64_t id) { $registry.Unregister(id); }');
    for (final connect in <bool>[true, false]) {
      out.format('''
extern "C" PigeonCppValue* $prefix${member}_${connect ? 'connect(const uint8_t* name, size_t length)' : 'disconnect(int64_t session)'} {
  const auto& codec = $type::GetCodec();
  try {
    auto result = std::make_unique<PigeonCppValue>();
    ${connect ? 'if (!name && length) throw std::invalid_argument("Null FFI name.");\nresult->integer = $registry.Connect(length ? std::string(reinterpret_cast<const char*>(name), length) : std::string());' : '$registry.Disconnect(session);'}
    return result.release();
  } catch (const std::exception& error) { return PigeonException(codec, error.what()); }
    catch (...) { return PigeonException(codec, "Unknown native exception."); }
}
''');
    }
    for (final Method method in api.methods) {
      _method(out, api, method, type, registry, prefix, options.namespace);
    }
  }
}

void _method(
  Indent out,
  AstHostApi api,
  Method method,
  String type,
  String registry,
  String prefix,
  String? namespace,
) {
  final bool async = method.isAsynchronous;
  final codec = '$type::GetCodec()';
  final symbol = '$prefix${cppFfiMember(api.name, method.name)}';
  out.writeln(
    'extern "C" ${async ? 'void' : 'PigeonCppValue*'} $symbol(int64_t session_id, const PigeonCppValue* args${async ? ', int64_t reply_id, PigeonCppReply callback' : ''}) {',
  );
  out.writeln('const auto& codec = $codec;');
  if (async) {
    out.writeln('if (!callback) return;');
    out.writeln('std::shared_ptr<PigeonReply> reply;');
  }
  out.writeln('try {');
  out.format('''
auto session = $registry.Get(session_id);
PigeonLease registration_lease(session ? session->registration->gate : nullptr);
PigeonLease session_lease(session ? session->gate : nullptr);
if (!registration_lease || !session_lease) throw std::runtime_error("FFI session has been disconnected.");
''');
  if (async) {
    out.format('''
reply = std::make_shared<PigeonReply>();
reply->id = reply_id;
reply->callback = callback;
reply->session_gate = session->gate;
reply->codec = &codec;
session->Track(reply);
''');
  }
  if (method.parameters.isNotEmpty) {
    out.writeln('if (!args) throw std::invalid_argument("Null FFI arguments.");');
  }
  final List<Parameter> encoded = nativeInteropEncodedParameters(method.parameters);
  final List<Parameter> direct = method.parameters
      .where((Parameter p) => isNativeInteropDirectType(p.type))
      .toList();
  if (encoded.isNotEmpty) {
    out.format('''
const auto& buffer = args[${direct.length}];
if (!buffer.data || !buffer.length) throw std::invalid_argument("Empty FFI argument buffer.");
auto message = codec.DecodeMessage(buffer.data, buffer.length);
const auto* values = message ? std::get_if<flutter::EncodableList>(message.get()) : nullptr;
if (!values || values->size() != ${encoded.length}) throw std::invalid_argument("Invalid FFI argument buffer.");
''');
  }
  final arguments = <String>[];
  for (var i = 0; i < method.parameters.length; i++) {
    final Parameter parameter = method.parameters[i];
    final TypeDeclaration t = parameter.type;
    final name = 'arg$i';
    final String cppType = _cppType(t, namespace);
    if (isNativeInteropDirectType(t)) {
      final field = 'args[${direct.indexOf(parameter)}]';
      if (!t.isNullable) {
        out.writeln(
          'if ($field.is_null) throw std::invalid_argument("Unexpected null argument.");',
        );
      }
      out.writeln('$cppType ${name}_value{};');
      out.writeln('if (!$field.is_null) {');
      if (t.isEnum || t.baseName == 'int' || t.baseName == 'bool') {
        if (t.isEnum) {
          out.writeln(
            'if ($field.integer < 0 || $field.integer >= ${t.associatedEnum!.members.length}) throw std::invalid_argument("Invalid enum index.");',
          );
        }
        out.writeln('${name}_value = static_cast<$cppType>($field.integer);');
      } else if (t.baseName == 'double') {
        out.writeln('${name}_value = $field.real;');
      } else {
        final String element = _elementType(t);
        out.writeln(
          'if ($field.length && !$field.data) throw std::invalid_argument("Null FFI data.");',
        );
        if (t.baseName == 'String') {
          out.writeln(
            'if ($field.length) ${name}_value.assign(reinterpret_cast<const char*>($field.data), $field.length);',
          );
        } else {
          out.writeln(
            'if ($field.length % sizeof($element)) throw std::invalid_argument("Invalid typed data length.");',
          );
          out.writeln('${name}_value.resize($field.length / sizeof($element));');
          out.writeln(
            'if ($field.length) std::memcpy(${name}_value.data(), $field.data, $field.length);',
          );
        }
      }
      out.writeln('}');
      arguments.add(t.isNullable ? '($field.is_null ? nullptr : &${name}_value)' : '${name}_value');
    } else {
      out.writeln('const auto& $name = values->at(${encoded.indexOf(parameter)});');
      if (!t.isNullable) {
        out.writeln(
          'if ($name.IsNull()) throw std::invalid_argument("Unexpected null argument.");',
        );
      }
      final value = t.baseName == 'Object'
          ? name
          : t.isClass
          ? 'std::any_cast<const $cppType&>(std::get<flutter::CustomEncodableValue>($name))'
          : 'std::get<$cppType>($name)';
      arguments.add(
        t.isNullable && t.baseName != 'Object'
            ? '($name.IsNull() ? nullptr : &($value))'
            : t.isNullable
            ? '&$name'
            : value,
      );
    }
  }
  final call =
      'session->registration->api->${method.name[0].toUpperCase()}${method.name.substring(1)}';
  if (async) {
    out.writeln(
      '$call(${arguments.isEmpty ? '' : '${arguments.join(', ')}, '}[reply](auto output) {',
    );
    out.writeln('auto encode = [&]() -> PigeonCppValue* {');
    out.writeln('const auto& codec = $codec;');
    out.writeln('try {');
    _return(out, method.returnType, type);
    out.writeln(
      '} catch (const std::exception& error) { return PigeonException(codec, error.what()); }',
    );
    out.writeln('catch (...) { return PigeonException(codec, "Unknown native exception."); }');
    out.writeln('}; reply->Send(encode()); });');
  } else {
    out.writeln('auto output = $call(${arguments.join(', ')});');
    _return(out, method.returnType, type);
  }
  out.writeln('} catch (const std::exception& error) {');
  out.writeln(
    async
        ? 'auto* value = PigeonException(codec, error.what()); if (reply) reply->Send(value); else callback(reply_id, value);'
        : 'return PigeonException(codec, error.what());',
  );
  out.writeln('} catch (...) {');
  out.writeln(
    async
        ? 'auto* value = PigeonException(codec, "Unknown native exception."); if (reply) reply->Send(value); else callback(reply_id, value);'
        : 'return PigeonException(codec, "Unknown native exception.");',
  );
  out.writeln('}\n}');
}

void _return(Indent out, TypeDeclaration t, String api) {
  out.writeln(
    'if (${t.isVoid ? 'output.has_value()' : 'output.has_error()'}) return PigeonError(codec, $api::WrapError(${t.isVoid ? 'output.value()' : 'output.error()'}));',
  );
  if (t.isVoid) {
    out.writeln('return new PigeonCppValue{};');
    return;
  }
  if (t.isNullable) {
    out.writeln(
      'if (!output.value()) { auto* value = new PigeonCppValue{}; value->is_null = 1; return value; }',
    );
  }
  final value = t.isNullable ? 'output.value().value()' : 'output.value()';
  if (!isNativeInteropDirectType(t)) {
    out.writeln(
      'return PigeonEncode(codec, ${t.isClass ? 'flutter::CustomEncodableValue' : 'flutter::EncodableValue'}($value));',
    );
  } else if (t.isEnum || t.baseName == 'int' || t.baseName == 'bool' || t.baseName == 'double') {
    out.writeln('auto* value = new PigeonCppValue{};');
    out.writeln(
      'value->${t.baseName == 'double' ? 'real = $value' : 'integer = static_cast<int64_t>($value)'};',
    );
    out.writeln('return value;');
  } else {
    out.writeln(
      'return PigeonBytes(reinterpret_cast<const uint8_t*>($value.data()), $value.size() * sizeof(${_elementType(t)}));',
    );
  }
}

String _elementType(TypeDeclaration t) => switch (t.baseName) {
  'Int32List' => 'int32_t',
  'Int64List' => 'int64_t',
  'Float64List' => 'double',
  _ => 'uint8_t',
};

String _cppType(TypeDeclaration t, String? namespace) => switch (t.baseName) {
  'bool' => 'bool',
  'int' => 'int64_t',
  'double' => 'double',
  'String' => 'std::string',
  'Uint8List' || 'Int32List' || 'Int64List' || 'Float64List' => 'std::vector<${_elementType(t)}>',
  'List' => 'flutter::EncodableList',
  'Map' => 'flutter::EncodableMap',
  'Object' => 'flutter::EncodableValue',
  _ => '${namespace == null ? '' : '$namespace::'}${t.baseName}',
};

/// Writes the configuration used by Pigeon's automatic FFIgen invocation.
void generateCppFfiConfig(
  InternalCppOptions options,
  String dartOut,
  StringSink sink, {
  required String package,
}) {
  final String config = cppFfiConfig(options.cppHeaderOut);
  String relative(String target) =>
      path.relative(target, from: path.dirname(config)).replaceAll(r'\', '/');
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  final String prefix = cppFfiPrefix(package, options.cppHeaderOut, namespace: options.namespace);
  sink.write('''
# ${getGeneratedCodeWarning()}
name: PigeonCppBindings
description: C bindings for generated Pigeon C++ native interop.
output: ${quote(relative(cppFfiDart(dartOut)))}
headers:
  entry-points:
    - ${quote(relative(cppFfiHeader(options.cppHeaderOut)))}
  include-directives:
    - ${quote('**/${path.basename(cppFfiHeader(options.cppHeaderOut))}')}
functions:
  include:
    - '$prefix.*'
  rename:
    '$prefix(.*)': 'pigeon_\$1'
structs:
  include:
    - PigeonCppValue
macros:
  exclude:
    - '.*'
typedefs:
  include:
    - PigeonCppReply
''');
}
