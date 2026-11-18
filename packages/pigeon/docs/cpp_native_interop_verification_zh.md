# C++ FFI 首版迁移：完整中文验证步骤

更新日期：2026-11-17。本说明对应 `gin7773/flutter-packages` 的迁移分支，适用于在另一台 Windows x64 机器上验证。

**Linux 请使用 [Linux 完整中文验证步骤](cpp_native_interop_linux_zh.md)。**
本页的 `.ps1` 是 Windows PowerShell 脚本，不能交给 Bash 执行；转换换行符也不能把它变成 Linux 脚本。

- 仓库：<https://github.com/gin7773/flutter-packages>
- 分支：`work/pigeon-cpp-native-interop`
- 官方基线：`65301abeb0a77968c58c072a5560df443846e369`
- 前一项独立整数修复：`4985a359c47c467d4012881897ecd31b0aecd883`
- 本次迁移提交：`1053058f9ae2d6ba92a6634ddc8c71a650152f0c`
- 分支上还包含本说明等后续提交；验证时以实际拉取的 HEAD 为准，并记录 hash。

## 1. 从 GitHub 拉取代码

推荐在较短的目录（例如 `C:\src`）创建新的 checkout，避免原实验分支的本地修改和 Windows 长路径问题。进入该目录后执行：

```powershell
git clone -c core.longpaths=true --filter=blob:none --single-branch --branch work/pigeon-cpp-native-interop https://github.com/gin7773/flutter-packages.git flutter-packages-cpp-ffi-verify
cd flutter-packages-cpp-ffi-verify
git branch --show-current
git rev-parse HEAD
git status --short
```

分支名应为 `work/pigeon-cpp-native-interop`，`git status --short` 应无输出。这里使用的是迁移分支，不是原来的 `pigeon/cpp_ffi_generator`。

如果已经检出这条迁移分支，确认本地修改已妥善保存后，可在该 checkout 更新：

```powershell
git switch work/pigeon-cpp-native-interop
git pull --ff-only origin work/pigeon-cpp-native-interop
git rev-parse HEAD
```

SDK、生成物、DLL 和 `.dart_tool` 缓存不会随 Git 拉取，后面的脚本会重新生成和编译。无需应用之前的补丁包。

## 2. 准备验证环境

- Windows x64。
- 完整 Flutter SDK，满足当前仓库要求：Flutter 3.44+、Dart 3.12+。真实双引擎夹具使用 `set_ui_thread_policy` 和 `PlatformDispatcher.engineId`，应使用包含这些 API 的 SDK。
- Visual Studio 2022 的“使用 C++ 的桌面开发”、Windows SDK 和 CMake。
- LLVM，安装目录内需要有 `libclang.dll`。
- 使用 Visual Studio 的 Developer PowerShell；让 `flutter`、`dart`、`cmake`、`ctest` 可执行。

下面的命令从 checkout 根目录开始。设置实际 SDK 路径，确保后续命令使用同一套 Flutter/Dart，然后进入 `packages\pigeon`：

```powershell
$taskFlutterSdk = 'C:\src\flutter'
$taskLlvmDirectory = 'C:\Program Files\LLVM'
$env:PATH = "$taskFlutterSdk\bin;$env:PATH"
$taskRepo = (Get-Location).Path
$taskPigeon = Join-Path $taskRepo 'packages/pigeon'
$taskLogs = Join-Path $env:TEMP 'pigeon-cpp-ffi-verification'
New-Item -ItemType Directory -Path $taskLogs -Force > $null
Start-Transcript -Path (Join-Path $taskLogs 'cpp-ffi-verification.log') -Force
Set-Location -LiteralPath $taskPigeon
git rev-parse HEAD
Get-Command flutter, dart, cmake, ctest
flutter --version
flutter doctor -v
cmake --version
dart pub get
if ($LASTEXITCODE -ne 0) { throw 'dart pub get 失败，请保留输出并停止本轮验证。' }
dart analyze lib test bin
if ($LASTEXITCODE -ne 0) { throw 'Dart 分析失败，请保留输出。' }
dart test test
if ($LASTEXITCODE -ne 0) { throw 'Dart 单元测试失败，请保留输出。' }
```

应无分析错误，单元测试全部通过。本机目前实际结果为 666 项。
`flutter doctor -v` 中 Windows 开发所需的 Visual Studio 工具链应可用。

## 3. 运行新增验证脚本

仍在 `packages\pigeon`，复用上一步的 SDK/LLVM 路径：

```powershell
.\tool\test_cpp_native_interop.ps1 `
  -FlutterSdk $taskFlutterSdk `
  -LlvmDirectory $taskLlvmDirectory `
  -Configuration Debug -MultiEngine

.\tool\test_cpp_native_interop.ps1 `
  -FlutterSdk $taskFlutterSdk `
  -LlvmDirectory $taskLlvmDirectory `
  -Configuration Release -MultiEngine
```

脚本依次执行：生成 Dart/C++ → ffigen → MSVC 构建 DLL 和原生测试 → CTest → Flutter 的 5 个运行测试 → 创建临时 Windows app → 同进程运行两个真实 FlutterEngine。
脚本会在遇到非零退出码时停止。如果 Debug 失败，先保留该错误，再决定是否继续 Release。若 PowerShell 的本机执行策略不允许运行脚本，请按该机器允许的方式执行；验证脚本不会修改执行策略。

