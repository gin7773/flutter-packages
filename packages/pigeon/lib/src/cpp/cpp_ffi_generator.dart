// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../ast.dart';
import '../functional.dart';
import '../generator_tools.dart';
import 'shared/error_or_generator.dart';

/// General comment opening token for C/C++.
const String _commentPrefix = '//';

/// Documentation comment spec.
const DocumentCommentSpecification _docCommentSpec = DocumentCommentSpecification(_commentPrefix);

/// Generator for C++ FFI backend.
///
/// This generator produces three files:
/// 1. messages.h - C++ HostApi interface (abstract class with pure virtual methods)
/// 2. messages_ffi.h - C ABI declarations (extern "C" functions for ffigen)
/// 3. messages.cc - C ABI dispatch implementation
class CppFfiGenerator {
  /// Constructor.
  const CppFfiGenerator();

  /// Generates all FFI backend files.
  void generate(CppFfiOptions generatorOptions, Root root, {required String dartPackageName}) {
    // Generate C ABI header (messages_ffi.h).
    final String ffiHeaderContent = _generateFfiHeader(
      generatorOptions,
      root,
      dartPackageName: dartPackageName,
    );

    // Generate C++ HostApi header (messages.h).
    final String hostApiHeaderContent = _generateHostApiHeader(
      generatorOptions,
      root,
      dartPackageName: dartPackageName,
    );

    // Generate C ABI source (messages.cc).
    final String ffiSourceContent = _generateFfiSource(
      generatorOptions,
      root,
      dartPackageName: dartPackageName,
    );

    // Write files.
    _writeFile(generatorOptions.ffiHeaderOut, ffiHeaderContent);
    _writeFile(generatorOptions.ffiHeaderOut.replaceAll('_ffi.h', '.h'), hostApiHeaderContent);
    _writeFile(generatorOptions.ffiSourceOut, ffiSourceContent);
  }

  String _generateFfiHeader(
    CppFfiOptions generatorOptions,
    Root root, {
    required String dartPackageName,
  }) {
    final indent = Indent();

    // Prologue.
    if (generatorOptions.copyrightHeader != null) {
      addLines(indent, generatorOptions.copyrightHeader!, linePrefix: '// ');
    }
    indent.writeln('$_commentPrefix ${getGeneratedCodeWarning()}');
    indent.writeln('$_commentPrefix $seeAlsoWarning');
    indent.newln();

    // Header guard.
    final String guardName = _getGuardName(generatorOptions.ffiHeaderOut);
    indent.writeln('#ifndef $guardName');
    indent.writeln('#define $guardName');
    indent.newln();

    // System includes for C ABI header.
    indent.writeln('#include <stdint.h>');
    indent.writeln('#include <stddef.h>');
    indent.newln();

    // Forward declarations for custom types.
    _writeForwardDeclarations(root, indent);

    // PigeonFfiBuffer struct.
    _writeFfiBufferStruct(indent);
    indent.newln();

    // C ABI function declarations.
    _writeFfiFunctionDeclarations(generatorOptions, root, indent);
    indent.newln();

    // Close header guard.
    indent.writeln('#endif  // $guardName');

    return indent.toString();
  }

