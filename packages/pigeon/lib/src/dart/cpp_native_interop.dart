// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../ast.dart';
import '../cpp/cpp_ffi_generator.dart';
import '../generator_tools.dart';
import 'dart_generator.dart' show addGenericTypes;

/// Writes the C++ implementation of the existing native interop interface.
void writeCppNativeInterop(
  Indent out,
  Root root,
  String library, {
  required String Function(String, TypeDeclaration) castValue,
  required String Function(List<Parameter>) parameterSignature,
}) {
  out.writeln(
    "final cpp_bindings.PigeonCppBindings _cppBindings = cpp_bindings.PigeonCppBindings(cpp_ffi.DynamicLibrary.open('${escapeStringSingleQuotes(library)}'));",
  );
  out.format(_runtime);
  for (final AstHostApi api in root.apis.whereType<AstHostApi>()) {
    final String member = cppFfiMember(api.name);
    out.format('''
class _${api.name}ForCppNativeInterop implements ${api.name}ForNativeInterop {
  _${api.name}ForCppNativeInterop(String name) : _session = _CppSession.connect(
    name, ${api.name}.pigeonChannelCodec,
    _cppBindings.pigeon_${member}_connect, _cppBindings.pigeon_${member}_disconnect);
  final _CppSession _session;
  @override
  void pigeonDispose() => _session.dispose();
''');
    for (final Method method in api.methods) {
      final TypeDeclaration t = method.returnType;
      final String signature = parameterSignature(method.parameters);
      final String type = addGenericTypes(t);
      final bool async = method.isAsynchronous;
      out.writeln('@override');
      out.writeln(
        '${async ? 'Future<$type>' : type} ${method.name}($signature) ${async ? 'async ' : ''}{',
      );
      out.writeln('_session.checkOpen();');
      final List<Parameter> encoded = nativeInteropEncodedParameters(method.parameters);
      final List<Parameter> direct = method.parameters
          .where((Parameter p) => isNativeInteropDirectType(p.type))
          .toList();
      out.writeln(
        '${t.isVoid ? '' : 'final Object? pigeonVar_result = '}${async ? 'await ' : ''}cpp_alloc.using((cpp_alloc.Arena pigeonVar_arena) {',
      );
      final int slots = direct.length + (encoded.isEmpty ? 0 : 1);
      out.writeln(
        'final cpp_ffi.Pointer<cpp_bindings.PigeonCppValue> pigeonVar_args = pigeonVar_arena<cpp_bindings.PigeonCppValue>(${slots <= 1 ? '' : slots});',
      );
      for (var i = 0; i < direct.length; i++) {
        final Parameter p = direct[i];
        out.writeln(
          '_cppWrite(pigeonVar_args[$i], ${p.name}${p.type.isEnum ? '${p.type.isNullable ? '?' : ''}.index' : ''}, ${_kind(p.type)}, pigeonVar_arena);',
        );
      }
      if (encoded.isNotEmpty) {
        out.writeln(
          'final ByteData pigeonVar_bytes = _session.codec.encodeMessage(<Object?>[${encoded.map((Parameter p) => p.name).join(', ')}])!;',
        );
        out.writeln(
          '_cppWrite(pigeonVar_args[${direct.length}], pigeonVar_bytes.buffer.asUint8List(pigeonVar_bytes.offsetInBytes, pigeonVar_bytes.lengthInBytes), 5, pigeonVar_arena);',
        );
      }
      final call = '_cppBindings.pigeon_${cppFfiMember(api.name, method.name)}';
      if (async) {
        out.writeln(
          'return _session.invokeAsync((pigeonVar_id) => $call(_session.id, pigeonVar_args, pigeonVar_id, _cppReply.nativeFunction), ${_kind(t)});',
        );
      } else {
        out.writeln(
          'return _cppDecode($call(_session.id, pigeonVar_args), _session.codec, ${_kind(t)});',
        );
      }
      out.writeln('});');
      if (!t.isVoid) {
        final String value = t.isEnum
            ? '${t.isNullable ? 'pigeonVar_result == null ? null : ' : ''}${t.baseName}.values[pigeonVar_result${t.isNullable ? '' : '!'} as int]'
            : castValue('pigeonVar_result', t);
        out.writeln('return $value;');
      }
      out.writeln('}');
    }
    out.writeln('}');
  }
}

int _kind(TypeDeclaration t) => t.isEnum
    ? 2
    : switch (t.baseName) {
        'bool' => 1,
        'int' => 2,
        'double' => 3,
        'String' => 4,
        'Uint8List' => 5,
        'Int32List' => 6,
        'Int64List' => 7,
        'Float64List' => 8,
        'void' => 9,
        _ => 0,
      };

