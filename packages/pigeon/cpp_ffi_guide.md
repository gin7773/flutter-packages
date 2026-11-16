# C++ FFI Guide

This guide describes the experimental C++ FFI generation path for Pigeon.

For Swift FFI and Kotlin JNI, see the [Native Interop guide](native_interop_guide.md).
These backends use different binding and data conversion mechanisms. Generate
C++ Dart FFI and Swift FFI/Kotlin JNI from separate Pigeon files with separate
Dart output paths; combining them in one configuration is rejected.

## C++ FFI

C++ FFI lets Dart call generated C ABI functions directly through `dart:ffi`
instead of sending calls through `BasicMessageChannel`. The public Dart API is
still the normal Pigeon HostApi class generated in `messages.g.dart`; callers do
not need to call native pointers directly.

The generated call path is:

```text
Dart HostApi caller
  -> messages.g.dart
  -> messages.g.ffi.dart
  -> messages_ffi.cc
  -> hand-written C++ HostApi implementation
```

Asynchronous HostApi methods use the same generated C ABI layer, but native
code replies later through a generated callback:

```text
Dart HostApi caller
  -> messages.g.dart Future<T>
  -> messages.g.ffi.dart
  -> messages_ffi.cc
  -> hand-written C++ HostApi implementation
  -> generated reply callback
  -> Dart Completer<T>
```

FFI event streams use the same generated binding for `listen` and `cancel`,
then send native events back through generated callbacks:

```text
Dart Stream listener
  -> messages.g.dart
  -> messages.g.ffi.dart
  -> messages_ffi.cc listen/cancel
  -> hand-written C++ StreamHandler

hand-written C++ StreamHandler
  -> generated C++ EventSink
  -> Dart NativeCallable callback
  -> Dart StreamController
```

## Requirements

Add `ffi` as a dependency and `ffigen` as a dev dependency in the package that
runs Pigeon:

```sh
dart pub add ffi
dart pub add dev:ffigen
```

The package should then have entries similar to:

```yaml
dependencies:
  ffi: ...

dev_dependencies:
  ffigen: ...
```

The generated C++ sources must also be compiled into the native library that
Dart opens with FFI.

## Pigeon Configuration

Configure both the regular C++ generator and the C++ FFI generator. The regular
C++ files provide the typed HostApi interface and codec helpers; the FFI files
provide exported C ABI functions that ffigen can read.
`cppFfiHeaderOut` and `cppFfiSourceOut` must be configured together.

```dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartFfiOut: 'lib/src/messages.g.ffi.dart',
    configDirectory: 'tool/pigeon',
    dartOptions: DartOptions(
      ffiOptions: DartFfiOptions(
        bindingClassName: 'MessagesFfiBindings',
        nativeLibraryExpression: 'ffi.DynamicLibrary.process()',
      ),
    ),
    cppHeaderOut: 'tizen/messages.h',
    cppSourceOut: 'tizen/messages.cc',
    cppOptions: CppOptions(namespace: 'my_plugin'),
    cppFfiHeaderOut: 'tizen/messages_ffi.h',
    cppFfiSourceOut: 'tizen/messages_ffi.cc',
    dartPackageName: 'my_plugin',
  ),
)
@HostApi()
abstract class VideoPlayerApi {
  int create(String uri);

  @async
  int initialize(int playerId);

  void dispose(int playerId);
}

@EventChannelApi()
abstract class VideoPlayerEvents {
  Map<Object?, Object?> events();
}
```

If the generated FFI header cannot include the generated C++ API header by file
name alone, set `cppFfiOptions.apiHeaderIncludePath` explicitly:

```dart
cppFfiOptions: CppFfiOptions(
  apiHeaderIncludePath: 'path/visible/to/messages.h',
),
```

The C++ FFI adapter uses `cppOptions.namespace` by default so that
`SetUpMyApiFfi` and the generated C++ API classes live in the same namespace.
When both C++ outputs are generated and `cppFfiOptions.apiHeaderIncludePath` is
omitted, an explicit `cppFfiOptions.namespace` must match
`cppOptions.namespace`; mismatches are rejected before generation. When
`cppFfiOptions.apiHeaderIncludePath` is set, `cppFfiOptions.namespace` must
match the API namespace in that header, whether it was just generated or
already existed.

