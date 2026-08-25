// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import '../ast.dart';
import '../generator_tools.dart';

/// Generator for ffigen configuration script.
///
/// This generator produces a Dart script that can be run to generate
/// low-level FFI bindings from the C ABI header.
class CppFfigenConfigGenerator {
  /// Constructor.
  const CppFfigenConfigGenerator();

  /// Generates ffigen configuration script.
  String generateConfigScript(CppFfigenConfigOptions options, Root root) {
    final config = _buildFfigenConfig(options);
    return _buildScript(config, options);
  }

  String _buildFfigenConfig(CppFfigenConfigOptions options) {
    final headerPath = options.headerPath.replaceAll('\\', '/');
    final outputPath = options.outputPath.replaceAll('\\', '/');

    return '''
ffigen:
  name: '${options.name}'
  description: 'FFI bindings for ${options.name}'
  output: '$outputPath'
  headers:
    entry-points:
      - '$headerPath'
    include-directives:
      - '$headerPath'
  compiler-opts:
    - '-I/usr/include'
    - '-I/usr/local/include'
  sort: true
  ignore-source-errors: false
  structs:
    include:
      - 'PigeonFfiBuffer'
  functions:
    include:
      - '${options.symbolPrefix}.*'
    exclude:
      - '.*SetUp.*'
  comments:
    style: any
    length: full
''';
  }

  String _buildScript(String config, CppFfigenConfigOptions options) {
    final scriptName = options.scriptName;
    final configPath = options.configPath.replaceAll('\\', '/');

    // Build the script using string concatenation to avoid triple-quote issues
    final buffer = StringBuffer();
    buffer.writeln('''
// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Script to generate FFI bindings for C++ backend.
///
/// Run this script using: dart run $scriptName
library;

import 'dart:io';

void main() async {
  // FFIgen configuration as YAML string
  final configYaml = <String>[
''');

    // Split config into lines and add each as a string literal
    for (final line in config.split('\n')) {
      // Escape single quotes and backslashes for Dart string
      final escapedLine = line.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      buffer.writeln("    '$escapedLine',");
    }

    buffer.writeln('''
  ].join('\\n');

  // Write config to file
  final configFile = File('$configPath');
  await configFile.writeAsString(configYaml);
  
  print('Generated ffigen config at: \${configFile.absolute.path}');
  print('');
  print('To generate FFI bindings, run:');
  print('  dart run ffigen --config \${configFile.absolute.path}');
}
''');

    return buffer.toString();
  }
}

/// Options that control how ffigen config will be generated.
class CppFfigenConfigOptions {
  /// Creates a [CppFfigenConfigOptions] object.
  const CppFfigenConfigOptions({
    required this.name,
    required this.headerPath,
    required this.outputPath,
    required this.scriptPath,
    required this.configPath,
    this.symbolPrefix = 'pigeon_',
  });

  /// Name of the FFI binding.
  final String name;

  /// Path to the C ABI header file.
  final String headerPath;

  /// Path to the output FFI binding file.
  final String outputPath;

  /// Path to the generated script file.
  final String scriptPath;

  /// Path to the generated config file.
  final String configPath;

  /// Symbol prefix for filtering functions.
  final String symbolPrefix;

  /// Gets the script name from the script path.
  String get scriptName => scriptPath.split('/').last;

  /// Creates a [CppFfigenConfigOptions] from a Map representation.
  static CppFfigenConfigOptions fromMap(Map<String, Object> map) {
    return CppFfigenConfigOptions(
      name: map['name'] as String,
      headerPath: map['headerPath'] as String,
      outputPath: map['outputPath'] as String,
      scriptPath: map['scriptPath'] as String,
      configPath: map['configPath'] as String,
      symbolPrefix: map['symbolPrefix'] as String? ?? 'pigeon_',
    );
  }

  /// Converts a [CppFfigenConfigOptions] to a Map representation.
  Map<String, Object> toMap() {
    return {
      'name': name,
      'headerPath': headerPath,
      'outputPath': outputPath,
      'scriptPath': scriptPath,
      'configPath': configPath,
      if (symbolPrefix != 'pigeon_') 'symbolPrefix': symbolPrefix,
    };
  }
}
