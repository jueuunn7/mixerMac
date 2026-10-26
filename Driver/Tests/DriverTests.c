#include <assert.h>
#include <stdio.h>
#include "../mixerMacAudio.c"

static void io(uint32_t operation, double sampleTime, float *buffer, uint32_t frames) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mSampleTime = sampleTime;
    cycle.mOutputTime.mSampleTime = sampleTime;
    assert(mixerMacAudio_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device,
        operation == kAudioServerPlugInIOOperationWriteMix ? kObjectID_Stream_Output : kObjectID_Stream_Input,
        1, operation, frames, &cycle, buffer, NULL) == noErr);
}

int main(void) {
    assert(mixerMacAudio_Create(NULL, kAudioServerPlugInTypeUUID) == gAudioServerPlugInDriverRef);
    AudioObjectPropertyAddress address = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef name = NULL;
    UInt32 bytes = 0;
    assert(mixerMacAudio_GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0,
        &address, 0, NULL, sizeof(name), &bytes, &name) == noErr);
    assert(CFEqual(name, CFSTR("mixerMac Audio")));
    CFRelease(name);
    for (int rate = 44100; rate <= 48000; rate += 3900) {
        assert(mixerMacAudio_PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef,
            kObjectID_Device, rate, NULL) == noErr);
        assert(mixerMacAudio_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 1) == noErr);
        float source[512 * 2], received[512 * 2];
        for (int i = 0; i < 512; ++i) {
            source[i * 2] = sinf(2 * M_PI * 1000 * i / rate) * 0.25f;
            source[i * 2 + 1] = -source[i * 2];
        }
        io(kAudioServerPlugInIOOperationReadInput, 0, received, 512);
        for (int i = 0; i < 1024; ++i) assert(received[i] == 0);
        // Exercise real HAL callbacks, including more than two full ring wraps.
        for (int64_t time = 0; time < MIXERMAC_RING_FRAMES * 3; time += 512) {
            io(kAudioServerPlugInIOOperationWriteMix, time, source, 512);
            io(kAudioServerPlugInIOOperationReadInput, time + MIXERMAC_DELAY_FRAMES, received, 512);
            for (int i = 0; i < 1024; ++i) assert(fabsf(source[i] - received[i]) < 0.00001f);
        }
        // Expired/missing audio must become silence, never replay stale ring contents.
        io(kAudioServerPlugInIOOperationReadInput, MIXERMAC_DELAY_FRAMES, received, 512);
        for (int i = 0; i < 1024; ++i) assert(received[i] == 0);
        atomic_store(&gMute_Output_Master_Value, true);
        io(kAudioServerPlugInIOOperationWriteMix, 300000, source, 512);
        io(kAudioServerPlugInIOOperationReadInput, 300000 + MIXERMAC_DELAY_FRAMES, received, 512);
        for (int i = 0; i < 1024; ++i) assert(received[i] == 0);
        atomic_store(&gMute_Output_Master_Value, false);
        assert(mixerMacAudio_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 1) == noErr);
    }
    puts("PASS: HAL factory, device name, 44.1/48 kHz, stereo loopback, ring wrap, missing-audio silence, mute, start/stop");
    return 0;
}
