#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <filesystem>
#include <fstream>
#include <atomic>
#include <thread>
#include <cstring>
#include <string>
#include "third_party/minhook/include/MinHook.h"

struct Snapshot { DWORD magic, sequence; ULONGLONG tick; XINPUT_STATE state; };
static_assert(sizeof(Snapshot) == 32);
static std::atomic<bool> enabled{false};
static std::atomic<ULONGLONG> calls{0};
static std::atomic<ULONGLONG> input_calls{0};
static std::atomic<const Snapshot*> shared{nullptr};
using GetState = DWORD(WINAPI*)(DWORD, XINPUT_STATE*);
using GetCaps = DWORD(WINAPI*)(DWORD, DWORD, XINPUT_CAPABILITIES*);
using SetState = DWORD(WINAPI*)(DWORD, XINPUT_VIBRATION*);
static GetState original_state = nullptr, original_extended = nullptr;
static GetCaps original_caps = nullptr;
static SetState original_set = nullptr;
static GetState original_state14 = nullptr, original_extended14 = nullptr;
static GetCaps original_caps14 = nullptr;
static SetState original_set14 = nullptr;

static bool read_state(XINPUT_STATE* state) {
    const auto mapping = shared.load();
    if (!mapping || !state) return false;
    for (int attempt = 0; attempt < 3; ++attempt) {
        DWORD before = mapping->sequence; MemoryBarrier();
        if (before & 1) continue;
        Snapshot copy; std::memcpy(&copy, mapping, sizeof(copy)); MemoryBarrier();
        if (before != mapping->sequence || copy.sequence != before) continue;
        const auto now = GetTickCount64();
        if (copy.magic != 0x354D4344 || copy.tick > now || now - copy.tick > 250) return false;
        *state = copy.state; return true;
    }
    return false;
}
static DWORD state_impl(GetState original, DWORD index, XINPUT_STATE* state) {
    ++calls;
    if (enabled && index == 0) {
        if (!state) return ERROR_BAD_ARGUMENTS;
        if (!read_state(state)) { *state = {}; return ERROR_DEVICE_NOT_CONNECTED; }
        ++input_calls; return ERROR_SUCCESS;
    }
    return original ? original(index, state) : ERROR_DEVICE_NOT_CONNECTED;
}
static DWORD WINAPI get_state(DWORD index, XINPUT_STATE* state) { return state_impl(original_state, index, state); }
static DWORD WINAPI get_extended(DWORD index, XINPUT_STATE* state) { return state_impl(original_extended, index, state); }
static DWORD WINAPI get_state14(DWORD index, XINPUT_STATE* state) { return state_impl(original_state14, index, state); }
static DWORD WINAPI get_extended14(DWORD index, XINPUT_STATE* state) { return state_impl(original_extended14, index, state); }
static DWORD caps_impl(GetCaps original, DWORD index, DWORD flags, XINPUT_CAPABILITIES* caps) {
    if (enabled && index == 0) {
        XINPUT_STATE state{};
        if (!caps) return ERROR_BAD_ARGUMENTS;
        if (!read_state(&state)) return ERROR_DEVICE_NOT_CONNECTED;
        *caps = {}; caps->Type = XINPUT_DEVTYPE_GAMEPAD; caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
        caps->Gamepad.wButtons = 0xf3ff; caps->Gamepad.bLeftTrigger = caps->Gamepad.bRightTrigger = 255;
        caps->Gamepad.sThumbLX = caps->Gamepad.sThumbLY = caps->Gamepad.sThumbRX = caps->Gamepad.sThumbRY = 32767;
        return ERROR_SUCCESS;
    }
    return original ? original(index, flags, caps) : ERROR_DEVICE_NOT_CONNECTED;
}
static DWORD WINAPI get_caps(DWORD index, DWORD flags, XINPUT_CAPABILITIES* caps) { return caps_impl(original_caps,index,flags,caps); }
static DWORD WINAPI get_caps14(DWORD index, DWORD flags, XINPUT_CAPABILITIES* caps) { return caps_impl(original_caps14,index,flags,caps); }
static DWORD set_impl(SetState original, DWORD index, XINPUT_VIBRATION* vibration) {
    if (enabled && index == 0) {
        XINPUT_STATE state{};
        // Effects remain owned by the event mapper; game rumble isn't replayed.
        return read_state(&state) ? ERROR_SUCCESS : ERROR_DEVICE_NOT_CONNECTED;
    }
    return original ? original(index, vibration) : ERROR_DEVICE_NOT_CONNECTED;
}
static DWORD WINAPI set_state(DWORD index, XINPUT_VIBRATION* vibration) { return set_impl(original_set,index,vibration); }
static DWORD WINAPI set_state14(DWORD index, XINPUT_VIBRATION* vibration) { return set_impl(original_set14,index,vibration); }

