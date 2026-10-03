param([string]$PythonRoot='')
if (!$PythonRoot) {$PythonRoot=(& python -c 'import sys;print(sys.base_prefix)').Trim()}
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsRoot=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vsRoot){throw 'Visual Studio C++ Build Tools required'}
$vcRoot=(Get-ChildItem "$vsRoot/VC/Tools/MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$kitRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$kitVersion=(Get-ChildItem "$kitRoot/Lib" -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$savedInclude=$env:INCLUDE;$savedLib=$env:LIB
Push-Location $projectRoot
try {
 $env:INCLUDE="$PythonRoot/include;$vcRoot/include;$kitRoot/Include/$kitVersion/ucrt;$kitRoot/Include/$kitVersion/shared;$kitRoot/Include/$kitVersion/um;$kitRoot/Include/$kitVersion/winrt"
 $env:LIB="$vcRoot/lib/x64;$kitRoot/Lib/$kitVersion/ucrt/x64;$kitRoot/Lib/$kitVersion/um/x64"
 New-Item -ItemType Directory -Force build/embedded | Out-Null
 $compiler="$vcRoot/bin/Hostx64/x64/cl.exe"
 & $compiler /nologo /MT /O2 /c native/third_party/minhook/src/buffer.c native/third_party/minhook/src/hook.c native/third_party/minhook/src/trampoline.c native/third_party/minhook/src/hde/hde64.c /Fo:build/embedded/
 if($LASTEXITCODE){throw 'MinHook compilation failed'}
 $objects=@('build/embedded/buffer.obj','build/embedded/hook.obj','build/embedded/trampoline.obj','build/embedded/hde64.obj')
 & $compiler /nologo /std:c++17 /EHsc /MT /O2 /LD native/embedded.cpp native/input.cpp /Fo:build/embedded/ @objects /link /NODEFAULTLIB:python310.lib /OUT:build/embedded/DMC5DualSensePlugin.dll /IMPLIB:build/embedded/plugin.lib
 if($LASTEXITCODE){throw 'Plugin compilation failed'}
 & $compiler /nologo /std:c++17 /EHsc /MT /O2 /DDMC5_RUNTIME_TEST /LD native/embedded.cpp native/input.cpp /Fo:build/embedded/ @objects /link /NODEFAULTLIB:python310.lib /OUT:build/embedded/DMC5DualSensePluginTest.dll /IMPLIB:build/embedded/plugin-test.lib
 if($LASTEXITCODE){throw 'Test plugin compilation failed'}
 & $compiler /nologo /std:c++17 /EHsc /MT /O2 native/embedded_test.cpp /Fo:build/embedded/ /link /OUT:build/embedded/DMC5RuntimeTest.exe
 if($LASTEXITCODE){throw 'Test host compilation failed'}
}finally{$env:INCLUDE=$savedInclude;$env:LIB=$savedLib;Pop-Location}
