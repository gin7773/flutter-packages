// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace {
// A view starts its own engine when GTK realizes it. Use public embedding APIs;
// constructing a headless FlEngine alone does not start its Dart isolate.
class EngineView {
 public:
  ~EngineView() { Stop(); }
  void Start(const char* name, const char* bias, const char* role,
             bool separate_ui) {
    g_autoptr(FlDartProject) project = fl_dart_project_new();
    gchar* arguments[] = {const_cast<gchar*>(name), const_cast<gchar*>(bias),
                          const_cast<gchar*>(role), nullptr};
    fl_dart_project_set_dart_entrypoint_arguments(project, arguments);
    fl_dart_project_set_ui_thread_policy(
        project, separate_ui ? FL_UI_THREAD_POLICY_RUN_ON_SEPARATE_THREAD
                             : FL_UI_THREAD_POLICY_RUN_ON_PLATFORM_THREAD);
    window_ = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(window_), 320, 240);
    FlView* view = fl_view_new(project);
    gtk_container_add(GTK_CONTAINER(window_), GTK_WIDGET(view));
    gtk_widget_show_all(window_);
  }
  void Stop() {
    if (window_) {
      gtk_widget_destroy(window_);
      window_ = nullptr;
    }
  }

 private:
  GtkWidget* window_ = nullptr;
};

bool Passed(const char* file) {
  std::ifstream input(file);
  std::string status;
  input >> status;
  return status == "PASS";
}
}  // namespace

int main(int argc, char** argv) {
  const bool separate_ui = argc > 1 && std::string(argv[1]) == "--separate-ui";
  // Do not pass our thread-policy option to GTK's argument parser.
  if (!gtk_init_check(nullptr, nullptr)) {
    std::cerr
        << "GTK needs a display. Run with xvfb-run on a headless machine.\n";
    return 2;
  }
  for (const char* file :
       {"cpp_engine_A.result", "cpp_engine_A2.result", "cpp_engine_B.result"}) {
    std::filesystem::remove(file);
  }
  void* library = dlopen("libpigeon_cpp_test.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    std::cerr << dlerror() << std::endl;
    return 3;
  }
  const auto register_api =
      reinterpret_cast<int64_t (*)(const uint8_t*, size_t, int64_t)>(
          dlsym(library, "fixture_register"));
  const auto unregister_api =
      reinterpret_cast<void (*)(int64_t)>(dlsym(library, "fixture_unregister"));
  if (!register_api || !unregister_api) {
    std::cerr << "Fixture registration entrypoints are missing.\n";
    dlclose(library);
    return 4;
  }
  int64_t a =
      register_api(reinterpret_cast<const uint8_t*>("engine-a"), 8, 100);
  const int64_t b =
      register_api(reinterpret_cast<const uint8_t*>("engine-b"), 8, 200);
  if (!a || !b) {
    std::cerr << "Could not register both test APIs.\n";
    unregister_api(a);
    unregister_api(b);
    dlclose(library);
    return 5;
  }
  EngineView first;
  EngineView second;
  first.Start("engine-a", "100", "A", separate_ui);
  second.Start("engine-b", "200", "B", separate_ui);
  bool replaced = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (std::chrono::steady_clock::now() < deadline) {
    // Bound each iteration so a busy GTK queue cannot hide our timeout.
    for (int i = 0; i < 64 && g_main_context_iteration(nullptr, FALSE); ++i) {
    }
    if (!replaced && Passed("cpp_engine_A.result")) {
      // Dart has already disposed its sessions before reporting PASS.
      first.Stop();
      unregister_api(a);
      a = register_api(reinterpret_cast<const uint8_t*>("engine-a"), 8, 300);
      if (!a) break;
      first.Start("engine-a", "300", "A2", separate_ui);
      replaced = true;
    }
    if (Passed("cpp_engine_A2.result") && Passed("cpp_engine_B.result")) break;
    g_usleep(1000);
  }
  const bool passed = Passed("cpp_engine_A.result") &&
                      Passed("cpp_engine_A2.result") &&
                      Passed("cpp_engine_B.result");
  if (!passed) {
    std::cerr << "Missing PASS results; inspect cpp_engine_*.result files.\n";
  }
  unregister_api(a);
  unregister_api(b);
  first.Stop();
  second.Stop();
  // Dart's loader retains its reference; release only this runner's handle.
  dlclose(library);
  return passed ? 0 : 1;
}
