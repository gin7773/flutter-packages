# Experimental C++ native interop (Windows)

This backend implements the existing `HostApiForNativeInterop` interface. The
normal `HostApi` class and its Platform Channel constructor remain available.
It supports synchronous and asynchronous HostApi methods, including
`@asyncCallback`, using the shared hybrid transport classification.

This is an initial Windows implementation. FlutterApi, EventChannelApi, ProxyApi,
custom TaskQueues, and the legacy `objects` transport are rejected. Linux support,
automatic engine discovery, and integration into the repository's CI shards are
separate follow-up work. The validation steps below must pass before proposing
this implementation for upstream review.

## Generating code

Configure the existing C++ generator:

```dart
@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/messages.dart',
  cppHeaderOut: 'windows/messages.h',
  cppSourceOut: 'windows/messages.cpp',
  cppOptions: CppOptions(
    namespace: 'my_plugin',
    useFfi: true,
    ffiLibraryName: 'my_plugin_plugin.dll',
  ),
))
```

The additional outputs are `windows/messages.ffi.h`,
`windows/messages.ffi.cpp`, `windows/messages.ffigen.yaml`, and
`lib/messages.native_interop.dart`. Run ffigen explicitly to create
`lib/messages.cpp_ffi.dart`:

```powershell
dart run pigeon --input pigeons/messages.dart
dart run ffigen --config windows/messages.ffigen.yaml
```

The consuming Flutter package needs `ffi` as a dependency and `ffigen` as a dev
dependency. Configure `llvm-path` in the generated ffigen YAML if LLVM is not
discoverable. C++ and Swift bindings have different filenames, so a common
HostApi definition can also enable Swift FFI and Kotlin JNI.

Add **both** `messages.cpp` and `messages.ffi.cpp` to the plugin's CMake sources.
Use C++17 with exceptions enabled (`/EHsc` and `_HAS_EXCEPTIONS=1` for MSVC).
The DLL name must match the compiled plugin DLL. Use a distinct C++ namespace
for each generated definition in the same DLL; exported names include the
package, namespace, header basename, API, and method.

## Registration, sessions, and ownership

```cpp
// The plugin retains the implementation and this registration token.
registration_id_ = my_plugin::RegisterExampleApiFfi(api_.get(), "engine-a");

// During teardown: prevent new calls and finish posting cancellation replies.
my_plugin::UnregisterExampleApiFfi(registration_id_);
// Then stop/join work owned by the implementation before destroying it.
api_->StopAndJoin();  // Application-specific; not a generated method.
api_.reset();
```

```dart
final api = ExampleApiForNativeInterop.getInstance(channelName: 'engine-a')!;
try {
  final value = api.synchronousMethod();
  await api.asynchronousMethod();
} finally {
  api.pigeonDispose();
}
```

Alternatively use `ExampleApi.createWithNativeInteropApi(messageChannelSuffix:
'engine-a')` to keep the normal Future-based API. Call `pigeonDispose()` on that
wrapper when finished. An injected native interop instance is shared by reference:
disposing either wrapper disposes that instance. Create separate instances when
independent lifetimes are required.

Each `getInstance` creates a separate session. Disposing one session does not
unregister the implementation or affect another session. A session stays attached
to its original registration: unregistering and registering the same name never
redirects an old session to the new implementation. Unregistration uses an opaque
token so delayed cleanup of an old registration cannot remove its replacement.

For multiple engines, the plugin supplies a unique name per registration and
passes that name to the corresponding Dart entrypoint. Background isolates also
receive that name explicitly. Duplicate names are rejected; there is no fallback
to an arbitrary engine. To deliberately share one implementation across engines,
register it **once**, connect each engine using that name, and keep it alive until
all engines are finished. The implementation must support concurrent calls.

This differs from Swift/JNI's engine-aware registrars: C++ currently uses explicit
names, not `PlatformDispatcher.engineId` lookup or engine affinity fallback.
Do not treat two registration names as proof of a real two-engine test; the
dedicated runner below creates two `FlutterEngine` objects in one process.

## Threads and memory

- A synchronous method runs directly on the Dart caller's native thread. Only
  use it for short operations valid on that thread. It does not imply that the
  caller is always on the platform thread.