  String _generateHostApiHeader(
    CppFfiOptions generatorOptions,
    Root root, {
    required String dartPackageName,
  }) {
    final indent = Indent();

    // Prologue.
    if (generatorOptions.copyrightHeader != null) {
      addLines(indent, generatorOptions.copyrightHeader!, linePrefix: '// ');
    }
    indent.writeln('$_commentPrefix ${getGeneratedCodeWarning()}');
    indent.writeln('$_commentPrefix $seeAlsoWarning');
    indent.newln();

    // Header guard.
    final String headerPath = generatorOptions.ffiHeaderOut.replaceAll('_ffi.h', '.h');
    final String guardName = _getGuardName(headerPath);
    indent.writeln('#ifndef $guardName');
    indent.writeln('#define $guardName');
    indent.newln();

    // System includes.
    indent.writeln('#include <string>');
    indent.writeln('#include <variant>');
    indent.writeln('#include <memory>');
    indent.newln();

    // Open namespace.
    if (generatorOptions.namespace != null) {
      indent.writeln('namespace ${generatorOptions.namespace} {');
      indent.newln();
    }

    // Write ErrorOr<T> and FlutterError classes.
    _writeGeneralUtilities(indent, root);
    indent.newln();

    // Write enum declarations.
    for (final Enum anEnum in root.enums) {
      _writeEnumDeclaration(anEnum, indent);
      indent.newln();
    }

    // Write class declarations.
    for (final Class clazz in root.classes) {
      _writeClassDeclaration(clazz, indent, root);
      indent.newln();
    }

    // Write HostApi abstract classes.
    for (final Api api in root.apis) {
      if (api is AstHostApi) {
        _writeHostApiClass(api, indent, root);
        indent.newln();
      }
    }

    // Write SetUp function declarations.
    for (final Api api in root.apis) {
      if (api is AstHostApi) {
        indent.writeln('/// Sets up the ${api.name} handler.');
        indent.writeln('void ${api.name}SetUp(${api.name}* api);');
        indent.newln();
      }
    }

    // Close namespace.
    if (generatorOptions.namespace != null) {
      indent.writeln('}  // namespace ${generatorOptions.namespace}');
      indent.newln();
    }

    // Close header guard.
    indent.writeln('#endif  // $guardName');

    return indent.toString();
  }

  String _generateFfiSource(
    CppFfiOptions generatorOptions,
    Root root, {
    required String dartPackageName,
  }) {
    final indent = Indent();

    // Prologue.
    if (generatorOptions.copyrightHeader != null) {
      addLines(indent, generatorOptions.copyrightHeader!, linePrefix: '// ');
    }
    indent.writeln('$_commentPrefix ${getGeneratedCodeWarning()}');
    indent.writeln('$_commentPrefix $seeAlsoWarning');
    indent.newln();

    // Includes.
    final String headerPath = generatorOptions.ffiHeaderOut.replaceAll('_ffi.h', '.h');
    indent.writeln('#include "$headerPath"');
    indent.writeln('#include "${generatorOptions.ffiHeaderOut}"');
    indent.newln();

    indent.writeln('#include <cstring>');
    indent.newln();

    // Open anonymous namespace for internal helpers.
    indent.writeln('namespace {');
    indent.newln();

    // Write binary codec helpers (placeholder).
    indent.writeln('// TODO: Implement binary codec helpers for encoding/decoding messages.');

    indent.writeln('}  // namespace');
    indent.newln();

    // Open namespace.
    if (generatorOptions.namespace != null) {
      indent.writeln('namespace ${generatorOptions.namespace} {');
      indent.newln();
    }

    // Write global HostApi pointer.
    for (final Api api in root.apis) {
      if (api is AstHostApi) {
        indent.writeln('${api.name}* g_${api.name}_api = nullptr;');
      }
    }
    indent.newln();

    // Write dispatch function implementations.
    final String prefix = generatorOptions.symbolPrefix ?? 'pigeon_';
    for (final Api api in root.apis) {
      if (api is AstHostApi) {
        for (final Method method in api.methods) {
          _writeFfiFunctionDefinition(api, method, prefix, indent);
        }
      }
    }

    // Write free_buffer implementation.
    _writeFreeBuffer(indent, prefix);
    indent.newln();

    // Write abi_version function.
    _writeAbiVersion(indent, prefix);
    indent.newln();

    // Close namespace.
    if (generatorOptions.namespace != null) {
      indent.writeln('}  // namespace ${generatorOptions.namespace}');
    }

    return indent.toString();
  }

  void _writeForwardDeclarations(Root root, Indent indent) {
    // Write forward declarations for custom classes.
    for (final Class clazz in root.classes) {
      indent.writeln('class ${clazz.name};');
    }
    if (root.classes.isNotEmpty) {
      indent.newln();
    }
  }

  void _writeFfiBufferStruct(Indent indent) {
    indent.writeln('/// FFI buffer structure for passing binary data between Dart and C++.');
    indent.writeln('/// The buffer ownership is transferred to the caller, who must call');
    indent.writeln('/// free_buffer() when done.');
    indent.writeln('typedef struct PigeonFfiBuffer {');
    indent.writeln('  uint8_t* data;');
    indent.writeln('  size_t length;');
    indent.writeln('} PigeonFfiBuffer;');
  }

