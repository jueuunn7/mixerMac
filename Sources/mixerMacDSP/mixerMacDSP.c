#include "mixerMacDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include <time.h>

#define CAPACITY 65536u
#define TARGET 4096u
#define SINC_TAPS 64u
#define SINC_PHASES 1024u
#define CLOCK_DEADBAND 512.0
struct mixerMacFIFO {
    float left[CAPACITY], right[CAPACITY];
    atomic_ullong read, write;
    double fraction; // only touched by the single output render callback
    bool primed;
    _Atomic(float) targetPan;
    float renderedPan; // render-callback owned; slew prevents zipper noise
    _Atomic(float) targetMasterPan;
    float renderedMasterPan;
    _Atomic(float) targetMasterWidth;
    float renderedMasterWidth;
    float coefficients[SINC_PHASES][SINC_TAPS];
};

mixerMacFIFO *mixerMacFIFOCreate(void) {
    mixerMacFIFO *fifo = calloc(1, sizeof(mixerMacFIFO));
    if (!fifo) return NULL;
    atomic_init(&fifo->targetPan, 0);
    atomic_init(&fifo->targetMasterPan, 0);
    atomic_init(&fifo->targetMasterWidth, 1);
    fifo->renderedMasterWidth = 1;
    // Precompute the interpolation bank off the audio callback. A 64-tap
    // Blackman-windowed sinc preserves high-frequency amplitude during drift
    // correction, unlike the previous two-point linear interpolation.
    for (uint32_t phase = 0; phase < SINC_PHASES; ++phase) {
        double sum = 0;
        for (uint32_t tap = 0; tap < SINC_TAPS; ++tap) {
            double x = (double)tap - 31.0 - (double)phase / SINC_PHASES;
            double sinc = fabs(x) < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x);
            double window = 0.42 + 0.5 * cos(M_PI * x / 32.0) + 0.08 * cos(2 * M_PI * x / 32.0);
            double coefficient = sinc * window;
            fifo->coefficients[phase][tap] = (float)coefficient;
            sum += coefficient;
        }
        for (uint32_t tap = 0; tap < SINC_TAPS; ++tap) fifo->coefficients[phase][tap] /= (float)sum;
    }
    return fifo;
}
void mixerMacFIFODestroy(mixerMacFIFO *fifo) { free(fifo); }
void mixerMacFIFOSetPan(mixerMacFIFO *fifo, float pan) {
    if (fifo) atomic_store_explicit(&fifo->targetPan,
        isfinite(pan) ? fmaxf(-1, fminf(1, pan)) : 0, memory_order_relaxed);
}
void mixerMacFIFOSetMasterPan(mixerMacFIFO *fifo, float pan) {
    if (fifo) atomic_store_explicit(&fifo->targetMasterPan,
        isfinite(pan) ? fmaxf(-1, fminf(1, pan)) : 0, memory_order_relaxed);
}
void mixerMacFIFOSetMasterWidth(mixerMacFIFO *fifo, float width) {
    if (fifo) atomic_store_explicit(&fifo->targetMasterWidth,
        isfinite(width) ? fmaxf(0, fminf(2, width)) : 1, memory_order_relaxed);
}

void mixerMacFIFOWrite(mixerMacFIFO *fifo, const AudioBufferList *buffers) {
    if (!fifo || !buffers || !buffers->mNumberBuffers) return;
    const AudioBuffer *first = &buffers->mBuffers[0];
    const AudioBuffer *second = &buffers->mBuffers[buffers->mNumberBuffers > 1 ? 1 : 0];
    if (!first->mData || !second->mData || !first->mNumberChannels || !second->mNumberChannels) return;
    uint32_t strideL = first->mNumberChannels, strideR = second->mNumberChannels;
    uint32_t frames = first->mDataByteSize / sizeof(float) / strideL;
    uint32_t framesR = second->mDataByteSize / sizeof(float) / strideR;
    if (framesR < frames) frames = framesR;
    const float *left = first->mData, *right = second->mData;
    uint32_t offsetR = buffers->mNumberBuffers == 1 && strideL > 1 ? 1 : 0;
    uint64_t write = atomic_load_explicit(&fifo->write, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&fifo->read, memory_order_acquire);
    // Drop new samples on overflow; the producer never overwrites unread data.
    // Retain enough already-consumed samples for the sinc's left wing. This
    // reserve also prevents the producer overwriting history at a ring wrap.
    uint64_t freeFrames = (CAPACITY - SINC_TAPS) - (write - read);
    if (frames > freeFrames) frames = (uint32_t)freeFrames;
    for (uint32_t i = 0; i < frames; ++i) {
        fifo->left[(write + i) % CAPACITY] = left[i * strideL];
        fifo->right[(write + i) % CAPACITY] = right[i * strideR + offsetR];
    }
    atomic_store_explicit(&fifo->write, write + frames, memory_order_release);
}

