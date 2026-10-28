#ifndef MIXERMAC_DSP_H
#define MIXERMAC_DSP_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

typedef struct mixerMacFIFO mixerMacFIFO;
mixerMacFIFO *mixerMacFIFOCreate(void);
void mixerMacFIFODestroy(mixerMacFIFO *fifo);
void mixerMacFIFOSetPan(mixerMacFIFO *fifo, float pan);
void mixerMacFIFOSetMasterPan(mixerMacFIFO *fifo, float pan);
void mixerMacFIFOSetMasterWidth(mixerMacFIFO *fifo, float width);
void mixerMacFIFOWrite(mixerMacFIFO *fifo, const AudioBufferList *buffers);
void mixerMacFIFORender(mixerMacFIFO *fifo, uint32_t frames, AudioBufferList *buffers);

typedef struct mixerMacAnalysis mixerMacAnalysis;
mixerMacAnalysis *mixerMacAnalysisCreate(void);
void mixerMacAnalysisDestroy(mixerMacAnalysis *analysis);
void mixerMacAnalysisPush(mixerMacAnalysis *analysis, const AudioBufferList *buffers, double rate);
int mixerMacAnalysisRead(mixerMacAnalysis *analysis, float *left, float *right,
                       double *rate, float *peak, float *leftPeak, float *rightPeak, uint64_t *sequence);
int mixerMacAnalysisPeek(mixerMacAnalysis *analysis, float *left, float *right,
                       double *rate, float *peak, float *leftPeak, float *rightPeak, uint64_t *sequence);
void mixerMacAnalysisReset(mixerMacAnalysis *analysis);
typedef struct mixerMacStereo mixerMacStereo;
mixerMacStereo *mixerMacStereoCreate(void);
void mixerMacStereoDestroy(mixerMacStereo *state);
void mixerMacStereoSetBypassed(mixerMacStereo *state, int bypassed);
void mixerMacStereoSet(mixerMacStereo *state, float pan, float width);
void mixerMacStereoProcess(mixerMacStereo *state, uint32_t frames, AudioBufferList *buffers);
#endif
