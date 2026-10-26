// mixerMac additions to the Apple Audio Server Plug-in sample (see LICENSE.txt).
#ifndef MIXERMAC_LOOPBACK_H
#define MIXERMAC_LOOPBACK_H
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#define MIXERMAC_RING_FRAMES 65536u
#define MIXERMAC_DELAY_FRAMES 2048u
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio IO requires lock-free 64-bit atomics");

typedef struct {
    atomic_ullong tag;
    atomic_ullong stereo;
} mixerMacFrame;

typedef struct { mixerMacFrame frames[MIXERMAC_RING_FRAMES]; } mixerMacLoopback;

static void mixerMacLoopbackReset(mixerMacLoopback *ring) {
    for (uint32_t i = 0; i < MIXERMAC_RING_FRAMES; ++i) {
        atomic_store(&ring->frames[i].tag, UINT64_MAX);
        atomic_store(&ring->frames[i].stereo, 0);
    }
}

// Called with the HAL's already-mixed stereo output. No locks or allocations.
static void mixerMacLoopbackWrite(mixerMacLoopback *ring, int64_t start,
                                  uint32_t count, const float *audio, float gain) {
    for (uint32_t i = 0; i < count; ++i) {
        int64_t sampleTime = start + i;
        if (sampleTime < 0) continue;
        float pair[2] = {audio[i * 2] * gain, audio[i * 2 + 1] * gain};
        uint64_t packed;
        memcpy(&packed, pair, sizeof(packed));
        mixerMacFrame *frame = &ring->frames[(uint64_t)sampleTime % MIXERMAC_RING_FRAMES];
        // Sequential consistency keeps the tag/payload/tag read valid across wraparound.
        atomic_store(&frame->tag, UINT64_MAX);
        atomic_store(&frame->stereo, packed);
        atomic_store(&frame->tag, (uint64_t)sampleTime);
    }
}

static void mixerMacLoopbackRead(mixerMacLoopback *ring, int64_t start,
                                 uint32_t count, float *audio, float gain) {
    for (uint32_t i = 0; i < count; ++i) {
        int64_t sampleTime = start + i - MIXERMAC_DELAY_FRAMES;
        float pair[2] = {0, 0};
        if (sampleTime >= 0) {
            mixerMacFrame *frame = &ring->frames[(uint64_t)sampleTime % MIXERMAC_RING_FRAMES];
            uint64_t before = atomic_load(&frame->tag);
            uint64_t packed = atomic_load(&frame->stereo);
            uint64_t after = atomic_load(&frame->tag);
            if (before == (uint64_t)sampleTime && after == before) {
                memcpy(pair, &packed, sizeof(packed));
            }
        }
        audio[i * 2] = pair[0] * gain;
        audio[i * 2 + 1] = pair[1] * gain;
    }
}
#endif
