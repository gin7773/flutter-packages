#!/usr/bin/env bash
# Copyright 2013 The Flutter Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash tool/test_cpp_native_interop.sh [options]
  --configuration Debug|Release   Build configuration (default: Debug).
  --multi-engine                  Run real GTK engines, including replacement.
  --flutter-sdk PATH              Defaults to FLUTTER_ROOT or flutter on PATH.
  --llvm-path PATH                Optional libclang installation directory.
  --flutter-wrapper-dir PATH      Optional common C++ client_wrapper sources.
  --help                          Show this help.
EOF
}

configuration=Debug
multi_engine=false
flutter_sdk=${FLUTTER_ROOT:-}
llvm_path=
wrapper_dir=
while (($#)); do
  case "$1" in
    --configuration|--flutter-sdk|--llvm-path|--flutter-wrapper-dir)
      if (($# < 2)) || [[ $2 == --* ]]; then
        printf 'Missing value for %s\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --configuration) configuration=$2 ;;
        --flutter-sdk) flutter_sdk=$2 ;;
        --llvm-path) llvm_path=$2 ;;
        --flutter-wrapper-dir) wrapper_dir=$2 ;;
      esac
      shift 2
      ;;
    --multi-engine) multi_engine=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$configuration" in
  Debug|Release) ;;
  *) echo 'Configuration must be Debug or Release.' >&2; exit 2 ;;
esac
if [[ $(uname -s) != Linux ]]; then
  echo 'This script requires Linux; on Windows use test_cpp_native_interop.ps1.' >&2
  exit 2
fi
case "$(uname -m)" in
  x86_64) architecture=x64 ;;
  aarch64|arm64) architecture=arm64 ;;
  *) echo 'The Flutter desktop harness requires Linux x64 or arm64.' >&2; exit 2 ;;
esac
for executable in cmake ctest git; do
  command -v "$executable" >/dev/null || { echo "Missing command: $executable" >&2; exit 2; }
done
if [[ -z $flutter_sdk ]]; then
  flutter_command=$(command -v flutter) || { echo 'Set --flutter-sdk or add flutter to PATH.' >&2; exit 2; }
  flutter_sdk=$(dirname "$(dirname "$(readlink -f "$flutter_command")")")
fi
flutter_sdk=$(realpath "$flutter_sdk")
flutter="$flutter_sdk/bin/flutter"
dart="$flutter_sdk/bin/dart"
if [[ ! -x $flutter || ! -x $dart ]]; then
  echo "Not a Flutter SDK: $flutter_sdk (expected bin/flutter and bin/dart)." >&2
  exit 2
fi
export PATH="$flutter_sdk/bin:$PATH"
pigeon=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin="$pigeon/platform_tests/test_plugin"
generated="$plugin/build/cpp_native_interop"
fixture="$plugin/test/cpp_native_interop"
native="$generated/native-linux/$configuration"
mode=${configuration,,}
trap 'printf "Linux C++ FFI verification failed at line %s. Preserve the output above.\n" "$LINENO" >&2' ERR

cd "$pigeon"
printf 'Flutter SDK: %s\nConfiguration: %s\n' "$flutter_sdk" "$configuration"
"$flutter" precache --linux
"$dart" pub get
"$dart" run pigeon \
  --input test/fixtures/cpp_native_interop.dart \
  --dart_out "$generated/messages.dart" \
  --cpp_header_out "$generated/messages.h" \
  --cpp_source_out "$generated/messages.cpp" \
  --cpp_namespace cpp_test --cpp_use_ffi \
  --cpp_ffi_library_name libpigeon_cpp_test.so --package_name cpp_test

if [[ -z $llvm_path ]] && command -v llvm-config >/dev/null; then
  llvm_path=$(llvm-config --prefix)
fi
if [[ -z $llvm_path ]]; then
  while IFS= read -r candidate; do
    if compgen -G "$candidate/lib/libclang.so*" >/dev/null; then
      llvm_path=$candidate
    fi
  done < <(printf '%s\n' /usr/lib/llvm-* | sort -V)
fi
if [[ -n $llvm_path ]]; then
  llvm_path=$(realpath "$llvm_path")
  printf "\nllvm-path:\n  - '%s'\n" "${llvm_path//\'/\'\'}" >> "$generated/messages.ffigen.yaml"
  printf 'LLVM: %s\n' "$llvm_path"
fi
"$dart" run ffigen --config "$generated/messages.ffigen.yaml"

