# Building DMC5 DualSense 0.2.0 Preview

## Prerequisites

Use Windows x64, CPython **3.10 x64** (3.10.11 was used locally), free Visual Studio
2022 C++ Build Tools with the x64 compiler and Windows 10/11 SDK. REFramework/DMC5
are needed for integration testing, not compilation. MinHook source is vendored.

Run PowerShell from the repository root. No elevation is required to build.

```powershell
python -m venv .venv
./.venv/Scripts/python.exe -m pip install -r requirements-dev.txt
$pythonRoot = (& ./.venv/Scripts/python.exe -c 'import sys; print(sys.base_prefix)').Trim()
./scripts/build-embedded.ps1 -PythonRoot $pythonRoot
```

The build produces:

- `build/embedded/DMC5DualSensePlugin.dll`: the public REFramework plugin.
- `build/embedded/DMC5DualSensePluginTest.dll`: test-only variant.
- `build/embedded/DMC5RuntimeTest.exe`: test-only host, **not** shipped in releases.

Python headers define the embedding API layout; Python functions are resolved
from the bundled `python310.dll` dynamically. The native plugin itself is not
linked to a system Python installation. It starts a worker after REFramework
initialization, with isolated Python module paths and signal handlers disabled.
There is no launcher/child-process code in `native/embedded.cpp`.

## Audio files deliberately excluded

Profile JSON files describe synthetic waveforms and reference existing WAVs.
The release's `profiles/audio.dmcpack` and loose WAVs are **not** published here
because they include game-derived audio. SHA-256 fingerprints and filenames are
recorded in `docs/audio-asset-fingerprints.json` without any audio contents.

To assemble a complete playable package, provide a locally available audio pack
that you are authorized to use at `profiles/audio.dmcpack`. A reviewer can compare
its contents against the fingerprints, or use independently licensed replacements
under the referenced asset names. Replacements change the release's sound/hashes.
The DLL itself can be compiled without the pack. Do not upload original game audio
or game archives to this repository.

## Build the external helper/runtime dependencies

```powershell
./.venv/Scripts/python.exe -m PyInstaller --noconfirm DMC5DualSense.spec
./scripts/build-native.ps1
./scripts/build-action-capture.ps1
```

`build-native.ps1` produces the **development-only** launcher and optional input
test program. `build-action-capture.ps1` builds the development recorder. Neither
the launcher EXE arrangement nor recorder is included in the public preview.
PyInstaller creates `dist/DMC5DualSense`, providing the native Python extension
dependencies subsequently selected by the public packager.

## Generate the public Fluffy package

After supplying the local audio pack and compiling the plugin/runtime:

```powershell
$env:DMC5_DEPS = (Resolve-Path .venv/Lib/site-packages).Path
./.venv/Scripts/python.exe scripts/package-embedded.py artifacts/public-preview
```

The output directory must not already exist. The packager generates a clean
production menu, five gameplay Lua scripts, the reduced runtime, dependency
licenses, a source-file hash manifest and the Fluffy ZIP. It removes development
search/capture dispatch, test effects, SDK dumps, histories and unused assets.
Only production-referenced audio is included in the new `audio.dmcpack`.

The package contains compiled DLL/PYD files and internal ZIP archives for Python
modules/audio. Nexus may require manual security review; the package is not
represented as having passed Nexus scanning. No Python installation is required
on the player's PC.

## Source-only checks

```powershell
$env:PYTHONPATH = (Resolve-Path helper).Path
./.venv/Scripts/python.exe -m unittest discover -s tests
```

These tests check source syntax, all Lua scripts, profile loading, zoned trigger
encoding, session-safe hit pulses and pause behavior without playing the bundled audio or requiring a connected controller. They are not a substitute for actual DMC5 testing.

## Optional native runtime test

Create a separate test folder. Copy the generated package's `reframework` folder
into it, plus `DMC5RuntimeTest.exe` and `DMC5DualSensePluginTest.dll`. Run the host
with the absolute path to the test DLL. It runs for 90 seconds and then signals
the stop event, allowing the engine to close audio/HID. Use a `dry-run.marker`
file beside the host to disable hardware output. Do not run this hardware test
simultaneously with DMC5 or another controller-output helper.

## Reproducing the published plugin

Rebuild the public DLL from `native/embedded.cpp`, `native/input.cpp` and vendored
MinHook. See `scripts/build-embedded.ps1` for compiler/linker flags. Exact binary
hash equality is not promised across compiler/SDK versions and build timestamps.
Review the generated package against `manifest.json`; matching WAV fingerprints require the excluded local asset pack. The public runtime is generated from the
same helper source, not a separate closed-source implementation.