If the target C++ toolchain cannot compile `std::visit` with
`flutter::EncodableValue`, disable it for the regular C++ generator:

```dart
cppOptions: CppOptions(
  namespace: 'my_plugin',
  useStdVisit: false,
),
```

Run Pigeon from the package root:

```sh
dart run pigeon --input pigeons/messages.dart
```

When `dartFfiOut`, `cppFfiHeaderOut`, and `cppFfiSourceOut` are set, Pigeon
will generate the ffigen config file and then run ffigen automatically. By
default, the config file is written under `tool/pigeon`. You can change that
directory with `configDirectory` or `--config_dir`.
For example, `pigeons/messages.dart` produces
`tool/pigeon/messages_ffigen_config.yaml`.
Paths inside that config are written relative to the config file, so the Dart
FFI output may appear as `../../lib/src/messages.g.ffi.dart`.
Running from the package root lets `dart run ffigen` resolve the package's
`pubspec.yaml` and dev dependencies.

Set `dartFfiConfigOut` or `--dart_ffi_config_out` only when you need to override
the exact ffigen config file path.

The same paths can also be passed on the command line:

```sh
dart run pigeon \
  --input pigeons/messages.dart \
  --dart_out lib/src/messages.g.dart \
  --dart_ffi_out lib/src/messages.g.ffi.dart \
  --config_dir tool/pigeon \
  --dart_ffi_binding_class MessagesFfiBindings \
  --dart_ffi_native_library 'ffi.DynamicLibrary.process()' \
  --cpp_header_out tizen/messages.h \
  --cpp_source_out tizen/messages.cc \
  --cpp_namespace my_plugin \
  --cpp_ffi_header_out tizen/messages_ffi.h \
  --cpp_ffi_source_out tizen/messages_ffi.cc
```

## Generated Files

With the configuration above, Pigeon generates:

* `lib/src/messages.g.dart`: the high-level Dart HostApi wrapper and FFI event
  stream facade.
* `lib/src/messages.g.ffi.dart`: the low-level Dart FFI binding generated by
  ffigen.
* `tizen/messages.h` and `tizen/messages.cc`: the regular generated C++ API and
  codec support.
* `tizen/messages_ffi.h` and `tizen/messages_ffi.cc`: the generated C ABI
  adapter used by FFI.
* `tool/pigeon/messages_ffigen_config.yaml`: the ffigen configuration that
  Pigeon uses for the automatic ffigen step.

## Native Setup

Implement the generated C++ HostApi class as usual, then register that
implementation with the generated FFI setup function:

```cpp
#include <functional>
#include <utility>

#include "messages.h"
#include "messages_ffi.h"

namespace my_plugin {

class VideoPlayerApiImpl : public VideoPlayerApi {
 public:
  // Supplied by the plugin using the embedding's platform task runner.
  using PostTask = std::function<void(std::function<void()>)>;

  explicit VideoPlayerApiImpl(PostTask post_to_platform)
      : post_to_platform_(std::move(post_to_platform)) {}

  ErrorOr<int64_t> Create(const std::string& uri) override {
    return 1;
  }

  void Initialize(
      int64_t player_id,
      std::function<void(ErrorOr<int64_t> reply)> result) override {
    post_to_platform_([player_id, result = std::move(result)]() mutable {
      // Initialize the platform player here and return the operation's result.
      result(player_id);
    });
  }

  std::optional<FlutterError> Dispose(int64_t player_id) override {
    return std::nullopt;
  }

 private:
  PostTask post_to_platform_;
};

void RegisterVideoPlayerApiFfi(
    VideoPlayerApiImpl* api,
    const std::string& engine_name) {
  SetUpVideoPlayerApiFfi(api, engine_name);
}

}  // namespace my_plugin
```

### Threading

