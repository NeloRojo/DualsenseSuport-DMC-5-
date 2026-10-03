#include "input.cpp"
#include <iostream>
static DWORD WINAPI fallback(DWORD, XINPUT_STATE* state) { state->dwPacketNumber=999; return ERROR_SUCCESS; }
int main() {
    Snapshot fixture{}; XINPUT_STATE state{};
    shared.store(&fixture); enabled.store(true);
    if (get_state(0,&state)!=ERROR_DEVICE_NOT_CONNECTED) return 1;
    fixture.magic=0x354D4344; fixture.sequence=2; fixture.tick=GetTickCount64();
    fixture.state.dwPacketNumber=42; fixture.state.Gamepad.wButtons=XINPUT_GAMEPAD_A;
    if (get_state(0,&state)!=ERROR_SUCCESS || state.dwPacketNumber!=42 || state.Gamepad.wButtons!=XINPUT_GAMEPAD_A) return 2;
    fixture.sequence=3;
    if (get_state(0,&state)!=ERROR_DEVICE_NOT_CONNECTED) return 3;
    fixture.sequence=4; fixture.tick=GetTickCount64()-1000;
    if (get_state(0,&state)!=ERROR_DEVICE_NOT_CONNECTED) return 4;
    fixture.magic=0; fixture.tick=GetTickCount64();
    if (get_state(0,&state)!=ERROR_DEVICE_NOT_CONNECTED) return 5;
    fixture.magic=0x354D4344;
    if (get_state(0,&state)!=ERROR_SUCCESS) return 6;
    original_state=fallback; enabled.store(false);
    if (get_state(0,&state)!=ERROR_SUCCESS || state.dwPacketNumber!=999) return 7;
    enabled.store(true);
    if (get_state(1,&state)!=ERROR_SUCCESS || state.dwPacketNumber!=999) return 8;
    std::cout << "Native reader freshness, disconnect, reconnect and passthrough passed\n";
    return 0;
}
