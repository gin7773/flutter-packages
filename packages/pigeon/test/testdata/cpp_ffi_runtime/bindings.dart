// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkg_ffi;

final class PigeonFfiBuffer extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> data;
  @ffi.Size()
  external int length;
}

typedef ReplyCallback = ffi.Void Function(ffi.Int64, ffi.Pointer<PigeonFfiBuffer>);
typedef DoneCallback = ffi.Void Function(ffi.Int64);

/// A binding fixture that invokes real NativeCallable function pointers.
class NativeLibrary {
  NativeLibrary(ffi.DynamicLibrary _);

  static int allocated = 0;
  static int freed = 0;
  static Completer<void>? drained;
  static bool failListen = false;
  static bool failCancel = false;
  bool failStart = false;

  final List<(int, ffi.Pointer<ffi.NativeFunction<ReplyCallback>>)> replies =
      <(int, ffi.Pointer<ffi.NativeFunction<ReplyCallback>>)>[];

  void pigeon_api_work(
    ffi.Pointer<PigeonFfiBuffer> request,
    int replyId,
    ffi.Pointer<ffi.NativeFunction<ReplyCallback>> callback,
  ) {
    if (failStart) {
      throw StateError('Cannot start request.');
    }
    replies.add((replyId, callback));
  }

  void reply(Object? envelope) {
    final (int id, ffi.Pointer<ffi.NativeFunction<ReplyCallback>> callback) = replies.removeAt(0);
    callback.asFunction<void Function(int, ffi.Pointer<PigeonFfiBuffer>)>()(id, buffer(envelope));
  }

  ffi.Pointer<PigeonFfiBuffer> pigeon_events_events_listen(
    ffi.Pointer<PigeonFfiBuffer> request,
    int sinkId,
    ffi.Pointer<ffi.NativeFunction<ReplyCallback>> onEvent,
    ffi.Pointer<ffi.NativeFunction<ReplyCallback>> onError,
    ffi.Pointer<ffi.NativeFunction<DoneCallback>> onDone,
  ) => buffer(failListen ? <Object?>['listen', 'failed', null] : <Object?>[null]);

  ffi.Pointer<PigeonFfiBuffer> pigeon_events_events_cancel(
    ffi.Pointer<PigeonFfiBuffer> request,
    int sinkId,
  ) => buffer(failCancel ? <Object?>['cancel', 'failed', null] : <Object?>[null]);

  static ffi.Pointer<PigeonFfiBuffer> buffer(Object? value) {
    final List<int> bytes = utf8.encode(jsonEncode(value));
    final ffi.Pointer<PigeonFfiBuffer> result = pkg_ffi.calloc<PigeonFfiBuffer>();
    result.ref.data = pkg_ffi.calloc<ffi.Uint8>(bytes.length);
    result.ref.data.asTypedList(bytes.length).setAll(0, bytes);
    result.ref.length = bytes.length;
    allocated++;
    return result;
  }

  void pigeon_free_buffer(ffi.Pointer<PigeonFfiBuffer> value) {
    pkg_ffi.calloc.free(value.ref.data);
    pkg_ffi.calloc.free(value);
    freed++;
    if (freed == allocated) {
      drained?.complete();
      drained = null;
    }
  }

  static Future<void> waitForBuffers() {
    if (allocated == freed) {
      return Future<void>.value();
    }
    return (drained ??= Completer<void>()).future;
  }
}
