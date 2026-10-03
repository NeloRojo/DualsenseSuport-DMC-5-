$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'Install the free Visual Studio C++ Build Tools and Windows SDK.' }
$vcRoot = (Get-ChildItem "$vsRoot/VC/Tools/MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$kitVersion = (Get-ChildItem "$kitRoot/Lib" -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$savedInclude = $env:INCLUDE; $savedLib = $env:LIB
Push-Location $projectRoot
try {
    $env:INCLUDE = "$vcRoot/include;$kitRoot/Include/$kitVersion/ucrt;$kitRoot/Include/$kitVersion/shared;$kitRoot/Include/$kitVersion/um;$kitRoot/Include/$kitVersion/winrt"
    $env:LIB = "$vcRoot/lib/x64;$kitRoot/Lib/$kitVersion/ucrt/x64;$kitRoot/Lib/$kitVersion/um/x64"
    New-Item -ItemType Directory -Force 'build/native' | Out-Null
    $compiler = "$vcRoot/bin/Hostx64/x64/cl.exe"
    & $compiler /nologo /MT /O2 /c native/third_party/minhook/src/buffer.c native/third_party/minhook/src/hook.c native/third_party/minhook/src/trampoline.c native/third_party/minhook/src/hde/hde64.c /Fo:build/native/
    if ($LASTEXITCODE -ne 0) { throw 'MinHook build failed' }
    & $compiler /nologo /std:c++17 /EHsc /MT /O2 /LD native/autostart.cpp native/input.cpp /Fo:build/native/ build/native/buffer.obj build/native/hook.obj build/native/trampoline.obj build/native/hde64.obj /link /OUT:build/native/DMC5DualSenseAutostart.dll /IMPLIB:build/native/autostart.lib
    if ($LASTEXITCODE -ne 0) { throw 'Native launcher build failed' }
    & $compiler /nologo /std:c++17 /EHsc /MT /O2 native/input_test.cpp /Fo:build/native/input_test.obj build/native/buffer.obj build/native/hook.obj build/native/trampoline.obj build/native/hde64.obj /link /OUT:build/native/input-test.exe
    if ($LASTEXITCODE -ne 0) { throw 'Native input tests build failed' }
} finally {
    $env:INCLUDE = $savedInclude; $env:LIB = $savedLib
    Pop-Location
}
