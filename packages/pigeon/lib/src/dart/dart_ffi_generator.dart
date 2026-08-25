// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:code_builder/code_builder.dart' as cb;
import 'package:dart_style/dart_style.dart';

import '../ast.dart';
import '../functional.dart';
import '../generator_tools.dart';

/// Documentation comment open symbol.
const String _docCommentPrefix = '///';

/// Documentation comment spec.
const DocumentCommentSpecification _docCommentSpec = DocumentCommentSpecification(
  _docCommentPrefix,
);

/// Generator for Dart FFI wrapper code.
///
/// This generator produces high-level wrapper code that uses the low-level
/// ffigen bindings to provide a Pigeon-compatible API.
class DartFfiGenerator {
  /// Constructor.
  const DartFfiGenerator();

  /// Generates Dart FFI wrapper code.
  String generate(DartFfiOptions options, Root root, {required String dartPackageName}) {
    final emitter = cb.DartEmitter(
      allocator: cb.Allocator.none,
      orderDirectives: true,
      useNullSafetySyntax: true,
    );

    final library = _buildLibrary(options, root, dartPackageName: dartPackageName);
    final code = library.accept(emitter).toString();

    final formatter = DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);
    return formatter.format(code);
  }

  cb.Library _buildLibrary(DartFfiOptions options, Root root, {required String dartPackageName}) {
    return cb.Library(
      (b) => b
        ..comments.addAll(_buildPrologue(options))
        ..directives.addAll(_buildDirectives(options, root))
        ..body.addAll(_buildBody(options, root)),
    );
  }

  List<String> _buildPrologue(DartFfiOptions options) {
    final comments = <String>[];
    if (options.copyrightHeader != null) {
      comments.addAll(options.copyrightHeader!.map((line) => '// $line'));
      comments.add('');
    }
    comments.add('/// ${getGeneratedCodeWarning()}');
    comments.add('/// $seeAlsoWarning');
    return comments;
  }

  List<cb.Directive> _buildDirectives(DartFfiOptions options, Root root) {
    final directives = <cb.Directive>[
      cb.Directive.import('dart:ffi'),
      cb.Directive.import(options.ffiBindingPath, as: 'ffi'),
    ];

    // Add imports for custom types.
    for (final Class clazz in root.classes) {
      // Custom types are defined in the same file or imported separately.
      // For now, assume they're in the same generated file.
    }

    return directives;
  }

  List<cb.Class> _buildBody(DartFfiOptions options, Root root) {
    final classes = <cb.Class>[];

    // Generate binary codec helpers.
    classes.add(_buildCodecHelpers(options));

    // Generate API classes for each HostApi.
    for (final Api api in root.apis) {
      if (api is AstHostApi) {
        classes.add(_buildHostApiClass(options, api, root));
      }
    }

    return classes;
  }

  cb.Class _buildCodecHelpers(DartFfiOptions options) {
    return cb.Class(
      (b) => b
        ..name = '_Codec'
        ..methods.addAll([
          // encodeRequest method
          cb.Method(
            (b) => b
              ..name = 'encodeRequest'
              ..returns = cb.refer('Uint8List')
              ..static = true
              ..requiredParameters.add(
                cb.Parameter(
                  (b) => b
                    ..name = 'message'
                    ..type = cb.refer('List<Object?>'),
                ),
              )
              ..body = cb.Code('''
// TODO: Implement request encoding using StandardMessageCodec
throw UnimplementedError('encodeRequest not implemented');'''),
          ),
          // decodeResponse method
          cb.Method(
            (b) => b
              ..name = 'decodeResponse'
              ..returns = cb.refer('Object?')
              ..static = true
              ..requiredParameters.add(
                cb.Parameter(
                  (b) => b
                    ..name = 'response'
                    ..type = cb.refer('Uint8List'),
                ),
              )
              ..body = cb.Code('''
// TODO: Implement response decoding using StandardMessageCodec
throw UnimplementedError('decodeResponse not implemented');'''),
          ),
          // errorEnvelopeToException method
          cb.Method(
            (b) => b
              ..name = 'errorEnvelopeToException'
              ..returns = cb.refer('Exception')
              ..static = true
              ..requiredParameters.add(
                cb.Parameter(
                  (b) => b
                    ..name = 'envelope'
                    ..type = cb.refer('List<Object?>'),
                ),
              )
              ..body = cb.Code('''
// TODO: Implement error envelope to exception conversion
throw UnimplementedError('errorEnvelopeToException not implemented');'''),
          ),
        ]),
    );
  }

  cb.Class _buildHostApiClass(DartFfiOptions options, AstHostApi api, Root root) {
    return cb.Class(
      (b) => b
        ..name = api.name
        ..docs.addAll(_buildClassDocs(api))
        ..fields.addAll(_buildHostApiFields(options, api))
        ..constructors.add(_buildHostApiConstructor(options, api))
        ..methods.addAll(_buildHostApiMethods(options, api, root)),
    );
  }

  List<String> _buildClassDocs(AstHostApi api) {
    final docs = <String>[];
    if (api.documentationComments.isNotEmpty) {
      for (final comment in api.documentationComments) {
        docs.add('$_docCommentPrefix $comment');
      }
    }
    docs.add('$_docCommentPrefix Generated class from Pigeon that represents a host API.');
    docs.add('$_docCommentPrefix This class uses FFI to call into native code.');
    return docs;
  }

  List<cb.Field> _buildHostApiFields(DartFfiOptions options, AstHostApi api) {
    return [
      // ffiBinding field
      cb.Field(
        (b) => b
          ..name = '_binding'
          ..type = cb.refer('ffi.${api.name}Binding')
          ..modifier = cb.FieldModifier.final$,
      ),
      // allocator field
      cb.Field(
        (b) => b
          ..name = '_allocator'
          ..type = cb.refer('ffi.Allocator')
          ..modifier = cb.FieldModifier.final$,
      ),
    ];
  }

  cb.Constructor _buildHostApiConstructor(DartFfiOptions options, AstHostApi api) {
    return cb.Constructor(
      (b) => b
        ..requiredParameters.addAll([
          cb.Parameter(
            (b) => b
              ..name = 'binding'
              ..type = cb.refer('ffi.${api.name}Binding'),
          ),
          cb.Parameter(
            (b) => b
              ..name = 'allocator'
              ..type = cb.refer('ffi.Allocator')
              ..named = true,
          ),
        ])
        ..initializers.addAll([
          cb.Code('_binding = binding'),
          cb.Code('_allocator = allocator ?? ffi.calloc'),
        ]),
    );
  }

  List<cb.Method> _buildHostApiMethods(DartFfiOptions options, AstHostApi api, Root root) {
    final methods = <cb.Method>[];

    for (final Method method in api.methods) {
      methods.add(_buildHostApiMethod(options, api, method, root));
    }

    // Add dispose method
    methods.add(
      cb.Method(
        (b) => b
          ..name = 'dispose'
          ..returns = cb.refer('void')
          ..body = cb.Code('_allocator.free(_binding);'),
      ),
    );

    return methods;
  }

  cb.Method _buildHostApiMethod(DartFfiOptions options, AstHostApi api, Method method, Root root) {
    final returnType = _getDartReturnType(method.returnType);
    final parameters = _buildMethodParameters(method);

    return cb.Method(
      (b) => b
        ..name = method.name
        ..docs.addAll(_buildMethodDocs(method))
        ..returns = cb.refer(returnType)
        ..requiredParameters.addAll(parameters)
        ..body = cb.Code(_buildMethodBody(options, api, method, root)),
    );
  }

  List<cb.Parameter> _buildMethodParameters(Method method) {
    final parameters = <cb.Parameter>[];

    for (final NamedType param in method.parameters) {
      final dartType = _getDartType(param.type);
      parameters.add(
        cb.Parameter(
          (b) => b
            ..name = param.name
            ..type = cb.refer(dartType),
        ),
      );
    }

    return parameters;
  }

  List<String> _buildMethodDocs(Method method) {
    final docs = <String>[];
    if (method.documentationComments.isNotEmpty) {
      for (final comment in method.documentationComments) {
        docs.add('$_docCommentPrefix $comment');
      }
    }
    return docs;
  }

  String _buildMethodBody(DartFfiOptions options, AstHostApi api, Method method, Root root) {
    final returnType = _getDartReturnType(method.returnType);

    // Build request message
    final requestArgs = method.parameters.map((p) => p.name).join(', ');
    final requestList = requestArgs.isEmpty ? '[]' : '[$requestArgs]';

    return '''
// Encode request message
final request = _Codec.encodeRequest($requestList);

// Allocate buffer for request
final requestBuffer = _allocator<Uint8>(request.length);
requestBuffer.asTypedList(request.length).setAll(0, request);

// Create FFI buffer struct
final requestFfi = ffi.PigeonFfiBuffer(
  data: requestBuffer,
  length: request.length,
);

// Call native function
final responseFfi = _binding.${method.name}(requestFfi);

// Read response
final responseLength = responseFfi.length;
final responseData = responseFfi.data!.asTypedList(responseLength).toList();

// Free response buffer
ffi.pigeon_free_buffer(responseFfi);

// Decode response
final response = _Codec.decodeResponse(Uint8List.fromList(responseData));

// Return result
return response as $returnType;''';
  }

  String _getDartReturnType(TypeDeclaration returnType) {
    if (returnType.isVoid) {
      return 'void';
    }
    return _getDartType(returnType);
  }

  String _getDartType(TypeDeclaration type) {
    switch (type.baseName) {
      case 'void':
        return 'void';
      case 'bool':
        return 'bool';
      case 'int':
        return 'int';
      case 'String':
        return 'String';
      case 'double':
        return 'double';
      case 'Uint8List':
        return 'Uint8List';
      case 'Int32List':
        return 'Int32List';
      case 'Int64List':
        return 'Int64List';
      case 'Float64List':
        return 'Float64List';
      case 'List':
        return 'List';
      case 'Map':
        return 'Map';
      case 'Object':
        return 'Object';
      default:
        // Custom class or enum
        return type.baseName;
    }
  }
}

/// Options that control how Dart FFI wrapper code will be generated.
class DartFfiOptions {
  /// Creates a [DartFfiOptions] object.
  const DartFfiOptions({
    this.copyrightHeader,
    required this.ffiBindingPath,
    required this.dartOutPath,
  });

  /// A copyright header that will get prepended to generated code.
  final Iterable<String>? copyrightHeader;

  /// Path to the ffigen binding file (e.g., "lib/src/messages.g.ffi.dart").
  final String ffiBindingPath;

  /// Path to the output Dart wrapper file.
  final String dartOutPath;

  /// Creates a [DartFfiOptions] from a Map representation.
  static DartFfiOptions fromMap(Map<String, Object> map) {
    return DartFfiOptions(
      copyrightHeader: (map['copyrightHeader'] as Iterable?)?.cast<String>(),
      ffiBindingPath: map['ffiBindingPath'] as String,
      dartOutPath: map['dartOutPath'] as String,
    );
  }

  /// Converts a [DartFfiOptions] to a Map representation.
  Map<String, Object> toMap() {
    return {
      if (copyrightHeader != null) 'copyrightHeader': copyrightHeader!,
      'ffiBindingPath': ffiBindingPath,
      'dartOutPath': dartOutPath,
    };
  }
}
