#include "mixerMacDSP.h"
#include <assert.h>
#include <stdio.h>

static float sampleValue(uint64_t frame) {
    return (float)((int)(frame * 1664525u % 65536u) - 32768) / 32768.0f;
}

static void writeBlock(mixerMacFIFO *fifo, float *input, unsigned count, uint64_t *written) {
    for (unsigned i = 0; i < count; ++i) {
        input[i * 2] = sampleValue(*written + i);
        input[i * 2 + 1] = -input[i * 2];
    }
    AudioBufferList in = {1, {{2, count * 2 * sizeof(float), input}}};
    mixerMacFIFOWrite(fifo, &in);
    *written += count;
}

static void callbackSizes(void) {
    const unsigned sizes[] = {128, 256, 512, 1024, 2048};
    for (unsigned a = 0; a < 5; ++a) for (unsigned b = 0; b < 5; ++b) {
        unsigned inputFrames = sizes[a], outputFrames = sizes[b];
        unsigned quantum = inputFrames > outputFrames ? inputFrames : outputFrames;
        unsigned reserve = quantum + 33 > 512 ? quantum + 33 : 512;
        mixerMacFIFO *fifo = mixerMacFIFOCreate(); assert(fifo);
        float input[2048 * 2], output[2048 * 2];
        uint64_t written = 0, rendered = 0;
        while (written < reserve) writeBlock(fifo, input, inputFrames, &written);
        AudioBufferList out = {1, {{2, outputFrames * 2 * sizeof(float), output}}};
        unsigned pending = 0;
        for (unsigned block = 0; block < 256; ++block) {
            mixerMacFIFORender(fifo, outputFrames, &out);
            for (unsigned i = 0; i < outputFrames; ++i) {
                assert(output[i * 2] == sampleValue(rendered + i));
                assert(output[i * 2 + 1] == -sampleValue(rendered + i));
            }
            rendered += outputFrames;
            pending += outputFrames;
            while (pending >= inputFrames) {
                writeBlock(fifo, input, inputFrames, &written);
                pending -= inputFrames;
            }
        }
        mixerMacFIFODestroy(fifo);
    }
    puts("PASS: 25 input/output callback combinations (128...2048 frames), exact PCM and no gaps");
}

int main(void) {
    callbackSizes();
    mixerMacFIFO *fifo = mixerMacFIFOCreate();
    assert(fifo);
    float input[256 * 2];
    float output[256 * 2];
    for (int i = 0; i < 256; ++i) { input[i * 2] = 0.25f; input[i * 2 + 1] = -0.25f; }
    AudioBufferList in = {1, {{2, sizeof(input), input}}};
    AudioBufferList out = {1, {{2, sizeof(output), output}}};
    mixerMacFIFORender(fifo, 256, &out);
    for (int i = 0; i < 512; ++i) assert(output[i] == 0);
    mixerMacFIFOWrite(fifo, &in);
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