void mixerMacFIFORender(mixerMacFIFO *fifo, uint32_t frames, AudioBufferList *buffers) {
    if (!fifo || !buffers || !buffers->mNumberBuffers) return;
    uint64_t read = atomic_load_explicit(&fifo->read, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&fifo->write, memory_order_acquire);
    uint64_t available = write - read;
    if (!fifo->primed && available >= TARGET) fifo->primed = true;
    // Ignore ordinary callback batching rather than continually resampling
    // equal-rate audio. Actual sustained clock drift is corrected slowly.
    double error = (double)available - TARGET;
    double correction = fabs(error) <= CLOCK_DEADBAND ? 0 : error - copysign(CLOCK_DEADBAND, error);
    double step = 1 + fmax(-0.001, fmin(0.001, correction / (TARGET * 2000.0)));
    float targetPan = atomic_load_explicit(&fifo->targetPan, memory_order_relaxed);
    float targetMasterPan = atomic_load_explicit(&fifo->targetMasterPan, memory_order_relaxed);
    float targetMasterWidth = atomic_load_explicit(&fifo->targetMasterWidth, memory_order_relaxed);
    for (uint32_t i = 0; i < frames; ++i) {
        float pair[2] = {0, 0};
        if (fifo->primed && read + 32 < write) {
            uint64_t a = read % CAPACITY;
            pair[0] = fifo->left[a]; pair[1] = fifo->right[a];
            uint32_t phase = (uint32_t)(fifo->fraction * SINC_PHASES);
            if (phase > 0) {
                double l = pair[0], r = pair[1];
                for (uint32_t tap = 0; tap < SINC_TAPS; ++tap) {
                    int64_t index = (int64_t)read + tap - 31;
                    float left = index >= 0 ? fifo->left[(uint64_t)index % CAPACITY] : 0;
                    float right = index >= 0 ? fifo->right[(uint64_t)index % CAPACITY] : 0;
                    // This form also preserves DC exactly, regardless of the
                    // coefficient bank's floating-point normalization error.
                    l += (left - pair[0]) * fifo->coefficients[phase][tap];
                    r += (right - pair[1]) * fifo->coefficients[phase][tap];
                }
                pair[0] = (float)l; pair[1] = (float)r;
            }
            fifo->fraction += step;
            uint32_t consumed = (uint32_t)fifo->fraction;
            read += consumed;
            fifo->fraction -= consumed;
        } else {
            fifo->primed = false;
            fifo->fraction = 0;
        }
        // Stereo balance: centre is unity on both sides, with no hidden
        // equal-power attenuation or stereo-to-mono fold-down. Slew over
        // about 5 ms so live adjustments do not create an abrupt gain step.
        float panDelta = targetPan - fifo->renderedPan;
        fifo->renderedPan += fmaxf(-1.0f / 240, fminf(1.0f / 240, panDelta));
        float masterDelta = targetMasterPan - fifo->renderedMasterPan;
        fifo->renderedMasterPan += fmaxf(-1.0f / 240, fminf(1.0f / 240, masterDelta));
        pair[0] *= fminf(1, 1 - fifo->renderedPan);
        pair[1] *= fminf(1, 1 + fifo->renderedPan);
        float widthDelta = targetMasterWidth - fifo->renderedMasterWidth;
        fifo->renderedMasterWidth += fmaxf(-1.0f / 240, fminf(1.0f / 240, widthDelta));
        if (fifo->renderedMasterWidth != 1) {
            float mid = (pair[0] + pair[1]) * 0.5f;
            float side = (pair[0] - pair[1]) * (0.5f * fifo->renderedMasterWidth);
            pair[0] = mid + side;
            pair[1] = mid - side;
        }
        pair[0] *= fminf(1, 1 - fifo->renderedMasterPan);
        pair[1] *= fminf(1, 1 + fifo->renderedMasterPan);
        for (uint32_t buffer = 0; buffer < buffers->mNumberBuffers; ++buffer) {
            AudioBuffer *out = &buffers->mBuffers[buffer];
            if (!out->mData || out->mDataByteSize < (i + 1) * out->mNumberChannels * sizeof(float)) continue;
            float *data = out->mData;
            for (uint32_t channel = 0; channel < out->mNumberChannels; ++channel) {
                uint32_t stereoChannel = buffers->mNumberBuffers > 1 ? buffer : channel;
                data[i * out->mNumberChannels + channel] = pair[stereoChannel % 2];
            }
        }
    }
    atomic_store_explicit(&fifo->read, read, memory_order_release);
}

