#include "mixerMacDSP.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    mixerMacFIFO *fifo = mixerMacFIFOCreate();
    assert(fifo);
    float input[4096 * 2];
    float output[256 * 2];
    for (int i = 0; i < 4096; ++i) { input[i * 2] = 0.25f; input[i * 2 + 1] = -0.25f; }
    AudioBufferList in = {1, {{2, sizeof(input), input}}};
    AudioBufferList out = {1, {{2, sizeof(output), output}}};
    mixerMacFIFORender(fifo, 256, &out);
    for (int i = 0; i < 512; ++i) assert(output[i] == 0);
    mixerMacFIFOWrite(fifo, &in);
    in.mBuffers[0].mDataByteSize = sizeof(output);
    for (int block = 0; block < 4000; ++block) {
        mixerMacFIFORender(fifo, 256, &out);
        for (int i = 0; i < 256; ++i) {
            assert(output[i * 2] == 0.25f);
            assert(output[i * 2 + 1] == -0.25f);
        }
        mixerMacFIFOWrite(fifo, &in);
    }
    for (int block = 0; block < 100; ++block) mixerMacFIFORender(fifo, 256, &out);
    for (int i = 0; i < 512; ++i) assert(output[i] == 0);
    mixerMacFIFODestroy(fifo);
    puts("PASS: native bridge silence, stereo channel separation, 1,024,000 frames, wraparound, underrun");
}
