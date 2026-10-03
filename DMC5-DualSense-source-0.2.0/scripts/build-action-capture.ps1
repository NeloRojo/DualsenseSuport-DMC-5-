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
    & $compiler /nologo /std:c++17 /EHsc /MT /O2 native/action_capture.cpp /Fo:build/native/action_capture.obj /link /OUT:build/native/DMC5AudioCapture.exe ole32.lib mmdevapi.lib
    if ($LASTEXITCODE -ne 0) { throw "Audio capture build failed" }
} finally {
    $env:INCLUDE = $savedInclude; $env:LIB = $savedLib
    Pop-Location
}
