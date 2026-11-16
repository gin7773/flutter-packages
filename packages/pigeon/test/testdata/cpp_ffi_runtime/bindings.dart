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

  NativeLibrary.fromLookup(ffi.Pointer<T> Function<T extends ffi.NativeType>(String) _)
    : this(ffi.DynamicLibrary.process());

  static int allocated = 0;
  static int freed = 0;
  static Completer<void>? drained;
  static bool failListen = false;
  static bool failCancel = false;
  bool failStart = false;
  static int connectCalls = 0;
  static int disconnectCalls = 0;
  static int nextSession = 1;
  static final Map<int, String> sessions = <int, String>{};
  static final Map<int, int> streamSessions = <int, int>{};

  ffi.Pointer<PigeonFfiBuffer> connect(ffi.Pointer<PigeonFfiBuffer> request) {
    final args =
        jsonDecode(utf8.decode(request.ref.data.asTypedList(request.ref.length))) as List<Object?>;
    final int session = nextSession++;
    sessions[session] = args.single! as String;
    connectCalls++;
    return buffer(<Object?>[session]);
  }

  ffi.Pointer<PigeonFfiBuffer> disconnect(int session) {
    if (sessions.remove(session) == null) {
      throw StateError('Unknown session.');
    }
    disconnectCalls++;
    return buffer(<Object?>[null]);
  }

  ffi.Pointer<PigeonFfiBuffer> pigeon_session_3__x41_pi_connect(
    ffi.Pointer<PigeonFfiBuffer> request,
  ) => connect(request);
  ffi.Pointer<PigeonFfiBuffer> pigeon_session_3__x41_pi_disconnect(int session) =>
      disconnect(session);
  ffi.Pointer<PigeonFfiBuffer> pigeon_event_session_6__x45_vents_6_events_connect(
    ffi.Pointer<PigeonFfiBuffer> request,
  ) => connect(request);
  ffi.Pointer<PigeonFfiBuffer> pigeon_event_session_6__x45_vents_6_events_disconnect(int session) =>
      disconnect(session);

  final List<(int, int, ffi.Pointer<ffi.NativeFunction<ReplyCallback>>)> replies =
      <(int, int, ffi.Pointer<ffi.NativeFunction<ReplyCallback>>)>[];

  void pigeon_host_3__x41_pi_4_work(
    int session,
    ffi.Pointer<PigeonFfiBuffer> request,
    int replyId,
    ffi.Pointer<ffi.NativeFunction<ReplyCallback>> callback,
  ) {
    if (failStart) {
      throw StateError('Cannot start request.');
    }
    if (!sessions.containsKey(session)) {
      throw StateError('Disconnected session.');
    }
    replies.add((session, replyId, callback));
  }

  void reply(Object? envelope) {
    final (int _, int id, ffi.Pointer<ffi.NativeFunction<ReplyCallback>> callback) = replies
        .removeAt(0);
    callback.asFunction<void Function(int, ffi.Pointer<PigeonFfiBuffer>)>()(id, buffer(envelope));
  }

  ffi.Pointer<PigeonFfiBuffer> pigeon_event_6__x45_vents_6_events_listen(
    int session,
    ffi.Pointer<PigeonFfiBuffer> request,
    int sinkId,
    ffi.Pointer<ffi.NativeFunction<ReplyCallback>> onEvent,
    ffi.Pointer<ffi.NativeFunction<ReplyCallback>> onError,
    ffi.Pointer<ffi.NativeFunction<DoneCallback>> onDone,
  ) {
    if (!sessions.containsKey(session)) {
      throw StateError('Disconnected event session.');
    }
    if (!failListen) {
      streamSessions[sinkId] = session;
    }
    return buffer(failListen ? <Object?>['listen', 'failed', null] : <Object?>[null]);
  }

  ffi.Pointer<PigeonFfiBuffer> pigeon_event_6__x45_vents_6_events_cancel(
    int session,
    ffi.Pointer<PigeonFfiBuffer> request,
    int sinkId,
  ) {
    if (streamSessions.remove(sinkId) != session) {
      throw StateError('Wrong event session.');
    }
    return buffer(failCancel ? <Object?>['cancel', 'failed', null] : <Object?>[null]);
  }

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
