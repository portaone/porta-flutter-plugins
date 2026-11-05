#ifndef NS_RNNOISE02_H
#define NS_RNNOISE02_H

#ifdef __cplusplus
extern "C" {
#endif

/* RNNoise v0.2 (xiph/rnnoise, 2024) with its standard model: 48 kHz mono, 480-sample frames of
 * float samples on the int16 scale, processed in place. The only way into that build: its own
 * rnnoise.h shares names with the v0.1.1 one the core uses. */
typedef struct NsRnnoise02 NsRnnoise02;

/* Allocates a state; NULL when it cannot be allocated. */
NsRnnoise02* ns_rnnoise02_create(void);

void ns_rnnoise02_destroy(NsRnnoise02* state);

/* Denoises one frame in place; returns the voice probability, 0..1. */
float ns_rnnoise02_process_frame(NsRnnoise02* state, float* samples);

#ifdef __cplusplus
}
#endif

#endif