# Linux GTK artifacts do not promise the common C++ wrapper used by this ABI.
# Prefer the SDK's sources, or fetch only that directory at the SDK's exact
# framework revision. Never fetch a moving main branch for codec sources.
if [[ -z $wrapper_dir ]]; then
  wrapper_dir="$flutter_sdk/engine/src/flutter/shell/platform/common/client_wrapper"
  if [[ ! -f $wrapper_dir/standard_codec.cc ]]; then
    revision=$(git -C "$flutter_sdk" rev-parse HEAD) || {
      echo 'Cannot identify SDK sources. Supply --flutter-wrapper-dir.' >&2
      exit 2
    }
    source_checkout="$generated/flutter-wrapper/$revision"
    wrapper_dir="$source_checkout/engine/src/flutter/shell/platform/common/client_wrapper"
    if [[ ! -f $wrapper_dir/standard_codec.cc ]]; then
      git init "$source_checkout"
      git -C "$source_checkout" config remote.origin.url https://github.com/flutter/flutter.git
      git -C "$source_checkout" config remote.origin.promisor true
      git -C "$source_checkout" config remote.origin.partialclonefilter blob:none
      git -C "$source_checkout" sparse-checkout init --cone
      git -C "$source_checkout" sparse-checkout set engine/src/flutter/shell/platform/common/client_wrapper
      git -C "$source_checkout" fetch --depth=1 --filter=blob:none origin "$revision"
      git -C "$source_checkout" checkout --detach FETCH_HEAD
    fi
  fi
fi
wrapper_dir=$(realpath "$wrapper_dir")
if [[ ! -f $wrapper_dir/standard_codec.cc || ! -d $wrapper_dir/include/flutter ]]; then
  echo "Invalid common client_wrapper directory: $wrapper_dir" >&2
  exit 2
fi
cmake -S "$fixture" -B "$native" -DCMAKE_BUILD_TYPE="$configuration" \
  -DFLUTTER_WRAPPER_DIR="$wrapper_dir" -DGENERATED_DIR="$generated"
cmake --build "$native" --config "$configuration" --parallel 2
ctest --test-dir "$native" -C "$configuration" --output-on-failure --verbose
export LD_LIBRARY_PATH="$native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$plugin"
"$flutter" pub get
cp "$fixture/runtime_test.dart.tmpl" "$generated/runtime_test.dart"
"$flutter" test build/cpp_native_interop/runtime_test.dart --reporter expanded

if $multi_engine; then
  command -v timeout >/dev/null || { echo 'Install GNU coreutils (timeout).' >&2; exit 2; }
  display_runner=()
  if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
    command -v xvfb-run >/dev/null || { echo 'Real GTK engines require a desktop display or xvfb-run.' >&2; exit 2; }
    display_runner=(xvfb-run -a -s '-screen 0 1024x768x24')
  fi
  app="$generated/engine_app_linux"
  if [[ ! -f $app/pubspec.yaml ]]; then
    "$flutter" create --platforms=linux,web --project-name=cpp_engine_test "$app"
  fi
  cd "$app"
  "$flutter" pub add ffi
  cp "$generated/messages.dart" "$generated/messages.native_interop.dart" "$generated/messages.cpp_ffi.dart" "$app/lib/"
  cp "$fixture/multi_engine.dart.tmpl" "$app/lib/main.dart"
  cp "$fixture/multi_engine_linux.cc" "$app/linux/runner/main.cc"
  cp "$fixture/linux_runner.CMakeLists.txt" "$app/linux/runner/CMakeLists.txt"
  "$flutter" build linux "--$mode"
  bundle="$app/build/linux/$architecture/$mode/bundle"
  cp "$native/libpigeon_cpp_test.so" "$bundle/lib/"
  # Prefer the copy bundled with this executable, including for dlopen in Dart.
  export LD_LIBRARY_PATH="$bundle/lib:$LD_LIBRARY_PATH"
  cd "$bundle"
  for policy in --platform-ui --separate-ui; do
    reports="$generated/reports/linux/$configuration/${policy#--}"
    mkdir -p "$reports"
    # Clear only the known result files, including when GTK cannot start.
    rm -f -- cpp_engine_{A,A2,B}.result "$reports"/cpp_engine_{A,A2,B}.result
    status=0
    timeout --kill-after=5s 60s "${display_runner[@]}" ./cpp_engine_test "$policy" || status=$?
    for role in A A2 B; do
      report="cpp_engine_$role.result"
      if [[ -f $report ]]; then
        cat "$report"
        cp "$report" "$reports/"
      fi
    done
    if ((status != 0)); then
      echo "Real Linux engines failed: $configuration $policy (exit $status)." >&2
      exit "$status"
    fi
    for role in A A2 B; do
      grep -q '^PASS ' "cpp_engine_$role.result"
    done
    echo "PASS: two Linux engines, $configuration, $policy"
  done
fi
