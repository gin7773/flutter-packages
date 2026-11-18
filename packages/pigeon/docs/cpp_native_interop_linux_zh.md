# C++ FFI：Linux 完整中文验证步骤

更新日期：2026-11-18。适用于 `gin7773/flutter-packages` 的
`work/pigeon-cpp-native-interop` 分支，Linux x64 或 arm64。

这次增加了 Linux 的生成入口、`.so` 构建和真实双引擎夹具。
之前的 `.ps1` 是 Windows PowerShell 脚本；在 Bash 中执行会出现 `param(`
语法错误，文件带 CRLF 时还会出现 `$'\r': command not found`。
只转换换行符不能解决平台差异。下面统一使用新的 `.sh` 脚本，Git 属性也固定其为 LF 换行。

## 1. 拉取代码

首次拉取：

```bash
git clone --filter=blob:none --single-branch --branch work/pigeon-cpp-native-interop \
  https://github.com/gin7773/flutter-packages.git flutter-packages-cpp-ffi-verify
cd flutter-packages-cpp-ffi-verify
```

已有这条分支的 checkout 时，保存好自己的修改后更新：

```bash
git switch work/pigeon-cpp-native-interop
git pull --ff-only origin work/pigeon-cpp-native-interop
```

在仓库根目录记录位置、提交和日志目录，然后进入 Pigeon：

```bash
task_repo=$(pwd)
task_logs=$(mktemp -d /tmp/pigeon-cpp-ffi-XXXXXX)
set -o pipefail
git rev-parse HEAD | tee "$task_logs/commit.txt"
git status --short
cd "$task_repo/packages/pigeon"
printf '日志目录：%s\n' "$task_logs"
```

分支应为 `work/pigeon-cpp-native-interop`，不是原实验分支
`pigeon/cpp_ffi_generator`。后续命令在同一个 Bash 终端执行，以保留上述变量。

## 2. 准备环境

需要完整 Flutter SDK，满足仓库的 Flutter 3.44+ / Dart 3.12+ 要求。
双引擎夹具还使用 `fl_dart_project_set_ui_thread_policy` 和
`PlatformDispatcher.engineId`；SDK 必须包含这些 API。优先使用当前稳定版。

Ubuntu/Debian 的依赖安装示例（其他发行版安装对应软件包）：

```bash
sudo apt-get update
sudo apt-get install -y git clang cmake ninja-build pkg-config \
  libgtk-3-dev libstdc++-12-dev libclang-dev llvm-dev
```

