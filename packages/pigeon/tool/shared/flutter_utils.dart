// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String getFlutterCommand() => Platform.isWindows ? 'flutter.bat' : 'flutter';

/// Finds the SDK used by the test tools without requiring a machine-specific path.
String getFlutterSdkPath() {
  final String dartSdk = p.dirname(p.dirname(Platform.resolvedExecutable));
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final String root) root,
    // Flutter's Dart executable is in bin/cache/dart-sdk/bin.
    p.dirname(p.dirname(p.dirname(dartSdk))),
    for (final directory in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    ))
      if (directory.isNotEmpty && File(p.join(directory, getFlutterCommand())).existsSync())
        p.dirname(
          p.dirname(File(p.join(directory, getFlutterCommand())).resolveSymbolicLinksSync()),
        ),
  ];
  return p.absolute(
    candidates.firstWhere(
      (String root) => File(p.join(root, 'bin', getFlutterCommand())).existsSync(),
      orElse: () => throw StateError('Add Flutter to PATH or set FLUTTER_ROOT to the Flutter SDK.'),
    ),
  );
}

/// Returns the first device listed by `flutter devices` that targets
/// [platform], or null if there is no such device.
Future<String?> getDeviceForPlatform(String platform) async {
  final ProcessResult result = await Process.run(getFlutterCommand(), <String>[
    'devices',
    '--machine',
  ], stdoutEncoding: utf8);
  if (result.exitCode != 0) {
    return null;
  }

  var output = result.stdout as String;
  // --machine doesn't currently prevent the tool from printing banners;
  // see https://github.com/flutter/flutter/issues/86055. This workaround
  // can be removed once that is fixed.
  output = output.substring(output.indexOf('['));

  final List<Map<String, dynamic>> devices = (jsonDecode(output) as List<dynamic>)
      .cast<Map<String, dynamic>>();
  for (final deviceInfo in devices) {
    final String targetPlatform = (deviceInfo['targetPlatform'] as String?) ?? '';
    if (targetPlatform.startsWith(platform)) {
      final deviceId = deviceInfo['id'] as String?;
      if (deviceId != null) {
        return deviceId;
      }
    }
  }
  return null;
}
