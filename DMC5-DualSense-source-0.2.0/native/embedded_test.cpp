#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <filesystem>
#include <iostream>
int wmain(int argc,wchar_t** argv){
    if(argc!=2)return 2;
    auto lib=LoadLibraryW(argv[1]);if(!lib){std::cerr<<"Load failure "<<GetLastError();return 3;}
    auto init=reinterpret_cast<bool(*)(const void*)>(GetProcAddress(lib,"reframework_plugin_initialize"));
    auto stop=reinterpret_cast<void(*)()>(GetProcAddress(lib,"dmc5_runtime_test_stop"));
    if(!init||!stop||!init(nullptr))return 4;
    std::cout<<"Runtime host started PID="<<GetCurrentProcessId()<<std::endl;
    Sleep(90000);stop();Sleep(3000);return 0;
}