#define ANALYSIS_FRAMES 4096u
struct mixerMacAnalysis {
    atomic_flag busy;
    float left[ANALYSIS_FRAMES], right[ANALYSIS_FRAMES];
    uint32_t index, count;
    float peak, leftPeak, rightPeak;
    double rate;
    uint64_t sequence, lastWrite;
};

mixerMacAnalysis *mixerMacAnalysisCreate(void) {
    mixerMacAnalysis *analysis = calloc(1, sizeof(mixerMacAnalysis));
    if (analysis) atomic_flag_clear(&analysis->busy);
    return analysis;
}
void mixerMacAnalysisDestroy(mixerMacAnalysis *analysis) { free(analysis); }

void mixerMacAnalysisPush(mixerMacAnalysis *analysis, const AudioBufferList *buffers, double rate) {
    if (!analysis || !buffers || !buffers->mNumberBuffers) return;
    const AudioBuffer *first = &buffers->mBuffers[0];
    const AudioBuffer *second = &buffers->mBuffers[buffers->mNumberBuffers > 1 ? 1 : 0];
    if (!first->mData || !second->mData || !first->mNumberChannels || !second->mNumberChannels) return;
    // If the UI is taking a snapshot, discard this analysis packet instead of
    // waiting on the audio callback. Playback uses the independent FIFO above.
    if (atomic_flag_test_and_set_explicit(&analysis->busy, memory_order_acquire)) return;
    uint32_t strideL = first->mNumberChannels, strideR = second->mNumberChannels;
    uint32_t frames = first->mDataByteSize / sizeof(float) / strideL;
    uint32_t rightFrames = second->mDataByteSize / sizeof(float) / strideR;
    if (rightFrames < frames) frames = rightFrames;
    uint32_t offset = buffers->mNumberBuffers == 1 && strideL > 1 ? 1 : 0;
    const float *left = first->mData, *right = second->mData;
    float peak = analysis->peak;
    float leftPeak = analysis->leftPeak, rightPeak = analysis->rightPeak;
    for (uint32_t i = 0; i < frames; ++i) {
        float l = left[i * strideL], r = right[i * strideR + offset];
        analysis->left[analysis->index] = l;
        analysis->right[analysis->index] = r;
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));
        leftPeak = fmaxf(leftPeak, fabsf(l));
        rightPeak = fmaxf(rightPeak, fabsf(r));
        analysis->index = (analysis->index + 1) & (ANALYSIS_FRAMES - 1);
    }
    analysis->count = analysis->count + frames > ANALYSIS_FRAMES ? ANALYSIS_FRAMES : analysis->count + frames;
    analysis->peak = peak;
    analysis->leftPeak = leftPeak;
    analysis->rightPeak = rightPeak;
    analysis->rate = rate;
    analysis->sequence++;
    analysis->lastWrite = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    atomic_flag_clear_explicit(&analysis->busy, memory_order_release);
}

static int mixerMacAnalysisReadInternal(mixerMacAnalysis *analysis, float *left, float *right,
                       double *rate, float *peak, float *leftPeak, float *rightPeak, uint64_t *sequence, bool consumePeak) {
    if (!analysis || atomic_flag_test_and_set_explicit(&analysis->busy, memory_order_acquire)) return 0;
    int valid = analysis->count == ANALYSIS_FRAMES &&
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - analysis->lastWrite < 400000000ull;
    if (valid) {
        if (left && right) {
            uint32_t tail = ANALYSIS_FRAMES - analysis->index;
            memcpy(left, analysis->left + analysis->index, tail * sizeof(float));
            memcpy(left + tail, analysis->left, analysis->index * sizeof(float));
            memcpy(right, analysis->right + analysis->index, tail * sizeof(float));
            memcpy(right + tail, analysis->right, analysis->index * sizeof(float));
        }
        *rate = analysis->rate;
        *peak = analysis->peak;
        *leftPeak = analysis->leftPeak;
        *rightPeak = analysis->rightPeak;
        *sequence = analysis->sequence;
        if (consumePeak) {
            analysis->peak = 0;
            analysis->leftPeak = analysis->rightPeak = 0;
        }
    }
    atomic_flag_clear_explicit(&analysis->busy, memory_order_release);
    return valid;
}

