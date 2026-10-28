#include "mixerMacDSP.h"
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    enum { frames = 256 };
    mixerMacCrunch *state = mixerMacCrunchCreate();
    assert(state);
    AudioBufferList *buffers = calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
    assert(buffers);
    float left[frames + 1], right[frames + 1], original[frames];
    buffers->mNumberBuffers = 2;
    buffers->mBuffers[0] = (AudioBuffer){1, frames * sizeof(float), left};
    buffers->mBuffers[1] = (AudioBuffer){1, frames * sizeof(float), right};
    for (int rateIndex = 0; rateIndex < 2; ++rateIndex) {
        double rate = rateIndex ? 48000 : 44100;
        for (int i = 0; i < frames; ++i) { left[i] = original[i] = 0.2f * sinf((float)i); right[i] = 0; }
        left[frames] = 123; right[frames] = -456;
        mixerMacCrunchReset(state);
        mixerMacCrunchSet(state, 0, 0);
        mixerMacCrunchProcess(state, frames, buffers, rate);
        assert(memcmp(left, original, sizeof(original)) == 0);
        mixerMacCrunchSet(state, 1, 0);
        for (int block = 0; block < 100; ++block) {
            for (int i = 0; i < frames; ++i) { left[i] = original[i]; right[i] = 0; }
            mixerMacCrunchProcess(state, frames, buffers, rate);
        }
        assert(memcmp(left, original, sizeof(original)) != 0);
        for (int i = 0; i < frames; ++i) { assert(isfinite(left[i])); assert(right[i] == 0); }
        mixerMacCrunchSet(state, 1, 1);
        memcpy(left, original, sizeof(original));
        mixerMacCrunchProcess(state, frames, buffers, rate);
        assert(memcmp(left, original, sizeof(original)) == 0);
        mixerMacCrunchReset(state);
        mixerMacCrunchSet(state, NAN, 0);
        mixerMacCrunchProcess(state, frames, buffers, rate);
        assert(memcmp(left, original, sizeof(original)) == 0);
        assert(left[frames] == 123 && right[frames] == -456);
    }
    mixerMacCrunchSet(state, 1, 0);
    buffers->mBuffers[1].mDataByteSize = frames / 2 * sizeof(float);
    mixerMacCrunchProcess(state, frames * 4, buffers, 48000);
    for (int i = frames / 2; i < frames; ++i) assert(left[i] == original[i]);
    assert(left[frames] == 123 && right[frames] == -456);
    free(buffers);
    mixerMacCrunchDestroy(state);
    puts("PASS: CRUNCH zero/bypass bit-exact, stereo separation, finite shaping, reset, bounds and 44.1/48 kHz");
}