C++ FFI follows the Native Interop caller-thread model: synchronous methods and
the startup of async methods execute on the OS thread making the Dart call.
There is no generated thread dispatcher or automatic platform-thread hop.
Calling an `async` Dart wrapper does not move its synchronous FFI work to
another thread. C++ FFI rejects background `@TaskQueue` annotations because
calls bypass Flutter Engine message queues.

When the embedding merges the root isolate's UI and platform threads, root
isolate calls already run on the platform thread. Background isolates and
embeddings with separate UI/platform threads still need to respect each native
API's thread requirements.

If a method must use a platform task runner and can be called from another
thread, declare it `@async` and schedule its work inside the C++ implementation,
as shown by `Initialize` above. The plugin's posting function must enqueue work
without waiting for its completion. It must report rejection, for example by
throwing, and accepted work must eventually reply or be ended by explicit
session disposal. Do not silently discard pending work when a runner stops.
Catch failures inside posted tasks and report them through `result`; the adapter
can only catch exceptions thrown before the implementation returns.
Methods that remain synchronous, such as the `Create` and `Dispose` stubs above,
must be called on a thread permitted by their actual implementation.

The implementation owns its task runner and asynchronous resources. Avoid
blocking one thread while waiting for another thread that may need Dart to
process a message. The API implementation is borrowed and must remain valid
until its named `TearDown...Ffi` call returns; plugin-owned asynchronous work
that uses it must also finish or stop before it is destroyed.

Setup now takes only the implementation and optional registration name. Update
old `SetUp...Ffi(api, dispatcher, name)` calls to `SetUp...Ffi(api, name)` and
regenerate the C++ adapter header and source together. This dispatcher removal
does not change the session-based C ABI or the Dart binding signatures.

For an async HostApi method, the generated FFI adapter decodes the request and
starts the native call synchronously. The hand-written C++ implementation must
call the generated `result` callback exactly once when the operation completes.
It may call the callback before returning or later from another thread, but it
must not keep references to generated argument objects beyond their valid
lifetime unless it copies the data it needs. Native code remains responsible for
stopping its own asynchronous work before destroying objects that work uses.
Disconnecting suppresses subsequent replies; it does not cancel a native job.

Make sure both `messages.cc` and `messages_ffi.cc` are included in the native
build.

C ABI exports include a prefix derived from the Dart package name and configured
FFI header path, allowing different generated adapters in the same native
library. The generated ffigen configuration renames these exports to the stable
`pigeon_*` Dart binding methods. The session-based C ABI changes the exported
names and function signatures. Regenerate all C++ adapters, Dart wrappers, and
ffigen bindings together after upgrading Pigeon or changing the header path;
old and new generated files cannot be mixed.

The shared Dart callbacks keep an isolate alive only while async requests or
event subscriptions are active. They remain available for reuse and for native
notifications already queued when a subscription is canceled.

## Multiple Engines and Shutdown

Each API has its own registry of named implementations. Choose whether each
engine owns a separate implementation object or several engines deliberately
share one object. Using the same implementation class does not require sharing
the same object.

| Ownership | Native setup | Dart wrapper | Native teardown |
| --- | --- | --- | --- |
| One implementation per engine | Register each object under that engine's unique name. | Pass the same name as `messageChannelSuffix`. | Tear down only that engine's named registration. |
| One implementation shared by multiple engines | Register the shared object once, using the default name or a common name. | Each wrapper selects that same registration. | The shared service owner tears down the registration after all users finish. |

Pigeon does not discover the calling Flutter engine automatically. The name is
an application-chosen registration key, not a `FlutterEngine` object. Different
APIs can reuse an engine's name because they have independent registries.
Registering the same API and name twice is an error; tear down the existing
registration before reusing its name.
Serialize native setup and teardown for a given registration on its owning
platform thread, and wait for teardown to return before registering a replacement.

### Separate implementation objects

Register each engine's object under a unique name, even when both objects use
the same C++ implementation class:

```cpp
SetUpVideoPlayerApiFfi(api_a, "video-engine-A");
SetUpVideoPlayerApiFfi(api_b, "video-engine-B");
```