每个配置都分别验证 UI 与 platform 同线程、UI 与 platform 分线程。Engine A 和 B 调用同一 API 的不同实现；A 关闭后，以原名称创建 A2，B 持续调用。后台 isolate 也参与调用。Release app 才是 AOT 验证，单纯用 Release DLL 跑 Flutter 单元测试不等于 AOT 验证。

期望结果：

| 项目 | 通过标准 |
| --- | --- |
| CTest | `cpp_native_interop` 通过，当前原生测试为 38 项检查 |
| Flutter 运行测试 | 5 项全部通过，没有超时或未捕获错误 |
| 双引擎 | 出现 4 行 `PASS: two engines, ...`，覆盖两个构建配置和两个线程模式 |
| A / A2 / B 报告 | 都以 PASS 开头，同时运行的 A/B、A2/B 的 engineId 不同；已销毁的 A 的标识可以被 A2 复用 |
| 隔离 | A 得到 100+输入，B 始终得到 200+输入，替换后的 A2 得到 300+输入 |
| 生命周期 | 旧 session 失效、释放一个共享 session 不影响另一个、注销后迟到回复不会再次执行 |

脚本会把成功报告复制到：

```text
platform_tests/test_plugin/build/cpp_native_interop/reports/
  Debug/platform-ui/
  Debug/separate-ui/
  Release/platform-ui/
  Release/separate-ui/
```

遇到编译失败、DLL 加载失败、超时、崩溃、跨引擎结果串用，都应保留完整错误。不要先改用默认实例名或删除失败测试绕过问题。

## 4. 检查 web 和原有 Windows 功能

web：在上一步已成功创建临时 app 后，执行下面的完整 PowerShell 命令。它临时修改生成 app 的 `lib/main.dart`，编译完成或失败后都会恢复：

```powershell
$taskApp = Join-Path $taskPigeon 'platform_tests/test_plugin/build/cpp_native_interop/engine_app'
$taskMain = Join-Path $taskApp 'lib/main.dart'
$taskOriginalMain = [System.IO.File]::ReadAllText($taskMain)
Push-Location -LiteralPath $taskApp
try {
  @'
import 'package:flutter/widgets.dart';
import 'messages.dart';

void main() {
  final api = CppTestApi();
  runApp(Text(api.runtimeType.toString(), textDirection: TextDirection.ltr));
}
'@ | Set-Content -LiteralPath $taskMain -Encoding utf8
  flutter build web
  if ($LASTEXITCODE -ne 0) { throw 'Web 编译失败，请保留输出。' }
} finally {
  [System.IO.File]::WriteAllText($taskMain, $taskOriginalMain)
  Pop-Location
}
```

必须能编译；验证的是普通 API 仍可被 web 导入。重新运行脚本会恢复双引擎 app 的 main.dart。

回到 `packages\pigeon`，运行原有测试入口：

```powershell
Set-Location -LiteralPath $taskPigeon
dart run tool/test.dart --list
dart run tool/test.dart --test dart_unittests,flutter_unittests,command_line_tests,windows_unittests,windows_integration_tests
if ($LASTEXITCODE -ne 0) { throw '原有 Windows 测试失败，请保留输出。' }
```

它会运行原有生成流程。若共享生成流程还要求 Android/JDK 等工具，保留报错并补齐对应环境；不要把环境缺失记为测试通过。生成后如有 diff，也保留下来供核查。

在仓库根目录运行元数据和发布检查：

```powershell
Set-Location -LiteralPath $taskRepo
dart pub get -C script/tool
if ($LASTEXITCODE -ne 0) { throw '仓库工具依赖安装失败。' }
dart run script/tool/bin/flutter_plugin_tools.dart validate --packages=pigeon
if ($LASTEXITCODE -ne 0) { throw '仓库 validate 失败，请保留输出。' }
dart run script/tool/bin/flutter_plugin_tools.dart publish-check --packages=pigeon
if ($LASTEXITCODE -ne 0) { throw '仓库 publish-check 失败，请保留输出。' }
git status --short
git diff --stat
Stop-Transcript
```

## 5. 返回哪些结果

返回 `$taskLogs` 目录中的 `cpp-ffi-verification.log`、4 组引擎报告、所用 commit，以及任何生成 diff。说明失败发生在哪一步即可，不需要先自行修复生成代码。如果中途失败，单独执行 `Stop-Transcript` 结束日志记录；失败配置的原始报告可能仍留在 `engine_app/build/windows/x64/runner/Debug` 或 `Release`，也请保留。

本机已实际通过：666 项 Dart 单元测试、源码分析、38 项 Zig 编译的原生检查、10 项真实 Dart/ffigen/DLL ABI 检查、仓库 validate、格式和 PowerShell 语法检查。本机未运行 MSVC、完整 Flutter、真实双引擎、web 或 Release/AOT。

这仍是上游提交准备的首版迁移。正式 CI 接入、长时间内存/压力诊断和同一 Release/AOT app 内的 Platform Channel 性能对比尚待后续完成，当前没有宣称性能提升幅度或已满足官方合入条件。

当前生命周期边界：`Isolate.run` 返回时会显式结束 isolate，所以其中的异步 FFI 调用应全部 await 后再返回。同步 dispose 会阻止后续原生发送，但不会同步清空 Dart 队列；有排队回复时立即强制结束 isolate/engine，仍可能丢弃尚待释放的原生缓冲区。支持这种强制退出场景需要后续增加可等待的排空协议，本版不作保证。

接口用法和设计边界见 [C++ native interop guide](cpp_native_interop.md)。
