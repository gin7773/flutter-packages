// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <windows.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

namespace {
std::unique_ptr<flutter::FlutterEngine> Start(const std::string& name,
                                              const std::string& bias,
                                              const std::string& role,
                                              bool separate_ui) {
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments({name, bias, role});
  project.set_ui_thread_policy(
      separate_ui ? flutter::UIThreadPolicy::RunOnSeparateThread
                  : flutter::UIThreadPolicy::RunOnPlatformThread);
  auto engine = std::make_unique<flutter::FlutterEngine>(project);
  if (!engine->Run()) return nullptr;
  return engine;
}
bool Passed(const char* file) {
  std::ifstream input(file);
  std::string status;
  input >> status;
  return status == "PASS";
}
}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t* command_line, int) {
  const bool separate_ui =
      std::wstring(command_line).find(L"--separate-ui") != std::wstring::npos;
  for (const auto* file :
       {"cpp_engine_A.result", "cpp_engine_A2.result", "cpp_engine_B.result"}) {
    std::filesystem::remove(file);
  }
  HMODULE dll = LoadLibraryW(L"pigeon_cpp_test.dll");
  if (!dll) return 2;
  const auto register_api =
      reinterpret_cast<int64_t (*)(const uint8_t*, size_t, int64_t)>(
          GetProcAddress(dll, "fixture_register"));
  const auto unregister_api = reinterpret_cast<void (*)(int64_t)>(
      GetProcAddress(dll, "fixture_unregister"));
  if (!register_api || !unregister_api) return 3;
  int64_t a =
      register_api(reinterpret_cast<const uint8_t*>("engine-a"), 8, 100);
  const int64_t b =
      register_api(reinterpret_cast<const uint8_t*>("engine-b"), 8, 200);
  auto first = Start("engine-a", "100", "A", separate_ui);
  auto second = Start("engine-b", "200", "B", separate_ui);
  if (!first || !second || !a || !b) return 4;
  bool replaced = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (std::chrono::steady_clock::now() < deadline) {
    first->ProcessMessages();
    second->ProcessMessages();
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    if (!replaced && Passed("cpp_engine_A.result")) {
      // A has explicitly disposed its Dart sessions before its engine exits.
      first->ShutDown();
      first.reset();
      unregister_api(a);
      a = register_api(reinterpret_cast<const uint8_t*>("engine-a"), 8, 300);
      first = Start("engine-a", "300", "A2", separate_ui);
      if (!first || !a) return 5;
      replaced = true;
    }
    if (Passed("cpp_engine_A2.result") && Passed("cpp_engine_B.result")) break;
    Sleep(1);
  }
  const bool passed = Passed("cpp_engine_A.result") &&
                      Passed("cpp_engine_A2.result") &&
                      Passed("cpp_engine_B.result");
  // On failure, stop native posts before forcefully stopping either isolate.
  unregister_api(a);
  unregister_api(b);
  first->ShutDown();
  second->ShutDown();
  first.reset();
  second.reset();
  // Dart's loader also owns a reference; this releases only the runner's
  // handle.
  FreeLibrary(dll);
  return passed ? 0 : 1;
}