Pass the matching name when creating each engine's Dart wrapper. Subsequent
method calls use that wrapper's session and need no additional name argument:

```dart
const String engineName = 'video-engine-A';
final api = VideoPlayerApi(messageChannelSuffix: engineName);
final subscription = events(
  messageChannelSuffix: engineName,
  instanceName: 'player-7',
).listen((event) {
  // Handle this engine's player events.
});

// Run during graceful engine/isolate shutdown, after stopping new calls.
await subscription.cancel();
api.pigeonDispose();
```

A HostApi wrapper connects lazily on its first call and pins that registration
to a native session. Reusing a native registration name does not redirect an
existing wrapper to the replacement implementation; create a new Dart wrapper.
`pigeonDispose()` disconnects that wrapper, prevents further calls, and completes
its pending asynchronous requests with an error. Dispose every wrapper, including
wrappers in worker isolates, before shutting down their isolate. It is safe to
call `pigeonDispose()` more than once.

Use this shutdown order:

1. Stop starting new calls and cancel all Dart event subscriptions.
2. Call `pigeonDispose()` on every Dart HostApi wrapper for that engine.
3. Call each native `TearDown...Ffi(engine_name)` while the implementation and
   platform task runner are still available. For the example, call
   `TearDownVideoPlayerApiFfi(engine_name)` and
   `TearDownVideoPlayerEventsEventsFfi(engine_name)`.
4. Stop any remaining native asynchronous work, then release implementations
   and shut down the engine and its task runner.

Native teardown closes the registration, waits for executing API calls and
callback posts to finish, and stops remaining registered event streams. Queued
calls check the closed session before touching the implementation. Teardown
must not be invoked from one of that registration's active native API calls or
callbacks; such reentrant teardown is rejected. The cleanup sequence must run
before a forced isolate termination or hot restart: killing an isolate does not
invoke `pigeonDispose()` or unregister its native producers automatically.

### Shared implementation object

A shared service must not depend on an individual engine's messenger, texture
registry, activity, or window. For example, given an application-wide
`ComputeApi` implementation, the service owner registers it once:

```cpp
// Keep shared_api alive until StopSharedComputeService returns.
void StartSharedComputeService(ComputeApiImpl* shared_api) {
  SetUpComputeApiFfi(shared_api);
}

// Call after every engine/isolate using the service has finished its cleanup.
void StopSharedComputeService() {
  TearDownComputeApiFfi();
}
```

Each engine or worker isolate creates and disposes its own Dart wrapper:

```dart
final api = ComputeApi(); // Selects the same default native registration.

// Use api, stop starting calls, and then release this wrapper before shutdown.
api.pigeonDispose();
```

The wrappers have different sessions even though they use the same native
object. Disposing one wrapper fails only its pending requests and leaves the
other wrappers usable. Disconnecting the last session does not automatically
unregister or destroy the shared implementation; a later wrapper can still
connect until the owner calls native teardown. Do not call native setup once
per engine for this shared service, or native teardown when just one engine
detaches. Native teardown closes all sessions of that registration.

Calls execute on each caller's thread, so the shared implementation must support
concurrent calls. For thread-affine operations, use async methods and schedule
work on a service-owned task runner inside the implementation. Keep that runner
available for all users; a runner that shuts down with the first engine is
unsuitable for a service that other engines continue to use. The earlier
requirements to stop native asynchronous work and keep borrowed implementations
alive also apply.

## FFI Event Streams

When Dart FFI is enabled, `@EventChannelApi` methods generate FFI-backed Dart
`Stream`s instead of Flutter `EventChannel`s. The generated C++ FFI header
contains one stream handler and one event sink type for each event method.