  void _writeFfiFunctionDeclarations(CppFfiOptions generatorOptions, Root root, Indent indent) {
    final String prefix = generatorOptions.symbolPrefix ?? 'pigeon_';

    // Write function declarations for each HostApi method.
    for (final Api api in root.apis) {
      if (api is AstHostApi) {
        for (final Method method in api.methods) {
          indent.writeln('/// FFI dispatch function for ${api.name}.${method.name}');
          indent.writeln(
            'extern "C" ${prefix}_ffi PigeonFfiBuffer ${prefix}${method.name}(const PigeonFfiBuffer* request);',
          );
        }
      }
    }

    if (root.apis.any((api) => api is AstHostApi)) {
      indent.newln();
    }

    // Write free_buffer declaration.
    indent.writeln('/// Frees a buffer allocated by the FFI dispatch functions.');
    indent.writeln('/// This function is safe to call with a null buffer.');
    indent.writeln('extern "C" ${prefix}_ffi void ${prefix}free_buffer(PigeonFfiBuffer* buffer);');
    indent.newln();

    // Write abi_version declaration.
    indent.writeln('/// Returns the ABI version string.');
    indent.writeln('extern "C" ${prefix}_ffi const char* ${prefix}abi_version(void);');
  }

  void _writeGeneralUtilities(Indent indent, Root root) {
    // Write ErrorOr<T> and FlutterError classes.
    ErrorOrGenerator.writeFlutterError(indent);
    if (root.containsHostApi) {
      ErrorOrGenerator.writeErrorOr(
        indent,
        friends: root.apis.where((Api api) => api is AstHostApi).map((Api api) => api.name),
      );
    }
  }

  void _writeEnumDeclaration(Enum anEnum, Indent indent) {
    addDocumentationComments(indent, anEnum.documentationComments, _docCommentSpec);
    indent.write('enum class ${anEnum.name} ');
    indent.writeln('{');
    enumerate(anEnum.members, (int index, EnumMember member) {
      addDocumentationComments(indent, member.documentationComments, _docCommentSpec);
      final valueName = 'k${_pascalCaseFromCamelCase(member.name)}';
      indent.writeln('  $valueName = $index${index == anEnum.members.length - 1 ? '' : ','}');
    });
    indent.writeln('};');
  }

  void _writeClassDeclaration(Class classDefinition, Indent indent, Root root) {
    const generatedMessages = <String>[
      ' Generated class from Pigeon that represents data sent in messages.',
    ];

    addDocumentationComments(
      indent,
      classDefinition.documentationComments,
      _docCommentSpec,
      generatorComments: generatedMessages,
    );

    final Iterable<NamedType> orderedFields = getFieldsInSerializationOrder(classDefinition);

    indent.write('class ${classDefinition.name} ');
    indent.writeln('{');
    indent.writeln(' public:');

    // Constructors.
    final Iterable<NamedType> requiredFields = orderedFields.where(
      (NamedType type) => !type.type.isNullable,
    );
    if (requiredFields.length != orderedFields.length) {
      _writeClassConstructor(
        indent,
        root,
        classDefinition,
        requiredFields,
        'Constructs an object setting all non-nullable fields.',
      );
    }
    _writeClassConstructor(
      indent,
      root,
      classDefinition,
      orderedFields,
      'Constructs an object setting all fields.',
    );

    // Getters and setters.
    for (final field in orderedFields) {
      addDocumentationComments(indent, field.documentationComments, _docCommentSpec);
      final HostDatatype baseDatatype = getFieldHostDatatype(field, _baseCppTypeForBuiltinDartType);
      // Getter.
      indent.writeln('  ${_getterReturnType(baseDatatype)} ${_makeGetterName(field)}() const;');
      // Setter.
      final String setterName = _makeSetterName(field);
      indent.writeln('  void $setterName(${_unownedArgumentType(baseDatatype)} value_arg);');
      if (field.type.isNullable) {
        // Non-nullable setter for convenience.
        final HostDatatype nonNullType = _nonNullableType(baseDatatype);
        indent.writeln('  void $setterName(${_unownedArgumentType(nonNullType)} value_arg);');
      }
      indent.newln();
    }

    // Equality operators.
    indent.writeln('  bool operator==(const ${classDefinition.name}& other) const;');
    indent.writeln('  bool operator!=(const ${classDefinition.name}& other) const;');

    // Stream output operator.
    indent.writeln('  /// Stream output operator for formatted string representation.');
    indent.writeln(
      '  friend std::ostream& operator<<(std::ostream& os, const ${classDefinition.name}& obj);',
    );

    // Private members.
    indent.writeln(' private:');
    for (final field in orderedFields) {
      final HostDatatype hostDatatype = getFieldHostDatatype(field, _baseCppTypeForBuiltinDartType);
      indent.writeln('  ${_fieldType(hostDatatype)} ${_makeInstanceVariableName(field)};');
    }

    indent.writeln('};');
  }

