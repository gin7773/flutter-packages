// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'flutter_utils.dart';
import 'process_utils.dart';

Future<int> runFlutterCommand(
  String projectDirectory,
  String command,
  List<String> commandArguments, {
  String? wrapperCommand,
  String? flutterExecutable,
  Map<String, String>? environment,
}) {
  final String flutterCommand = flutterExecutable ?? getFlutterCommand();
  return runProcess(
    wrapperCommand ?? flutterCommand,
    <String>[if (wrapperCommand != null) flutterCommand, command, ...commandArguments],
    workingDirectory: projectDirectory,
    environment: environment,
  );
}

Future<int> runFlutterBuild(
  String projectDirectory,
  String target, {
  bool debug = true,
  List<String> flags = const <String>[],
  String? flutterExecutable,
}) {
  return runFlutterCommand(projectDirectory, 'build', <String>[
    target,
    if (debug) '--debug',
    ...flags,
  ], flutterExecutable: flutterExecutable);
}

Future<int> runXcodeBuild(
  String nativeProjectDirectory, {
  String? sdk,
  String? destination,
  List<String> extraArguments = const <String>[],
}) {
  return runProcess('xcodebuild', <String>[
    '-workspace',
    'Runner.xcworkspace',
    '-scheme',
    'Runner',
    if (sdk != null) ...<String>['-sdk', sdk],
    if (destination != null) ...<String>['-destination', destination],
    ...extraArguments,
  ], workingDirectory: nativeProjectDirectory);
}

Future<int> runGradleBuild(String nativeProjectDirectory, [String? command]) {
  return runProcess('./gradlew', <String>[
    if (command != null) command,
  ], workingDirectory: nativeProjectDirectory);
}

/// Finds the common C++ wrapper, fetching the SDK's exact revision if needed.
Future<String> getFlutterCppWrapper(String sdk, String buildDirectory) async {
  const sourcePath = 'engine/src/flutter/shell/platform/common/client_wrapper';
  String? wrapper = Platform.environment['FLUTTER_CPP_WRAPPER_DIR'];
  wrapper ??= Platform.isWindows
      ? p.join(sdk, 'bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper')
      : p.join(sdk, sourcePath);
  if (Platform.environment['FLUTTER_CPP_WRAPPER_DIR'] == null &&
      Platform.isLinux &&
      !File(p.join(wrapper, 'standard_codec.cc')).existsSync()) {
    final ProcessResult revisionResult = await Process.run('git', <String>[
      '-C',
      sdk,
      'rev-parse',
      'HEAD',
    ]);
    if (revisionResult.exitCode != 0) {
      throw StateError('Cannot identify Flutter SDK sources; set FLUTTER_CPP_WRAPPER_DIR.');
    }
    final String revision = (revisionResult.stdout as String).trim();
    final String checkout = p.join(buildDirectory, 'flutter-wrapper', revision);
    wrapper = p.join(checkout, sourcePath);
    if (!File(p.join(wrapper, 'standard_codec.cc')).existsSync()) {
      for (final arguments in <List<String>>[
        <String>['init', checkout],
        <String>[
          '-C',
          checkout,
          'config',
          'remote.origin.url',
          'https://github.com/flutter/flutter.git',
        ],
        <String>['-C', checkout, 'config', 'remote.origin.promisor', 'true'],
        <String>['-C', checkout, 'config', 'remote.origin.partialclonefilter', 'blob:none'],
        <String>['-C', checkout, 'sparse-checkout', 'init', '--cone'],
        <String>['-C', checkout, 'sparse-checkout', 'set', sourcePath],
        <String>['-C', checkout, 'fetch', '--depth=1', '--filter=blob:none', 'origin', revision],
        <String>['-C', checkout, 'checkout', '--detach', 'FETCH_HEAD'],
      ]) {
        if (await runProcess('git', arguments) != 0) {
          throw StateError('Could not fetch the Flutter C++ wrapper at $revision.');
        }
      }
    }
  }
  if (!File(p.join(wrapper, 'standard_codec.cc')).existsSync() ||
      !Directory(p.join(wrapper, 'include/flutter')).existsSync()) {
    throw StateError('Invalid C++ wrapper: $wrapper. Set FLUTTER_CPP_WRAPPER_DIR.');
  }
  return p.absolute(wrapper);
}

/// Runs an engine test and checks fresh results from every engine.
///
/// A successful process exit alone is not evidence that all three Dart
/// entrypoints finished. Delete old reports before starting, including saved
/// reports, so a startup failure cannot be mistaken for a previous success.
Future<int> runCppNativeInteropEngineTest({
  required String command,
  required List<String> arguments,
  required String bundleDirectory,
  required String reportDirectory,
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 70),
}) async {
  const reports = <String>['cpp_engine_A.result', 'cpp_engine_A2.result', 'cpp_engine_B.result'];
  Directory(reportDirectory).createSync(recursive: true);
  for (final name in reports) {
    for (final directory in <String>[bundleDirectory, reportDirectory]) {
      final file = File(p.join(directory, name));
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }
  final Process process = await Process.start(
    command,
    arguments,
    workingDirectory: bundleDirectory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final int exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () async {
      print('Engine test timed out after $timeout.');
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      return 1;
    },
  );
  var passed = exitCode == 0;
  for (final name in reports) {
    final file = File(p.join(bundleDirectory, name));
    if (!file.existsSync()) {
      print('Missing engine report: $name');
      passed = false;
      continue;
    }
    final String contents = file.readAsStringSync();
    print(contents);
    file.copySync(p.join(reportDirectory, name));
    passed = passed && contents.startsWith('PASS ');
  }
  return passed ? 0 : (exitCode == 0 ? 1 : exitCode);
}