- An asynchronous method also **enters** on the caller's thread. The implementation
  schedules any work on its required thread and returns promptly. Merely adding
  `@async` does not schedule a thread switch.
- There is no synchronous dispatcher or UI-to-platform wait in the adapter.
  Implementations must not block waiting for a thread that is waiting for them.
- Input references are borrowed for the duration of the entry. Copy strings,
  vectors, data classes, and other referenced inputs before using them later.
- Native results are owned by the adapter and freed after Dart copies/decodes
  them. Scalars, enums, strings, and typed data bypass the codec. Complex
  arguments share one encoded buffer; complex results and error details use the
  generated codec. This is not a zero-allocation or zero-copy transport.
- Unregister waits for active native entries and callback posts, cancels pending
  replies, and rejects new entries. It does **not** join implementation-owned asynchronous workers.
  Unregistering from inside an active call is rejected to avoid a self-deadlock.
- Dispose Dart sessions before an isolate exits or an engine shuts down. For a
  forced shutdown, native unregistration and worker shutdown must occur first.
  Abruptly killing an isolate with live native callbacks is unsupported.
- Keep the DLL loaded while sessions, native work, or queued replies exist.
  Never unload it immediately after posting an asynchronous reply.

The runtime fences callback posts during disposal and suppresses duplicate or
late replies. One listener remains available per isolate to free replies already
queued before disposal. Pending calls keep the isolate alive until completion or
explicit disposal. Applications still own cancellation/timeouts for work that
never completes.

`keepIsolateAlive` does not prevent an explicit `Isolate.exit`/`Isolate.kill` or
engine shutdown. `Isolate.run` also exits explicitly when its computation returns:
await all its asynchronous FFI calls before returning. Synchronous disposal fences
native posts but does not synchronously drain queued Dart replies; forcibly exiting
at that point can discard replies that still own native buffers. Supporting that
case requires an asynchronous drain protocol and is outside this initial backend.

## Reproducing the verification on another Windows machine

Copy this local branch to that machine, including the commit containing this
document. No push is required: a Git bundle, or a copy of the entire checkout,
can be used. A plain diff must include newly added files.

Prerequisites:

1. Flutter with Dart **3.12 or later** and Windows desktop support. The two-engine
   runner also uses `DartProject.set_ui_thread_policy` and
   `PlatformDispatcher.engineId`; use a current Flutter SDK containing these APIs.
2. Visual Studio 2022 with **Desktop development with C++**, the Windows SDK,
   and CMake. Use its **Developer PowerShell** so `cmake` and `ctest` are on PATH.
3. An LLVM installation containing `libclang.dll` for ffigen.
4. Windows x64. This harness selects x64 explicitly.

From the checkout's `packages/pigeon` directory, record the environment:

```powershell
git rev-parse HEAD
git status --short
flutter --version
flutter doctor -v
cmake --version
dart pub get
dart analyze lib test bin
dart test test
```

Run the full harness twice, substituting your installation directories:

```powershell
.\tool\test_cpp_native_interop.ps1 `
  -FlutterSdk C:\src\flutter `
  -LlvmDirectory 'C:\Program Files\LLVM' `
  -Configuration Debug -MultiEngine

.\tool\test_cpp_native_interop.ps1 `
  -FlutterSdk C:\src\flutter `
  -LlvmDirectory 'C:\Program Files\LLVM' `
  -Configuration Release -MultiEngine
```

If script execution is disabled by your local policy, run it using your normal
approved PowerShell script policy. The script does not change system policy.

The script performs these steps and stops at the first nonzero exit code:

1. Precache the Windows engine and resolve the real package dependencies.
2. Generate normal C++/Dart code, the C ABI adapter, and ffigen bindings from the
   checked-in `test/fixtures/cpp_native_interop.dart` definition.
3. Build the DLL and native executable using CMake/MSVC, then run CTest.
4. Copy `runtime_test.dart.tmpl` alongside the generated code and run
   `flutter test build/cpp_native_interop/runtime_test.dart` in `platform_tests/test_plugin`.
   This exercises the generated companion with Flutter's real Dart codec. Keeping
   the source as a template avoids adding a DLL-dependent test to unrelated test runs.
5. With `-MultiEngine`, create a disposable Windows app under `build/`, copy the
   generated code and checked-in engine harness into it, and build the app.
