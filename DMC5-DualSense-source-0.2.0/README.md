# DMC5 DualSense Support — 0.2.0 Preview

Experimental DualSense feedback for Devil May Cry 5 on Windows: adaptive triggers,
audio haptics, lightbar effects and selected controller-speaker sounds for Nero,
Dante and Vergil. V-specific effects are not implemented yet.

This repository publishes the source for review and rebuilding. It contains **no
CAPCOM audio, game archives, compiled binaries, private gameplay recordings or
development-session logs**. Audio filenames and SHA-256 fingerprints are included
for comparison only. Software licenses do not grant rights to game audio.

## Editions

- **Public preview:** REFramework loads `DMC5DualSensePlugin.dll`. It embeds a
  private reduced CPython runtime in a worker thread inside DMC5. It launches no
  helper executable. This is not a complete C++ rewrite or a single DLL without
  dependencies. The production menu is English, with speaker volume at the top.
- **Development:** Lua event detection talks to a separate hidden Python helper.
  Audio search/capture tools and a read-only SDK bridge support development.

Both editions use the same effect definitions and output engine:

`DMC5 SDK/FSM/contact hooks → JSON bridge → effect mapper → DualSense USB HID/WASAPI`

Only one edition should be installed at a time. In-process native failures may
affect DMC5; the external helper provides better failure isolation.

## Player requirements

Windows x64, DMC5, [REFramework](https://github.com/praydog/REFramework-nightly/releases)
and a standard DualSense connected by a USB data cable. Keep the controller's USB
audio endpoint enabled for audio haptics/speaker. Steam Input is optional: enable
it if the game does not recognize your controller. The public package disables
the optional native input bridge by default. Bluetooth, DualSense Edge, gyro
camera control and multiple controllers are not validated.

Install a complete release through Fluffy Mod Manager while DMC5 is closed.
Remove the previous DualSense edition first; do not replace original game files
or `dinput8.dll`. Remove this mod through Fluffy to uninstall. Generated settings
and small error logs may remain.

## Build / review

See [BUILD.md](BUILD.md) for exact DLL and helper build commands, dependency pins,
production packaging, audio prerequisites and verification. **The DLL can be compiled without game sounds.** Rebuilding the complete playable
package requires a local audio pack, which is deliberately excluded from this repository.

Public gameplay tests confirmed controls, transformation speaker/haptics and
Demolition/The Luce triggers in DMC5. The local project passed 126 tests, including
production effect/audio preservation. That suite used private audio fixtures;
the smaller source-only checks included here need no game assets. Reconnection,
game-exit behavior and broad mod/hardware compatibility are still being tested.

Suggestions and bug reports are welcome through GitHub Issues. Include the game
and REFramework version, character, action and a short description of the problem.

## Credits and third-party licenses

Nelo supplied the design, instructions, sound selection and gameplay testing.
Most coding and compilation were assisted by Codex Astra.

Thanks to praydog for REFramework, which is required but not bundled. The code
uses CPython, HIDAPI/hidapi, sounddevice/PortAudio, CFFI/pycparser and MinHook;
see [THIRD-PARTY.txt](THIRD-PARTY.txt) and [licenses](licenses). Original game
audio belongs to CAPCOM and its respective rights holders and is not included here. This is an unofficial project.

No general redistribution license has been selected for the original mod code
yet; third-party components retain their own licenses. Public source visibility
does not change those licenses or grant rights to the game's assets.
