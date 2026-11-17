# Copyright 2013 The Flutter Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

param(
  [Parameter(Mandatory = $true)][string]$FlutterSdk,
  [Parameter(Mandatory = $true)][string]$LlvmDirectory,
  [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
  [switch]$MultiEngine
)
$ErrorActionPreference = 'Stop'
$taskPigeon = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskFlutter = Join-Path $FlutterSdk 'bin/flutter.bat'
$taskDart = Join-Path $FlutterSdk 'bin/dart.bat'
$taskPlugin = Join-Path $taskPigeon 'platform_tests/test_plugin'
$taskGenerated = Join-Path $taskPlugin 'build/cpp_native_interop'
$taskFixture = Join-Path $taskPlugin 'test/cpp_native_interop'
$taskPrevious = Get-Location
$taskPreviousPath = $env:PATH
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Executable $Arguments" }
}
try {
  Set-Location -LiteralPath $taskPigeon
  Invoke-Checked $taskFlutter @('precache', '--windows')
  Invoke-Checked $taskDart @('pub', 'get')
  Invoke-Checked $taskDart @('run', 'pigeon',
    '--input', 'test/fixtures/cpp_native_interop.dart',
    '--dart_out', 'platform_tests/test_plugin/build/cpp_native_interop/messages.dart',
    '--cpp_header_out', 'platform_tests/test_plugin/build/cpp_native_interop/messages.h',
    '--cpp_source_out', 'platform_tests/test_plugin/build/cpp_native_interop/messages.cpp',
    '--cpp_namespace', 'cpp_test', '--cpp_use_ffi',
    '--cpp_ffi_library_name', 'pigeon_cpp_test.dll', '--package_name', 'cpp_test')
  $taskLlvmYaml = $LlvmDirectory.Replace('\', '/').Replace("'", "''")
  Add-Content -LiteralPath "$taskGenerated/messages.ffigen.yaml" -Value "`nllvm-path:`n  - '$taskLlvmYaml'"
  Invoke-Checked $taskDart @('run', 'ffigen', '--config', "$taskGenerated/messages.ffigen.yaml")
  $taskWrapper = Join-Path $FlutterSdk 'bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper'
  if (!(Test-Path -LiteralPath "$taskWrapper/standard_codec.cc")) {
    throw "Flutter Windows wrapper not found: $taskWrapper"
  }
  Invoke-Checked 'cmake' @('-S', $taskFixture, '-B', "$taskGenerated/native", '-A', 'x64',
    "-DFLUTTER_WRAPPER_DIR=$taskWrapper", "-DGENERATED_DIR=$taskGenerated")
  Invoke-Checked 'cmake' @('--build', "$taskGenerated/native", '--config', $Configuration)
  Invoke-Checked 'ctest' @('--test-dir', "$taskGenerated/native", '-C', $Configuration, '--output-on-failure')
  $env:PATH = "$taskGenerated/native/$Configuration;$taskPreviousPath"
  Set-Location -LiteralPath $taskPlugin
  Invoke-Checked $taskFlutter @('pub', 'get')
  Copy-Item -LiteralPath "$taskFixture/runtime_test.dart.tmpl" -Destination "$taskGenerated/runtime_test.dart" -Force
  Invoke-Checked $taskFlutter @('test', 'build/cpp_native_interop/runtime_test.dart', '--reporter', 'expanded')

  if ($MultiEngine) {
    $taskApp = Join-Path $taskGenerated 'engine_app'
    if (!(Test-Path -LiteralPath "$taskApp/pubspec.yaml")) {
      Invoke-Checked $taskFlutter @('create', '--platforms=windows,web', '--project-name=cpp_engine_test', $taskApp)
    }
    Set-Location -LiteralPath $taskApp
    Invoke-Checked $taskFlutter @('pub', 'add', 'ffi')
    Copy-Item -LiteralPath "$taskGenerated/messages.dart", "$taskGenerated/messages.native_interop.dart", "$taskGenerated/messages.cpp_ffi.dart" -Destination "$taskApp/lib" -Force
    Copy-Item -LiteralPath "$taskFixture/multi_engine.dart.tmpl" -Destination "$taskApp/lib/main.dart" -Force
    Copy-Item -LiteralPath "$taskFixture/multi_engine_main.cpp" -Destination "$taskApp/windows/runner/main.cpp" -Force
    Invoke-Checked $taskFlutter @('build', 'windows', "--$($Configuration.ToLowerInvariant())")
    $taskBundle = Join-Path $taskApp "build/windows/x64/runner/$Configuration"
    Copy-Item -LiteralPath "$taskGenerated/native/$Configuration/pigeon_cpp_test.dll" -Destination $taskBundle -Force
    foreach ($taskPolicy in @('--platform-ui', '--separate-ui')) {
      $taskProcess = Start-Process -FilePath "$taskBundle/cpp_engine_test.exe" -ArgumentList $taskPolicy -WorkingDirectory $taskBundle -WindowStyle Hidden -PassThru
      if (!$taskProcess.WaitForExit(60000)) {
        Stop-Process -Id $taskProcess.Id
        throw "Two-engine test timed out: $Configuration $taskPolicy"
      }
      $taskReports = "$taskBundle/cpp_engine_A.result", "$taskBundle/cpp_engine_A2.result", "$taskBundle/cpp_engine_B.result"
      Get-Content -LiteralPath $taskReports
      if ($taskProcess.ExitCode -ne 0) { throw "Two-engine test failed: $Configuration $taskPolicy ($($taskProcess.ExitCode))" }
      $taskSavedReports = Join-Path $taskGenerated "reports/$Configuration/$($taskPolicy.TrimStart('-'))"
      New-Item -ItemType Directory -Path $taskSavedReports -Force > $null
      Copy-Item -LiteralPath $taskReports -Destination $taskSavedReports -Force
      Write-Output "PASS: two engines, $Configuration, $taskPolicy"
    }
  }
} finally {
  $env:PATH = $taskPreviousPath
  Set-Location -LiteralPath $taskPrevious
}
