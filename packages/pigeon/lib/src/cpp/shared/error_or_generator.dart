// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../../generator_tools.dart';

/// Shared generator for `ErrorOr<T>` and `FlutterError` C++ classes.
///
/// This is extracted from cpp_generator.dart to be reused by both
/// the platform-channel C++ generator and the FFI C++ generator.
class ErrorOrGenerator {
  /// Generates `FlutterError` class definition.
  static void writeFlutterError(Indent indent) {
    indent.format('''

class FlutterError {
 public:
\texplicit FlutterError(const std::string& code)
\t\t: code_(code) {}
\texplicit FlutterError(const std::string& code, const std::string& message)
\t\t: code_(code), message_(message) {}
\texplicit FlutterError(const std::string& code, const std::string& message, const ::flutter::EncodableValue& details)
\t\t: code_(code), message_(message), details_(details) {}

\tconst std::string& code() const { return code_; }
\tconst std::string& message() const { return message_; }
\tconst ::flutter::EncodableValue& details() const { return details_; }

 private:
\tstd::string code_;
\tstd::string message_;
\t::flutter::EncodableValue details_;
};''');
  }

  /// Generates `ErrorOr<T>` template class definition.
  ///
  /// [friends] is a list of class names that should be friends of `ErrorOr<T>`.
  /// This is used to allow only specific classes to construct `ErrorOr` instances.
  static void writeErrorOr(Indent indent, {Iterable<String> friends = const <String>[]}) {
    final String friendLines = friends
        .map((String className) => '\tfriend class $className;')
        .join('\n');
    indent.format('''

template<class T> class ErrorOr {
 public:
\tErrorOr(const T& rhs) : v_(rhs) {}
\tErrorOr(const T&& rhs) : v_(std::move(rhs)) {}
\tErrorOr(const FlutterError& rhs) : v_(rhs) {}
\tErrorOr(const FlutterError&& rhs) : v_(std::move(rhs)) {}

\tbool has_error() const { return std::holds_alternative<FlutterError>(v_); }
\tconst T& value() const { return std::get<T>(v_); };
\tconst FlutterError& error() const { return std::get<FlutterError>(v_); };

 private:
$friendLines
\tErrorOr() = default;
\tT TakeValue() && { return std::get<T>(std::move(v_)); }

\tstd::variant<T, FlutterError> v_;
};
''');
  }
}