```cpp
namespace my_plugin {

class VideoPlayerEventsEventsHandler
    : public PigeonVideoPlayerEventsEventsStreamHandler {
 public:
  std::optional<FlutterError> OnListen(
      const std::string& instance_name,
      std::unique_ptr<PigeonVideoPlayerEventsEventsEventSink> sink) override {
    sinks_[instance_name] = std::move(sink);
    return std::nullopt;
  }

  std::optional<FlutterError> OnCancel(
      const std::string& instance_name) override {
    sinks_.erase(instance_name);
    return std::nullopt;
  }

 private:
  std::map<std::string,
           std::unique_ptr<PigeonVideoPlayerEventsEventsEventSink>>
      sinks_;
};

void RegisterVideoPlayerEventsFfi(
    VideoPlayerEventsEventsHandler* handler,
    const std::string& engine_name) {
  SetUpVideoPlayerEventsEventsFfi(handler, engine_name);
}

}  // namespace my_plugin
```

Native code sends events by calling `sink->Success(event)`, reports stream
errors with `sink->Error(error)`, and closes the Dart stream with
`sink->EndOfStream()`. The `instanceName` argument in Dart is encoded and
passed to C++ as `instance_name`, so plugins can keep one sink per player.
`messageChannelSuffix` selects the named native registration; `instanceName`
selects a stream within that registration. Different engines may use the same
stream name when using separate registrations, but two active subscriptions
in the same registration cannot. When sharing an event handler across engines,
use a distinct `instanceName` for each subscription across all its users.
Within one isolate, keep and reuse one broadcast stream for multiple listeners.

The stream handler is borrowed and must remain valid until its named native
teardown returns. Each active Dart stream has its own session, which disconnects
when the last listener cancels. Cancel subscriptions before shutting down their
isolate, even when their HostApi wrappers have already been disposed.
`OnCancel` must stop all native producers that can use that subscription's sink
before returning, including error paths. Queued notifications are still consumed
and their buffers freed after cancellation. Closed sessions suppress later
native notifications, but native producers must still stop before their sinks
or handlers are destroyed.

`OnListen`, `OnCancel`, and cleanup during disconnect or native teardown execute
on the thread that initiates that operation. The plugin must satisfy any thread
affinity requirements of its handler and producers. Do not post cancellation and
return while producers can still access a sink that is being destroyed.

## Native regression tests

`dart test test/cpp_ffi_generator_test.dart` includes a native regression test
that generates a C++ API and FFI adapter, then compiles and runs them with
Flutter's real `StandardMessageCodec`. No Flutter engine binary, platform SDK,
CMake project, or running Flutter app is required.

Set both of the following before running the native test:

* `PIGEON_TEST_CPP_CLIENT_WRAPPER`: the absolute path to Flutter's
  `engine/src/flutter/shell/platform/common/client_wrapper` directory. This must
  contain `standard_codec.cc` and `include/flutter/standard_message_codec.h`.
* `PIGEON_TEST_CXX`: a C++17 `clang++` or `g++` executable accepting Unix-style
  compiler arguments. Alternatively, set `PIGEON_TEST_ZIG` to the `zig`
  executable; the test invokes `zig c++`. `PIGEON_TEST_CXX` takes precedence.

The native test skips with an explicit reason when these environment variables
are not configured; the other generator tests run normally. A configured but
broken compiler or client wrapper fails the native test. Generated files and
executables live in a temporary directory and are removed after the test.
Native failure messages are included in Dart test failures.

The C++ fixture in `test/testdata/cpp_ffi_native/main.cc` covers independent
named registrations, shared default HostApi and event registrations, stale
session IDs, nullable small/large integers, asynchronous duplicate and revoked
replies, native exceptions, isolated event cancellation, native teardown,
and registration/callback gate synchronization. Shared-registration checks use
different sessions for one implementation, including identical sink IDs on
different stream names. Nested calls verify that teardown rejects closing an
outer active registration and still succeeds after all calls unwind.

Threading checks invoke synchronous methods, async startup, event listen/cancel,
disconnect, and teardown on both the test thread and a worker thread. A native
implementation schedules its own asynchronous work and replies from another
thread. Teardown still waits for an active implementation call before returning.

## Limitations

The C++ FFI generator currently supports synchronous HostApi methods,
asynchronous HostApi methods, and FFI event streams. FlutterApi and ProxyApi are
not supported by this C++ FFI path.