void initialize_native_input(const std::filesystem::path& bridge) {
    // The worker lives for the game's process lifetime. REFramework does not
    // unload native plugins during Lua resets; no Lua state is retained here.
    std::thread([bridge] {
        std::ofstream log(bridge / L"input.log", std::ios::app);
        const auto configuration = bridge / L"native_input.ini";
        const auto mapping_name = L"Local\\DMC5DualSenseInput_" + std::to_wstring(GetCurrentProcessId());
        HANDLE mapping = nullptr;
        bool hooks = false;
        ULONGLONG status_at = 0;
        while (true) {
            bool requested = GetPrivateProfileIntW(L"input", L"enabled", 0, configuration.c_str()) == 1;
            if (requested && !hooks) {
                // Cover both XInput API versions present in DMC5. Resolve symbols,
                // never hard-coded game addresses or replacement system DLLs.
                auto library = GetModuleHandleW(L"xinput1_3.dll");
                static auto library14 = LoadLibraryExW(L"xinput1_4.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
                if (library) {
                    auto initialized = MH_Initialize();
                    if (initialized == MH_OK || initialized == MH_ERROR_ALREADY_INITIALIZED) {
                        struct Hook { FARPROC target; LPVOID detour; LPVOID* original; };
                        Hook entries[] = {
                            {GetProcAddress(library,"XInputGetState"), (LPVOID)get_state, (LPVOID*)&original_state},
                            {GetProcAddress(library,MAKEINTRESOURCEA(100)), (LPVOID)get_extended, (LPVOID*)&original_extended},
                            {GetProcAddress(library,"XInputGetCapabilities"), (LPVOID)get_caps, (LPVOID*)&original_caps},
                            {GetProcAddress(library,"XInputSetState"), (LPVOID)set_state, (LPVOID*)&original_set},
                            {library14 ? GetProcAddress(library14,"XInputGetState") : nullptr, (LPVOID)get_state14, (LPVOID*)&original_state14},
                            {library14 ? GetProcAddress(library14,MAKEINTRESOURCEA(100)) : nullptr, (LPVOID)get_extended14, (LPVOID*)&original_extended14},
                            {library14 ? GetProcAddress(library14,"XInputGetCapabilities") : nullptr, (LPVOID)get_caps14, (LPVOID*)&original_caps14},
                            {library14 ? GetProcAddress(library14,"XInputSetState") : nullptr, (LPVOID)set_state14, (LPVOID*)&original_set14}
                        };
                        bool success = true;
                        for (auto& entry : entries) {
                            if (!entry.target) { if (entry.detour == (LPVOID)get_extended || entry.detour == (LPVOID)get_extended14) continue; success=false; break; }
                            auto result=MH_CreateHook(entry.target, entry.detour, entry.original);
                            log << "Create hook: " << result << std::endl;
                            if (result != MH_OK) { success=false; break; }
                        }
                        if (success) {
                            for (auto& entry : entries) if (entry.target && MH_EnableHook(entry.target) != MH_OK) success=false;
                        }
                        if (!success) {
                            for (auto& entry : entries) if (entry.target) MH_RemoveHook(entry.target);
                            log << "Input hooks failed; original input preserved\n";
                            requested = false;
                        } else { hooks=true; log << "XInput translator ready" << std::endl; }
                    }
                }
            }
            enabled.store(requested && hooks);
            if (!mapping) {
                mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, mapping_name.c_str());
                if (mapping) {
                    auto view = (const Snapshot*)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 32);
                    if (view) shared.store(view);
                    else { CloseHandle(mapping); mapping=nullptr; }
                }
            }
            // Retain the mapping across USB reconnection. The helper reopens the
            // same mapping; timestamp expiry ensures no stuck buttons meanwhile.
            if (GetTickCount64()-status_at > 1000) {
                XINPUT_STATE state{};
                std::ofstream status(bridge / L"input_status.json");
                status << "{\"enabled\":" << (enabled ? "true" : "false")
                       << ",\"connected\":" << (read_state(&state) ? "true" : "false")
                       << ",\"calls\":" << calls << ",\"translated\":" << input_calls << "}";
                status_at=GetTickCount64();
            }
            Sleep(50);
        }
    }).detach();
}