int mixerMacAnalysisRead(mixerMacAnalysis *analysis, float *left, float *right,
                       double *rate, float *peak, float *leftPeak, float *rightPeak, uint64_t *sequence) {
    return mixerMacAnalysisReadInternal(analysis, left, right, rate, peak, leftPeak, rightPeak, sequence, true);
}

int mixerMacAnalysisPeek(mixerMacAnalysis *analysis, float *left, float *right,
                       double *rate, float *peak, float *leftPeak, float *rightPeak, uint64_t *sequence) {
    return mixerMacAnalysisReadInternal(analysis, left, right, rate, peak, leftPeak, rightPeak, sequence, false);
}

void mixerMacAnalysisReset(mixerMacAnalysis *analysis) {
    if (!analysis || atomic_flag_test_and_set_explicit(&analysis->busy, memory_order_acquire)) return;
    analysis->count = 0;
    analysis->index = 0;
    analysis->peak = 0;
    analysis->leftPeak = analysis->rightPeak = 0;
    analysis->lastWrite = 0;
    analysis->sequence++;
    atomic_flag_clear_explicit(&analysis->busy, memory_order_release);
}

struct mixerMacStereo {
    atomic_bool bypassed;
    _Atomic(float) pan, width;
    float renderedPan, renderedWidth;
};

mixerMacStereo *mixerMacStereoCreate(void) {
    mixerMacStereo *state = calloc(1, sizeof(mixerMacStereo));
    if (!state) return NULL;
    atomic_init(&state->bypassed, false);
    atomic_init(&state->pan, 0);
    atomic_init(&state->width, 1);
    state->renderedWidth = 1;
    return state;
}
void mixerMacStereoDestroy(mixerMacStereo *state) { free(state); }
void mixerMacStereoSetBypassed(mixerMacStereo *state, int bypassed) {
    atomic_store_explicit(&state->bypassed, bypassed != 0, memory_order_relaxed);
}
void mixerMacStereoSet(mixerMacStereo *state, float pan, float width) {
    atomic_store_explicit(&state->pan, isfinite(pan) ? fmaxf(-1, fminf(1, pan)) : 0, memory_order_relaxed);
    atomic_store_explicit(&state->width, isfinite(width) ? fmaxf(0, fminf(2, width)) : 1, memory_order_relaxed);
}
void mixerMacStereoProcess(mixerMacStereo *state, uint32_t frames, AudioBufferList *buffers) {
    if (atomic_load_explicit(&state->bypassed, memory_order_relaxed) || buffers->mNumberBuffers != 2) return;
    AudioBuffer *leftBuffer = &buffers->mBuffers[0], *rightBuffer = &buffers->mBuffers[1];
    if (!leftBuffer->mData || !rightBuffer->mData || leftBuffer->mNumberChannels != 1 || rightBuffer->mNumberChannels != 1) return;
    uint32_t available = leftBuffer->mDataByteSize / sizeof(float);
    if (rightBuffer->mDataByteSize / sizeof(float) < available) available = rightBuffer->mDataByteSize / sizeof(float);
    if (frames > available) frames = available;
    float *left = leftBuffer->mData, *right = rightBuffer->mData;
    const float pan = atomic_load_explicit(&state->pan, memory_order_relaxed);
    const float width = atomic_load_explicit(&state->width, memory_order_relaxed);
    for (uint32_t i = 0; i < frames; ++i) {
        state->renderedPan += fmaxf(-1.0f / 240, fminf(1.0f / 240, pan - state->renderedPan));
        state->renderedWidth += fmaxf(-1.0f / 240, fminf(1.0f / 240, width - state->renderedWidth));
        float mid = (left[i] + right[i]) * 0.5f;
        float side = (left[i] - right[i]) * (0.5f * state->renderedWidth);
        left[i] = (mid + side) * fminf(1, 1 - state->renderedPan);
        right[i] = (mid - side) * fminf(1, 1 + state->renderedPan);
    }
}
