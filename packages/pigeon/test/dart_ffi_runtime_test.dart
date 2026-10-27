// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:pigeon/src/ast.dart';
import 'package:pigeon/src/dart/dart_generator.dart';
import 'package:pigeon/src/generator_tools.dart';
import 'package:test/test.dart';

void main() {
  test('generated shared FFI callbacks release idle isolates and survive reuse', () async {
    final api = AstHostApi(
      name: 'Api',
      methods: <Method>[
        Method(
          name: 'work',
          location: ApiLocation.host,
          isAsynchronous: true,
          returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
          parameters: <Parameter>[],
        ),
      ],
    );
    final events = AstEventChannelApi(
      name: 'Events',
      methods: <Method>[
        Method(
          name: 'events',
          location: ApiLocation.host,
          returnType: const TypeDeclaration(baseName: 'int', isNullable: false),
          parameters: <Parameter>[],
        ),
      ],
    );
    final root = Root(
      apis: <Api>[api, events],
      classes: <Class>[],
      enums: <Enum>[],
      containsHostApi: true,
      containsEventChannel: true,
    );
    const options = InternalDartOptions(
      ignoreLints: false,
      ffiOptions: InternalDartFfiOptions(
        bindingImportPath: 'bindings.dart',
        bindingClassName: 'NativeLibrary',
        nativeLibraryExpression: 'ffi.DynamicLibrary.process()',
      ),
    );
    final indent = Indent();
    const generator = DartGenerator();
    generator.writeGeneralUtilities(options, root, indent, dartPackageName: 'test');
    generator.writeHostApi(options, root, indent, api, dartPackageName: 'test');
    generator.writeEventChannelApi(options, root, indent, events, dartPackageName: 'test');

    final Directory dir = Directory.systemTemp.createTempSync('pigeon_ffi_runtime_');
    try {
      final fixtures = Directory('test/testdata/cpp_ffi_runtime');
      File('${fixtures.path}/bindings.dart').copySync('${dir.path}/bindings.dart');
      File('${dir.path}/main.dart').writeAsStringSync(
        '${File('${fixtures.path}/support.txt').readAsStringSync()}\n'
        '$indent\n'
        '${File('${fixtures.path}/main.txt').readAsStringSync()}',
      );
      final Uri packageConfig = (await Isolate.packageConfig)!;
      final Process process = await Process.start(Platform.resolvedExecutable, <String>[
        '--packages=${packageConfig.toFilePath()}',
        '${dir.path}/main.dart',
      ]);
      final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
      final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 20));
      } on TimeoutException {
        process.kill();
        await process.exitCode;
        fail('Generated callbacks kept an idle isolate alive.\n${await stdout}\n${await stderr}');
      }
      expect(exitCode, 0, reason: await stderr);
      expect(await stdout, contains('All callback lifecycle checks passed.'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