6. Start two headless Flutter engines in one process. Engine A and B use different
   implementations of the same API. Both also exercise a background isolate.
   A disposes and stops; A2 starts with A's old name and a different result bias.
   B keeps making calls while A is replaced.
7. Repeat step 6 with the UI isolate on the platform thread and on a separate
   thread. The Release app verifies Dart AOT; running Flutter unit tests against
   a Release DLL alone would not verify AOT.

Expected results:

| Check | Expected result |
| --- | --- |
| Generator tests | All pass; no analyzer findings |
| Native CTest | `cpp_native_interop` passes; executable prints its check count |
| Flutter tests | All 5 tests pass without a timeout or uncaught error |
| Engine runner | `PASS: two engines, Debug/Release, --platform-ui/--separate-ui` |
| Engine report files | A, A2, and B all start with `PASS`; distinct engines have distinct IDs |
| Engine B during replacement | Always gets its own `200 + value` result |
| Replacement A2 | Gets `300 + value`; old sessions fail instead of reconnecting |

The generated app and reports are under:

```text
platform_tests/test_plugin/build/cpp_native_interop/
  native/Debug/                 (or Release)
  engine_app/build/windows/x64/runner/Debug/
    cpp_engine_A.result
    cpp_engine_A2.result
    cpp_engine_B.result
```

Keep the console output, the three report files for each configuration/thread
policy, `flutter doctor -v`, and the commit hash. The script saves successful
reports under `build/cpp_native_interop/reports/<configuration>/<thread-policy>/`.
An engine timeout, missing result file, crash, stale session succeeding, or result
from the wrong registration is a failure.

### Web compilation check

After the script has created `engine_app`, temporarily replace its `lib/main.dart`
with this smoke app (only the disposable generated app is changed):

```dart
import 'package:flutter/widgets.dart';
import 'messages.dart';

void main() {
  final api = CppTestApi();
  runApp(Text(api.runtimeType.toString(), textDirection: TextDirection.ltr));
}
```

Run `flutter build web` from that app directory. It must compile without importing
`dart:ffi` into the web implementation. The test verifies the normal API import;
it does not attempt Windows native interop in a browser. Rerunning the PowerShell
harness restores the two-engine `main.dart`.

### Remaining checks before upstream submission

The standalone harness is deliberately reproducible without editing an existing
application. It is not yet wired into Pigeon's CI matrix. Before submission:

Run the existing Windows regression suites from `packages/pigeon` as well:

```powershell
dart run tool/test.dart --list
dart run tool/test.dart --test dart_unittests,flutter_unittests,command_line_tests,windows_unittests,windows_integration_tests
```

This uses the repository's normal generation step. Keep any generation diff for
review; do not discard it. The new standalone C++ FFI harness must still be run
separately. For repository metadata and publishing checks, run from the root:

```powershell
dart pub get -C script/tool
dart run script/tool/bin/flutter_plugin_tools.dart validate --packages=pigeon
dart run script/tool/bin/flutter_plugin_tools.dart publish-check --packages=pigeon
```

The remaining upstream preparation includes:

- Integrate generation, native tests, and Windows integration tests into the
  repository's normal generation/test suites, and review the public lifecycle API.
- Run the full Flutter/native package checks on an equipped machine, including
  generation consistency and the existing Windows platform tests.
- Run a sustained attach/call/dispose/detach loop with MSVC AddressSanitizer or
  equivalent memory diagnostics; retain crash and leak reports.
- Benchmark against Platform Channels in the **same Release/AOT application**,
  using the same implementation and payloads. Measure synchronous integers,
  strings, typed data, data classes, and asynchronous calls separately, after
  warm-up, with multiple samples. Do not claim a performance improvement from
  the type classification or from a Debug build alone.

The headless runner uses Flutter's public Windows
[FlutterEngine](https://github.com/flutter/flutter/blob/main/engine/src/flutter/shell/platform/windows/client_wrapper/include/flutter/flutter_engine.h)
and [DartProject](https://github.com/flutter/flutter/blob/main/engine/src/flutter/shell/platform/windows/client_wrapper/include/flutter/dart_project.h)
interfaces. Registration names are provided explicitly by the harness; it does
not claim to implement Swift/JNI's engine-affinity resolution policy.
