#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <exdisp.h>
#include <shldisp.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "uuid.lib")
using Microsoft::WRL::ComPtr;
void initialize_native_input(const std::filesystem::path& bridge);

// Explorer launches the helper outside Steam's inherited input hooks.
// Steam Input stays active in DMC5. No elevation or persistent task is created.
static HRESULT launch_from_desktop(const std::filesystem::path& executable,
                                  const std::wstring& arguments,
                                  const std::filesystem::path& directory) {
    ComPtr<IShellWindows> windows;
    HRESULT hr = CoCreateInstance(CLSID_ShellWindows, nullptr, CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(&windows));
    if (FAILED(hr)) return hr;
    VARIANT location{}; location.vt = VT_I4; location.lVal = CSIDL_DESKTOP;
    VARIANT empty{}; long hwnd = 0;
    ComPtr<IDispatch> desktop;
    hr = windows->FindWindowSW(&location, &empty, SWC_DESKTOP, &hwnd, SWFO_NEEDDISPATCH, &desktop);
    if (FAILED(hr) || !desktop) return FAILED(hr) ? hr : E_FAIL;
    ComPtr<IServiceProvider> services;
    hr = desktop.As(&services); if (FAILED(hr)) return hr;
    ComPtr<IShellBrowser> browser;
    hr = services->QueryService(SID_STopLevelBrowser, IID_PPV_ARGS(&browser)); if (FAILED(hr)) return hr;
    ComPtr<IShellView> view;
    hr = browser->QueryActiveShellView(&view); if (FAILED(hr)) return hr;
    ComPtr<IShellFolderViewDual> folder;
    ComPtr<IDispatch> background;
    hr = view->GetItemObject(SVGIO_BACKGROUND, IID_PPV_ARGS(&background)); if (FAILED(hr)) return hr;
    hr = background.As(&folder); if (FAILED(hr)) return hr;
    ComPtr<IDispatch> application;
    hr = folder->get_Application(&application); if (FAILED(hr)) return hr;
    ComPtr<IShellDispatch2> shell;
    hr = application.As(&shell); if (FAILED(hr)) return hr;
    BSTR file = SysAllocString(executable.c_str());
    VARIANT args{}; args.vt = VT_BSTR; args.bstrVal = SysAllocString(arguments.c_str());
    VARIANT cwd{}; cwd.vt = VT_BSTR; cwd.bstrVal = SysAllocString(directory.c_str());
    VARIANT verb{}; verb.vt = VT_BSTR; verb.bstrVal = SysAllocString(L"open");
    VARIANT show{}; show.vt = VT_I4; show.lVal = SW_HIDE;
    if (!file || !args.bstrVal || !cwd.bstrVal || !verb.bstrVal) hr = E_OUTOFMEMORY;
    else hr = shell->ShellExecute(file, args, cwd, verb, show);
    SysFreeString(file); VariantClear(&args); VariantClear(&cwd); VariantClear(&verb);
    return hr;
}

struct REFrameworkPluginInitializeParam;
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam*) {
    wchar_t buffer[32768];
    if (!GetModuleFileNameW(nullptr, buffer, 32768)) return false;
    const auto game = std::filesystem::path(buffer).parent_path();
    if (_wcsicmp(std::filesystem::path(buffer).filename().c_str(), L"DevilMayCry5.exe") != 0) return false;
    const auto bridge = game / L"reframework" / L"data" / L"dmc5_dualsense";
    const auto runtime = bridge / L"runtime";
    const auto executable = runtime / L"DMC5DualSense.exe";
    std::ofstream log(bridge / L"autostart.log", std::ios::app);
    if (!std::filesystem::is_regular_file(executable)) { log << "Helper executable missing\n"; return false; }
    const auto arguments = L"--audio-haptics --speaker --bridge \"" + bridge.wstring()
        + L"\" --parent-pid " + std::to_wstring(GetCurrentProcessId());
    HRESULT result = E_FAIL;
    // A separate COM apartment leaves the game's initialization untouched.
    std::thread worker([&] {
        auto initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (FAILED(initialized)) { result = initialized; return; }
        result = launch_from_desktop(executable, arguments, runtime);
        CoUninitialize();
    });
    worker.join();
    if (SUCCEEDED(result)) initialize_native_input(bridge);
    log << "Desktop helper launch for game " << GetCurrentProcessId() << "; HRESULT " << std::hex << result << '\n';
    return SUCCEEDED(result);
}