其中 clang、CMake、Ninja、GTK 等是
[Flutter 官方 Linux 环境要求](https://docs.flutter.dev/platform-integration/linux/setup)；
`libclang-dev` / `llvm-dev` 用于 ffigen 读取 C ABI 头文件。
原生代码使用 C++17，系统还需要正常可用的 C++ 编译器和线程库。

SSH、容器或没有桌面的机器另外安装虚拟显示和 Mesa 软件渲染：

```bash
sudo apt-get install -y xvfb xauth libgl1-mesa-dri
```

Flutter 已在 PATH 时，不需要显式指定 SDK 路径。否则先按实际路径配置：

```bash
export FLUTTER_ROOT="$HOME/development/flutter"
export PATH="$FLUTTER_ROOT/bin:$PATH"
```

记录环境并运行生成器检查：

```bash
flutter --version 2>&1 | tee "$task_logs/flutter-version.log"
flutter doctor -v 2>&1 | tee "$task_logs/flutter-doctor.log"
cmake --version
dart pub get
dart analyze lib test bin 2>&1 | tee "$task_logs/analyze.log"
dart test test 2>&1 | tee "$task_logs/dart-tests.log"
```

每条命令都应成功；失败时先保留错误并处理，不要继续把后续结果当成通过。
`flutter doctor -v` 的 Linux toolchain 应可用。仅运行本页独立 FFI 夹具不要求 Android 或 Windows 工具链。

## 3. 运行 Linux FFI 验证

在 `packages/pigeon` 下执行，Debug 成功后再运行 Release：

```bash
bash tool/test_cpp_native_interop.sh --configuration Debug --multi-engine \
  2>&1 | tee "$task_logs/debug.log"

bash tool/test_cpp_native_interop.sh --configuration Release --multi-engine \
  2>&1 | tee "$task_logs/release.log"
```

参数含义：

| 参数 | 是否必填 | 含义 |
| --- | --- | --- |
| `--configuration Debug` / `Release` | 否，默认 Debug | 选择原生库和 Flutter app 的构建模式；Release app 验证 Dart AOT |
| `--multi-engine` | 完整验证需要 | 增加真实 GTK 双引擎、后台 isolate 和引擎替换测试；省略时只运行原生与 Flutter 单元测试 |
| `--flutter-sdk /实际路径/flutter` | 否 | 覆盖 SDK 自动发现；默认先用 `FLUTTER_ROOT`，再从 PATH 查找 flutter |
| `--llvm-path /usr/lib/llvm-18` | 否 | 覆盖 libclang 自动发现；填包含 `lib/libclang.so` 的 LLVM 安装目录，数字按本机版本调整 |
| `--flutter-wrapper-dir /实际路径/client_wrapper` | 否 | 指定公共 C++ wrapper 源码目录，里面应有 `standard_codec.cc` 和 `include/flutter/` |

LLVM 默认先查找 `llvm-config`，再查找 `/usr/lib/llvm-*`，最后使用 ffigen 自己的默认路径。
需要覆盖路径时，两种构建模式都带上同样的参数，例如：

```bash
bash tool/test_cpp_native_interop.sh --configuration Debug --multi-engine \
  --flutter-sdk "$HOME/development/flutter" --llvm-path /usr/lib/llvm-18
```

脚本会依次执行：

1. 下载 Linux Flutter 缓存、解析依赖，生成 Dart/C++ 代码和 ffigen 绑定。库名明确为 `libpigeon_cpp_test.so`。
2. 找到 Flutter 公共 C++ wrapper。SDK 中没有源码时，从官方 Flutter 仓库按 **该 SDK 的 Git 提交** 做稀疏下载，放在忽略的 `build/cpp_native_interop/flutter-wrapper/` 下。
3. CMake 构建 `.so` 和原生测试程序，CTest 执行原生检查，然后 `flutter test` 执行 5 个 Dart/native 运行测试。
4. `--multi-engine` 创建临时 Linux app，使用 GTK 的公开 `FlView` 接口启动两个独立 Flutter 引擎。
5. A 使用偏移值 100，B 使用 200；A 退出后用相同注册名创建 A2，偏移值改为 300，期间 B 持续调用自己的实现。各引擎还通过 `Isolate.run` 验证后台 isolate。
6. 分别运行 UI 与 platform 同线程、UI 与 platform 分线程两种模式。Debug 和 Release 都运行一次，共四组双引擎测试。

没有 `DISPLAY` 和 `WAYLAND_DISPLAY` 时，脚本会自动用 `xvfb-run`。
若机器配置了无效的远程显示或 OpenGL 驱动，可明确使用软件渲染和虚拟显示：

```bash
env -u DISPLAY -u WAYLAND_DISPLAY LIBGL_ALWAYS_SOFTWARE=1 \
  bash tool/test_cpp_native_interop.sh --configuration Debug --multi-engine
```

离线机器需要预先准备 Flutter/pub 缓存，并通过 `--flutter-wrapper-dir` 提供与 SDK 匹配的源码。
wrapper 指 Flutter 仓库里的 `engine/src/flutter/shell/platform/common/client_wrapper`，
不是 Windows 专用 wrapper，也不是 Linux 的 GObject 头文件目录。

## 4. 判断结果并保留报告

| 检查 | 通过标准 |
| --- | --- |
| Dart 分析和生成器单元测试 | 无分析问题，单元测试全部通过 |
| 原生 CTest | `cpp_native_interop` 通过；当前程序执行 38 项检查 |
| Flutter 运行测试 | 5 项全部通过，没有超时或未捕获错误 |
| 真实双引擎 | 两次脚本合计打印四行 `PASS: two Linux engines, ...` |
| A / A2 / B | 每组报告都以 `PASS` 开头；同时存在的 A/B、A2/B 的 engineId 不同 |
| 调用隔离 | A 返回 100+输入，B 始终返回 200+输入，A2 返回 300+输入 |
| 生命周期 | 原生/Flutter 测试确认旧 session 失效，释放一个共享 session 不影响另一个，迟到回调不会重复完成 |

A 被销毁后，A2 的 engineId 可能复用旧 A 的标识；不要求先后创建的 A/A2 标识不同。
Release `.so` 配合 `flutter test` 不能单独证明 AOT，必须成功运行 Release 的真实 app。

报告位于：

```text
platform_tests/test_plugin/build/cpp_native_interop/reports/linux/
  Debug/platform-ui/
  Debug/separate-ui/
  Release/platform-ui/
  Release/separate-ui/
```

每个目录有 `cpp_engine_A.result`、`cpp_engine_A2.result`、`cpp_engine_B.result`。
脚本遇到非零退出码即停止，失败时也尽量保存已经产生的报告；缺少报告本身也是失败。
发生超时、崩溃、`.so` 加载失败、不同引擎结果串用时，保留 `$task_logs` 和报告目录。
这些生成物全部位于 `build/` 下，不需要提交。

## 5. 检查 web 和原有 Linux 功能

双引擎脚本成功创建临时 app 后，执行以下命令验证普通 API 仍可在 web 编译。
只修改临时 app，子 shell 退出时自动恢复其 `main.dart`：

```bash
(
  set -e
  cd "$task_repo/packages/pigeon/platform_tests/test_plugin/build/cpp_native_interop/engine_app_linux"
  task_main_backup=$(mktemp)
  cp lib/main.dart "$task_main_backup"
  trap 'cp "$task_main_backup" lib/main.dart; rm -f -- "$task_main_backup"' EXIT
  cat > lib/main.dart <<'DART'
import 'package:flutter/widgets.dart';
import 'messages.dart';

void main() {
  final api = CppTestApi();
  runApp(Text(api.runtimeType.toString(), textDirection: TextDirection.ltr));
}
DART
  flutter build web
) 2>&1 | tee "$task_logs/web.log"
```

然后从 Pigeon 目录运行原有测试入口：

```bash
cd "$task_repo/packages/pigeon"
dart run tool/test.dart --list
dart run tool/test.dart --test dart_unittests,flutter_unittests,command_line_tests,linux_unittests,linux_integration_tests \
  2>&1 | tee "$task_logs/linux-regression.log"
```

原有测试入口会运行共享生成流程，可能还要求 Android/JDK 等工具；这是额外回归检查的依赖，
不是上面的独立 FFI 夹具要求。若环境不全，记录具体缺项，不要标为通过。
生成后有代码差异也请保留。

仓库元数据和发布检查：

```bash
cd "$task_repo"
dart pub get -C script/tool
dart run script/tool/bin/flutter_plugin_tools.dart validate --packages=pigeon \
  2>&1 | tee "$task_logs/validate.log"
dart run script/tool/bin/flutter_plugin_tools.dart publish-check --packages=pigeon \
  2>&1 | tee "$task_logs/publish-check.log"
git status --short
git diff --stat
```

## 6. 当前验证边界

实现机器是 Windows，没有完整 Linux/Flutter 运行环境。本地脚本语法检查、Dart 测试和交叉编译
不能替代你在 Linux 上实际运行 GTK 双引擎、Release/AOT、web 和原有 Linux 回归测试。
请返回提交 hash、`$task_logs`、四组引擎报告和任何生成 diff。

本次本机已通过：666 项 Dart 单元测试、源码分析、仓库 validate、Bash/PowerShell 语法检查，
以及 Linux x64 `.so` 和原生测试程序的交叉编译。Linux 可执行文件尚未运行，GTK runner 尚未在 Linux 工具链下编译。

线程规则没有改变：FFI 在调用线程执行，需要平台线程的实现自行异步派发，再调用完成回调。
注册名仍由宿主与 Dart 显式约定；没有新增自动 engine 发现。

生命周期边界也没有改变：后台 `Isolate.run` 中应 await 完全部异步 FFI 调用，再 dispose 和返回。
同步 dispose 不会同步清空 Dart 队列；有排队回复时立即强制终止 isolate/engine，仍可能遗留原生缓冲区。
本次双引擎测试覆盖有序退出，不代表支持所有强制退出场景。

正式 CI 接入、长期内存/压力诊断，以及同一 Release/AOT app 内与 Platform Channel 的性能对比仍需后续完成。
更多接口说明见 [C++ native interop guide](cpp_native_interop.md)。
