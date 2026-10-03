// Private CPython runtime hosted inside DMC5; no child process or console.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <Python.h>
#include <filesystem>
#include <fstream>
#include <thread>
#include <atomic>
#include <stdexcept>
#include <vector>
#include <string>
namespace fs=std::filesystem;
void initialize_native_input(const fs::path& bridge);
static HANDLE stop_event=nullptr;
static std::atomic<bool> started{false};
template<class T> static T symbol(HMODULE lib,const char* name) {
    auto p=GetProcAddress(lib,name);if(!p)throw std::runtime_error(name);
    return reinterpret_cast<T>(p);
}
static void worker(fs::path game) {
    const auto bridge=game/L"reframework"/L"data"/L"dmc5_dualsense";
    const auto runtime=bridge/L"runtime";
    std::ofstream log(bridge/L"plugin.log",std::ios::app);
    try {
        // Never reuse an interpreter owned by another mod.
        if(GetModuleHandleW(L"python310.dll"))throw std::runtime_error("Another Python 3.10 runtime is already loaded; plugin disabled");
        AddDllDirectory(runtime.c_str());
        auto lib=LoadLibraryExW((runtime/L"python310.dll").c_str(),nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if(!lib)throw std::runtime_error("Cannot load private Python runtime");
        auto init_config=symbol<decltype(&PyConfig_InitIsolatedConfig)>(lib,"PyConfig_InitIsolatedConfig");
        auto set_string=symbol<decltype(&PyConfig_SetString)>(lib,"PyConfig_SetString");
        auto append=symbol<decltype(&PyWideStringList_Append)>(lib,"PyWideStringList_Append");
        auto initialize=symbol<decltype(&Py_InitializeFromConfig)>(lib,"Py_InitializeFromConfig");
        auto clear=symbol<decltype(&PyConfig_Clear)>(lib,"PyConfig_Clear");
        auto run=symbol<decltype(&PyRun_SimpleStringFlags)>(lib,"PyRun_SimpleStringFlags");
        PyConfig config;init_config(&config);
        config.install_signal_handlers=0;config.write_bytecode=0;config.parse_argv=0;
        config.module_search_paths_set=1;
        auto check=[](PyStatus status){if(status._type!=0)throw std::runtime_error(status.err_msg?status.err_msg:"Python configuration failed");};
        try {
            check(set_string(&config,&config.home,runtime.c_str()));
            for(auto path:{runtime/L"app.zip",runtime/L"python310.zip",runtime})check(append(&config.module_search_paths,path.c_str()));
            std::vector<std::wstring> args={L"DMC5DualSensePlugin",L"--audio-haptics",L"--speaker",L"--bridge",bridge.wstring(),L"--profile",(runtime/L"profiles"/L"nero.json").wstring()};
#ifdef DMC5_RUNTIME_TEST
            if(fs::exists(game/L"dry-run.marker"))args.push_back(L"--dry-run");
#endif
            for(auto& arg:args)check(append(&config.argv,arg.c_str()));
            check(initialize(&config));
        }catch(...){clear(&config);throw;}
        clear(&config);
        initialize_native_input(bridge);
        log<<"Private runtime initialized in process "<<GetCurrentProcessId()<<"\n";log.flush();
        // Entry handles exceptions and closes HID/audio on the stop event.
        int result=run("import embedded_entry; embedded_entry.run()",nullptr);
        log<<"Engine stopped; result "<<result<<"\n";
        // Do not finalize/unload extension modules while audio callbacks may unwind.
        // All allocations are reclaimed with the host process.
    }catch(const std::exception& error){log<<"Plugin disabled: "<<error.what()<<"\n";}
}
struct REFrameworkPluginInitializeParam;
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam*) {
    wchar_t buffer[32768];if(!GetModuleFileNameW(nullptr,buffer,32768))return false;
    fs::path exe(buffer);
    if(_wcsicmp(exe.filename().c_str(),L"DevilMayCry5.exe")!=0
#ifdef DMC5_RUNTIME_TEST
       && _wcsicmp(exe.filename().c_str(),L"DMC5RuntimeTest.exe")!=0
#endif
    )return false;
    auto bridge=exe.parent_path()/L"reframework"/L"data"/L"dmc5_dualsense";
    if(!fs::is_regular_file(bridge/L"runtime"/L"app.zip"))return false;
    if(started.exchange(true))return true;
    HMODULE own;GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&reframework_plugin_initialize),&own);
    auto name=L"Local\\DMC5DualSenseStop_"+std::to_wstring(GetCurrentProcessId());
    stop_event=CreateEventW(nullptr,TRUE,FALSE,name.c_str());if(!stop_event)return false;
    std::thread(worker,exe.parent_path()).detach();return true;
}
#ifdef DMC5_RUNTIME_TEST
extern "C" __declspec(dllexport) void dmc5_runtime_test_stop(){if(stop_event)SetEvent(stop_event);}
#endif