  void _writeClassConstructor(
    Indent indent,
    Root root,
    Class classDefinition,
    Iterable<NamedType> params,
    String docComment,
  ) {
    final List<String> paramStrings = params.map((NamedType param) {
      final HostDatatype hostDatatype = getFieldHostDatatype(param, _baseCppTypeForBuiltinDartType);
      return '${_hostApiArgumentType(hostDatatype)} ${_makeVariableName(param)}';
    }).toList();

    indent.writeln('  /// $docComment');
    indent.writeln('  ${classDefinition.name}(${paramStrings.join(', ')});');
    indent.newln();
  }

  void _writeHostApiClass(AstHostApi api, Indent indent, Root root) {
    const generatedMessages = <String>[
      ' Generated interface from Pigeon that represents a handler of messages from Flutter.',
    ];
    addDocumentationComments(
      indent,
      api.documentationComments,
      _docCommentSpec,
      generatorComments: generatedMessages,
    );

    indent.write('class ${api.name} ');
    indent.writeln('{');
    indent.writeln(' public:');

    // Prevent copying/assigning.
    indent.writeln('  ${api.name}(const ${api.name}&) = delete;');
    indent.writeln('  ${api.name}& operator=(const ${api.name}&) = delete;');

    // Virtual destructor.
    indent.writeln('  virtual ~${api.name}() = default;');
    indent.newln();

    // Pure virtual methods.
    for (final Method method in api.methods) {
      final HostDatatype returnType = getHostDatatype(
        method.returnType,
        _baseCppTypeForBuiltinDartType,
      );
      final String returnTypeName = _hostApiReturnType(returnType);

      final parameters = <String>[];
      if (method.parameters.isNotEmpty) {
        for (final NamedType arg in method.parameters) {
          final HostDatatype hostType = getFieldHostDatatype(arg, _baseCppTypeForBuiltinDartType);
          parameters.add('${_hostApiArgumentType(hostType)} ${_makeVariableName(arg)}');
        }
      }

      addDocumentationComments(indent, method.documentationComments, _docCommentSpec);
      indent.writeln(
        '  virtual $returnTypeName ${_makeMethodName(method)}(${parameters.join(', ')}) = 0;',
      );
      indent.newln();
    }

    indent.writeln('};');
  }

  void _writeFfiFunctionDefinition(AstHostApi api, Method method, String prefix, Indent indent) {
    indent.writeln(
      'extern "C" ${prefix}_ffi PigeonFfiBuffer ${prefix}${method.name}(const PigeonFfiBuffer* request) {',
    );
    indent.writeln('  PigeonFfiBuffer response = {nullptr, 0};');
    indent.newln();

    indent.writeln('  // TODO: Decode request, call HostApi, encode response');
    indent.writeln('  // This is a placeholder implementation.');
    indent.newln();

    indent.writeln('  return response;');
    indent.writeln('}');
    indent.newln();
  }

