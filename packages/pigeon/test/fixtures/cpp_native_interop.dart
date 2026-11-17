// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

enum Choice { first, second }

class Box {
  Box({required this.value, this.label});
  int value;
  String? label;
}

@HostApi()
abstract class CppTestApi {
  int add(int value);
  int sumWithNames(int result, int args, int arena, int bytes, int id);
  int? echoInt(int? value);
  bool echoBool(bool value);
  double echoDouble(double value);
  String? echoString(String? value);
  Uint8List echoBytes(Uint8List value);
  Int32List? echoInt32(Int32List? value);
  Int64List echoInt64(Int64List value);
  Float64List echoFloat64(Float64List value);
  Choice? echoEnum(Choice? value);
  Box echoBox(Box value);
  Box mixed(int increment, Box value, String label);
  List<Object?> echoList(List<Object?> value);
  Map<String?, Object?> echoMap(Map<String?, Object?> value);
  Object? echoObject(Object? value);
  void ping();
  void fail();
  @async
  int delayed(int value);
  @asyncCallback
  int pending(int value);
  @async
  void abandoned();
  @async
  Box asyncBox(Box value);
  @async
  void asyncVoid();
}
