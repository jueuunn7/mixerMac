#include "mixerMacDSP.h"
#include <math.h>
#include <stdio.h>
#include <assert.h>

static void tone(float *input, unsigned frames, unsigned long long start, double frequency, double rate) {
    for (unsigned i=0; i<frames; ++i) {
        float value=(float)(0.1*sin(2*M_PI*frequency*(double)(start+i)/rate));
        input[i*2]=value; input[i*2+1]=-value;
    }
}
static float diagnosticSample(unsigned long long sample, unsigned channel) {
    return (float)((int)((sample * 1664525u + channel * 1013904223u) & 65535u) - 32768) / 32768.0f;
}

static void equalClockIdentity(void) {
    mixerMacFIFO *fifo=mixerMacFIFOCreate(); assert(fifo);
    float input[512*2],output[256*2];
    AudioBufferList in={1,{{2,sizeof(output),input}}};
    AudioBufferList out={1,{{2,sizeof(output),output}}};
    for(unsigned i=0;i<512;++i) for(unsigned c=0;c<2;++c) input[i*2+c]=diagnosticSample(i,c);
    mixerMacFIFOWrite(fifo,&in);
    in.mBuffers[0].mData = input + 256 * 2;
    mixerMacFIFOWrite(fifo,&in);
    in.mBuffers[0].mData = input;
    in.mBuffers[0].mDataByteSize=sizeof(output);
    for(unsigned block=0;block<4000;++block) {
        mixerMacFIFORender(fifo,256,&out);
        for(unsigned i=0;i<256;++i) for(unsigned c=0;c<2;++c) {
            assert(output[i*2+c]==diagnosticSample((unsigned long long)block*256+i,c));
            input[i*2+c]=diagnosticSample(512+(unsigned long long)block*256+i,c);
        }
        mixerMacFIFOWrite(fifo,&in);
    }
    mixerMacFIFODestroy(fifo);
    puts("PASS: equal-clock bridge preserves 1,024,000 arbitrary PCM frames bit-for-bit");
}

int main(void) {
    equalClockIdentity();
    for(unsigned rateIndex=0;rateIndex<2;++rateIndex) {
    double rate=rateIndex==0 ? 44100.0 : 48000.0;
    for (unsigned band=0; band<3; ++band) {
        double frequency=(double[]){1000,18000,20000}[band];
        mixerMacFIFO *fifo=mixerMacFIFOCreate(); assert(fifo);
        float input[4096*2],output[256*2];
        AudioBufferList in={1,{{2,sizeof(input),input}}};
        AudioBufferList out={1,{{2,sizeof(output),output}}};
        tone(input,4096,0,frequency,rate); mixerMacFIFOWrite(fifo,&in);
        unsigned long long sample=4096;
        double power=0; unsigned count=0;
        for(unsigned block=0;block<1200;++block) {
            if(block%4==0) {
                tone(input,1024,sample,frequency,rate); sample+=1024;
                in.mBuffers[0].mDataByteSize=1024*2*sizeof(float); mixerMacFIFOWrite(fifo,&in);
            }
            mixerMacFIFORender(fifo,256,&out);
            if(block>100) for(unsigned i=0;i<256;++i) {
                power+=(double)output[i*2]*output[i*2]; ++count;
                assert(fabsf(output[i*2]+output[i*2+1])<1e-6);
            }
        }
        double gain=10*log10((power/count)/0.005);
        printf("PASS: %.0f Hz @ %.0f Hz drift correction: %+.5f dB\n",frequency,rate,gain);
        assert(fabs(gain)<0.06);
        mixerMacFIFODestroy(fifo);
    }
    }
    return 0;
}