  void _writeFreeBuffer(Indent indent, String prefix) {
    indent.writeln('extern "C" void ${prefix}free_buffer(PigeonFfiBuffer* buffer) {');
    indent.writeln('  if (buffer && buffer->data) {');
    indent.writeln('    delete[] buffer->data;');
    indent.writeln('    buffer->data = nullptr;');
    indent.writeln('    buffer->length = 0;');
    indent.writeln('  }');
    indent.writeln('}');
  }

  void _writeAbiVersion(Indent indent, String prefix) {
    indent.writeln('extern "C" const char* ${prefix}abi_version(void) {');
    indent.writeln('  return "1.0.0";');
    indent.writeln('}');
  }

  String _getGuardName(String path) {
    final String fileName = path.split('/').last;
    return fileName.toUpperCase().replaceAll('.', '_').replaceAll('-', '_');
  }

  void _writeFile(String filePath, String content) {
    // This is a placeholder - actual file writing will be handled by the caller.
    // For now, just print to indicate generation.
    // ignore: avoid_print
    print('Would write to $filePath');
  }
}

// Helper functions copied/adapted from cpp_generator.dart

String _pascalCaseFromCamelCase(String camelCase) =>
    camelCase[0].toUpperCase() + camelCase.substring(1);

String _snakeCaseFromCamelCase(String camelCase) {
  return camelCase.replaceAllMapped(
    RegExp(r'[A-Z]'),
    (Match m) => '${m.start == 0 ? '' : '_'}${m[0]?.toLowerCase() ?? ''}',
  );
}

String _makeMethodName(Method method) => _pascalCaseFromCamelCase(method.name);

String _makeGetterName(NamedType field) => _snakeCaseFromCamelCase(field.name);

String _makeSetterName(NamedType field) => 'set_${_snakeCaseFromCamelCase(field.name)}';

String _makeVariableName(NamedType field) => _snakeCaseFromCamelCase(field.name);

String _makeInstanceVariableName(NamedType field) => '${_makeVariableName(field)}_';

String? _baseCppTypeForBuiltinDartType(
  TypeDeclaration type, {
  bool includeFlutterNamespace = true,
}) {
  final flutterNamespace = includeFlutterNamespace ? '::flutter::' : '';
  final cppTypeForDartTypeMap = <String, String>{
    'void': 'void',
    'bool': 'bool',
    'int': 'int64_t',
    'String': 'std::string',
    'double': 'double',
    'Uint8List': 'std::vector<uint8_t>',
    'Int32List': 'std::vector<int32_t>',
    'Int64List': 'std::vector<int64_t>',
    'Float64List': 'std::vector<double>',
    'Map': '${flutterNamespace}EncodableMap',
    'List': '${flutterNamespace}EncodableList',
    'Object': '${flutterNamespace}EncodableValue',
  };
  if (cppTypeForDartTypeMap.containsKey(type.baseName)) {
    return cppTypeForDartTypeMap[type.baseName];
  } else {
    return null;
  }
}

/// Returns the C++ type to use in a value context (variable declaration,
/// pass-by-value, etc.) for the given C++ base type.
String _valueType(HostDatatype type) {
  final String baseType = type.datatype;
  return type.isNullable ? 'std::optional<$baseType>' : baseType;
}

/// Returns the C++ type to use when declaring a data class field for the
/// given type.
String _fieldType(HostDatatype type) {
  return _isPointerField(type) ? 'std::unique_ptr<${type.datatype}>' : _valueType(type);
}

/// Returns true if [type] should be stored as a pointer, rather than a
/// value type, in a data class.
bool _isPointerField(HostDatatype type) {
  // Custom class types are stored as `unique_ptr`s since they can have
  // arbitrary size, and can also be arbitrarily (including recursively)
  // nested, so must be stored as pointers.
  return !type.isBuiltin && !type.isEnum;
}

/// Returns true if [type] corresponds to a plain-old-data type.
bool _isPodType(HostDatatype type) {
  switch (type.datatype) {
    case 'bool':
    case 'int64_t':
    case 'double':
      return false;
    default:
      return true;
  }
}

