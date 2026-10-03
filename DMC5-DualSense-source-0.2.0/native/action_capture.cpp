// Local research utility: bounded, process-only WASAPI loopback, no microphone.
// API pattern: Microsoft Windows-classic-samples/Samples/ApplicationLoopback.
#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <wrl.h>
#include <cstdio>
#include <io.h>
#include <fcntl.h>
#include <thread>
#include <atomic>
static std::atomic<bool> requested_stop{false};
#include <vector>
#include <string>
#include <stdexcept>
using namespace Microsoft::WRL;
static void check(HRESULT hr) { if (FAILED(hr)) { char b[80]; sprintf_s(b,"HRESULT 0x%08lx",hr); throw std::runtime_error(b); } }
class Activation : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IActivateAudioInterfaceCompletionHandler, FtmBase> {
public:
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_PENDING;
    ComPtr<IAudioClient> client;
    ~Activation() { CloseHandle(ready); }
    HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation* op) override {
        ComPtr<IUnknown> object; HRESULT inner=E_FAIL;
        result=op->GetActivateResult(&inner,&object);
        if(SUCCEEDED(result)) result=inner;
        if(SUCCEEDED(result)) result=object.As(&client);
        SetEvent(ready); return S_OK;
    }
};
int wmain(int argc, wchar_t** argv) {
    if(argc!=4) { puts("capture_game DMC5_PID seconds(1..30) -"); return 2; }
    DWORD pid=wcstoul(argv[1],nullptr,10); int seconds=_wtoi(argv[2]);
    if(!pid || seconds<1 || seconds>30 || wcscmp(argv[3],L"-")!=0) return 2;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,pid);
    wchar_t name[32768]; DWORD length=32768;
    if(!process || !QueryFullProcessImageNameW(process,0,name,&length)) return 3;
    std::wstring path(name); auto slash=path.find_last_of(L"\\/");
    if(_wcsicmp(path.substr(slash+1).c_str(),L"DevilMayCry5.exe")) { CloseHandle(process); return 3; }
    try {
        check(CoInitializeEx(nullptr,COINIT_MULTITHREADED));
        AUDIOCLIENT_ACTIVATION_PARAMS params={};
        params.ActivationType=AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
        params.ProcessLoopbackParams.TargetProcessId=pid;
        params.ProcessLoopbackParams.ProcessLoopbackMode=PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
        PROPVARIANT prop={}; prop.vt=VT_BLOB; prop.blob.cbSize=sizeof(params); prop.blob.pBlobData=(BYTE*)&params;
        auto activation=Make<Activation>(); ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
        check(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,__uuidof(IAudioClient),&prop,activation.Get(),&operation));
        if(WaitForSingleObject(activation->ready,5000)!=WAIT_OBJECT_0) throw std::runtime_error("Activation timeout");
        check(activation->result);
        WAVEFORMATEX format={WAVE_FORMAT_PCM,2,48000,192000,4,16,0};
        check(activation->client->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_LOOPBACK|AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,0,0,&format,nullptr));
        ComPtr<IAudioCaptureClient> capture; check(activation->client->GetService(IID_PPV_ARGS(&capture)));
        std::vector<BYTE> audio; audio.reserve(seconds*192000);
        check(activation->client->Start()); fprintf(stderr,"CAPTURE_READY\n"); fflush(stderr);
        if(wcscmp(argv[3],L"-")==0) std::thread([] { if(getchar()!=EOF) requested_stop=true; }).detach();
        ULONGLONG end=GetTickCount64()+seconds*1000;
        while(!requested_stop && GetTickCount64()<end && WaitForSingleObject(process,0)==WAIT_TIMEOUT) {
            UINT32 frames; check(capture->GetNextPacketSize(&frames));
            while(frames) {
                BYTE* data; DWORD flags; check(capture->GetBuffer(&data,&frames,&flags,nullptr,nullptr));
                size_t count=frames*format.nBlockAlign;
                if(flags&AUDCLNT_BUFFERFLAGS_SILENT) audio.insert(audio.end(),count,0);
                else audio.insert(audio.end(),data,data+count);
                if(audio.size()>60*192000) throw std::runtime_error("Capture limit exceeded");
                check(capture->ReleaseBuffer(frames)); check(capture->GetNextPacketSize(&frames));
            }
            Sleep(5);
        }
        check(activation->client->Stop());
        FILE* file=stdout; _setmode(_fileno(stdout),_O_BINARY);
        DWORD size=(DWORD)audio.size(), riff=size+36, fmt=16;
        fwrite("RIFF",1,4,file); fwrite(&riff,4,1,file); fwrite("WAVEfmt ",1,8,file);
        fwrite(&fmt,4,1,file); fwrite(&format,1,16,file); fwrite("data",1,4,file);
        fwrite(&size,4,1,file); fwrite(audio.data(),1,size,file); fflush(file);
        fprintf(stderr,"Captured %lu bytes from DMC5 only\n",size);
    } catch(const std::exception& e) { fprintf(stderr,"%s\n",e.what()); CloseHandle(process); return 1; }
    CloseHandle(process); return 0;
}