const String _runtime = r'''
typedef _CppValue = cpp_ffi.Pointer<cpp_bindings.PigeonCppValue>;
typedef _CppReplyNative = cpp_ffi.Void Function(cpp_ffi.Int64, _CppValue);

void _cppWrite(cpp_bindings.PigeonCppValue target, Object? value, int kind, cpp_alloc.Arena arena) {
  if (value == null) { target.is_null = 1; return; }
  switch (kind) {
    case 1: target.integer = (value as bool) ? 1 : 0;
    case 2: target.integer = value as int;
    case 3: target.real = value as double;
    default:
      final Uint8List bytes;
      if (kind == 4) {
        bytes = Uint8List.fromList(cpp_convert.utf8.encode(value as String));
      } else {
        final TypedData typed = value as TypedData;
        bytes = typed.buffer.asUint8List(typed.offsetInBytes, typed.lengthInBytes);
      }
      target.length = bytes.length;
      if (bytes.isNotEmpty) {
        target.data = arena<cpp_ffi.Uint8>(bytes.length);
        target.data.asTypedList(bytes.length).setAll(0, bytes);
      }
  }
}

Object? _cppDecode(_CppValue pointer, MessageCodec<Object?> codec, int kind) {
  if (pointer == cpp_ffi.nullptr) {
    throw PlatformException(code: 'native-allocation-error', message: 'Unable to allocate an FFI result.');
  }
  try {
    final cpp_bindings.PigeonCppValue value = pointer.ref;
    Uint8List bytes() => value.length == 0 ? Uint8List(0) : Uint8List.fromList(value.data.asTypedList(value.length));
    if (value.is_error != 0) {
      final List<Object?> error = codec.decodeMessage(ByteData.sublistView(bytes()))! as List<Object?>;
      throw PlatformException(code: error[0]! as String, message: error[1] as String?, details: error[2]);
    }
    if (value.is_null != 0 || kind == 9) { return null; }
    switch (kind) {
      case 1: return value.integer != 0;
      case 2: return value.integer;
      case 3: return value.real;
      case 4: return cpp_convert.utf8.decode(bytes());
      case 5: return bytes();
      case 6: return bytes().buffer.asInt32List();
      case 7: return bytes().buffer.asInt64List();
      case 8: return bytes().buffer.asFloat64List();
      default: return codec.decodeMessage(ByteData.sublistView(bytes()));
    }
  } finally { _cppBindings.pigeon_free_value(pointer); }
}

class _CppPending {
  _CppPending(this.owner, this.kind);
  final _CppSession owner;
  final int kind;
  final Completer<Object?> completer = Completer<Object?>();
}
final Map<int, _CppPending> _cppPending = <int, _CppPending>{};
int _cppNextReply = 1;
// One listener per isolate. Disconnect fences native posts; already queued
// replies still need this listener so they can free their result buffers.
final cpp_ffi.NativeCallable<_CppReplyNative> _cppReply = cpp_ffi.NativeCallable<_CppReplyNative>.listener((int id, _CppValue pointer) {
  final _CppPending? pending = _cppPending.remove(id);
  try {
    if (pending == null || pending.completer.isCompleted) {
      _cppBindings.pigeon_free_value(pointer);
      return;
    }
    pending.owner.replies.remove(id);
    try { pending.completer.complete(_cppDecode(pointer, pending.owner.codec, pending.kind)); }
    catch (error, stack) { pending.completer.completeError(error, stack); }
  } finally { _cppReply.keepIsolateAlive = _cppPending.isNotEmpty; }
})..keepIsolateAlive = false;

class _CppSession {
  _CppSession(this.id, this.codec, this.disconnect);
  static _CppSession connect(String name, MessageCodec<Object?> codec,
      _CppValue Function(cpp_ffi.Pointer<cpp_ffi.Uint8>, int) connect,
      _CppValue Function(int) disconnect) {
    return cpp_alloc.using((cpp_alloc.Arena arena) {
      final List<int> bytes = cpp_convert.utf8.encode(name);
      final cpp_ffi.Pointer<cpp_ffi.Uint8> pointer = arena<cpp_ffi.Uint8>(bytes.isEmpty ? 1 : bytes.length);
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      final int id = _cppDecode(connect(pointer, bytes.length), codec, 2)! as int;
      if (id == 0) { _throwNoInstanceError(name); }
      return _CppSession(id, codec, disconnect);
    });
  }
  final int id;
  final MessageCodec<Object?> codec;
  final _CppValue Function(int) disconnect;
  final Set<int> replies = <int>{};
  bool disposed = false;
  void checkOpen() { if (disposed) { throw StateError('This C++ native interop session is disposed.'); } }
  Future<Object?> invokeAsync(void Function(int) invoke, int kind) {
    checkOpen();
    if (_cppNextReply == 9223372036854775807) { throw StateError('FFI reply identifiers exhausted.'); }
    final int id = _cppNextReply++;
    final _CppPending pending = _CppPending(this, kind);
    _cppPending[id] = pending;
    replies.add(id);
    _cppReply.keepIsolateAlive = true;
    try { invoke(id); }
    catch (error, stack) {
      _cppPending.remove(id);
      replies.remove(id);
      pending.completer.completeError(error, stack);
      _cppReply.keepIsolateAlive = _cppPending.isNotEmpty;
    }
    return pending.completer.future;
  }
  void dispose() {
    if (disposed) { return; }
    _cppDecode(disconnect(id), codec, 9);
    disposed = true;
    for (final int id in replies) {
      // Keep the listener alive until each native terminal reply is drained.
      // The future fails immediately, while queued native buffers remain owned.
      _cppPending[id]?.completer.completeError(StateError('The C++ native interop session was disposed.'));
    }
    replies.clear();
    _cppReply.keepIsolateAlive = _cppPending.isNotEmpty;
  }
}
''';