/// Returns the C++ type to use in an argument context without ownership
/// transfer for the given base type.
String _unownedArgumentType(HostDatatype type) {
  final isString = type.datatype == 'std::string';
  final String baseType = isString ? 'std::string_view' : type.datatype;
  if (isString || _isPodType(type)) {
    return type.isNullable ? 'const $baseType*' : baseType;
  }
  return type.isNullable ? 'const $baseType*' : 'const $baseType&';
}

/// Returns the C++ type to use for arguments to a host API.
String _hostApiArgumentType(HostDatatype type) {
  final String baseType = type.datatype;
  if (_isPodType(type)) {
    return type.isNullable ? 'const $baseType*' : baseType;
  }
  return type.isNullable ? 'const $baseType*' : 'const $baseType&';
}

/// Returns the C++ type to use for the return of a getter for a field of type
/// [type].
String _getterReturnType(HostDatatype type) {
  final String baseType = type.datatype;
  if (_isPodType(type)) {
    return type.isNullable ? 'const $baseType*' : baseType;
  }
  return type.isNullable ? 'const $baseType*' : 'const $baseType&';
}

/// Returns the C++ type to use for the return of a host API method returning
/// [type].
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

/// Returns a non-nullable variant of [type].
HostDatatype _nonNullableType(HostDatatype type) {
  return HostDatatype(
    datatype: type.datatype,
    isBuiltin: type.isBuiltin,
    isNullable: false,
    isEnum: type.isEnum,
  );
}

/// Options that control how C++ FFI code will be generated.
class CppFfiOptions {
  /// Creates a [CppFfiOptions] object.
  const CppFfiOptions({
    this.namespace,
    this.copyrightHeader,
    required this.ffiHeaderOut,
    required this.ffiSourceOut,
    required this.ffiBindingOut,
    this.ffiConfigOut,
    this.symbolPrefix,
    this.libraryMode = FfiLibraryMode.process,
  });

  /// The namespace where the generated class will live.
  final String? namespace;

  /// A copyright header that will get prepended to generated code.
  final Iterable<String>? copyrightHeader;

  /// Path to the C ABI header file (e.g., "messages_ffi.h").
  final String ffiHeaderOut;

  /// Path to the C ABI source file (e.g., "messages.cc").
  final String ffiSourceOut;

  /// Path to the Dart ffigen binding file (e.g., "messages.g.ffi.dart").
  final String ffiBindingOut;

  /// Path to the ffigen config file (optional, defaults to tool/pigeon/).
  final String? ffiConfigOut;

  /// Symbol prefix for exported C functions.
  final String? symbolPrefix;

  /// Library loading mode for Dart FFI.
  final FfiLibraryMode libraryMode;

  /// Creates a [CppFfiOptions] from a Map representation.
  static CppFfiOptions fromMap(Map<String, Object> map) {
    return CppFfiOptions(
      namespace: map['namespace'] as String?,
      copyrightHeader: (map['copyrightHeader'] as Iterable?)?.cast<String>(),
      ffiHeaderOut: map['ffiHeaderOut'] as String,
      ffiSourceOut: map['ffiSourceOut'] as String,
      ffiBindingOut: map['ffiBindingOut'] as String,
      ffiConfigOut: map['ffiConfigOut'] as String?,
      symbolPrefix: map['symbolPrefix'] as String?,
      libraryMode: FfiLibraryMode.values.byName(map['libraryMode'] as String? ?? 'process'),
    );
  }

  /// Converts a [CppFfiOptions] to a Map representation.
  Map<String, Object> toMap() {
    return {
      if (namespace != null) 'namespace': namespace!,
      if (copyrightHeader != null) 'copyrightHeader': copyrightHeader!,
      'ffiHeaderOut': ffiHeaderOut,
      'ffiSourceOut': ffiSourceOut,
      'ffiBindingOut': ffiBindingOut,
      if (ffiConfigOut != null) 'ffiConfigOut': ffiConfigOut!,
      if (symbolPrefix != null) 'symbolPrefix': symbolPrefix!,
      'libraryMode': libraryMode.name,
    };
  }
}

/// Library loading mode for Dart FFI.
enum FfiLibraryMode {
  /// Load from the current process (default).
  process,

  /// Load from a dynamic library.
  dylib,
}
