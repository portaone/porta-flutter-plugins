#include "rnnoise02_prefix.h"

#include "include/ns_rnnoise02.h"
#include "rnnoise/include/rnnoise.h"

/* NULL is the model compiled in: the standard one of v0.2 (rnnoise/src/rnnoise_data.c). */
NsRnnoise02* ns_rnnoise02_create(void) { return (NsRnnoise02*)rnnoise_create(NULL); }

void ns_rnnoise02_destroy(NsRnnoise02* state) {
  if (state != NULL) rnnoise_destroy((DenoiseState*)state);
}

float ns_rnnoise02_process_frame(NsRnnoise02* state, float* samples) {
  return rnnoise_process_frame((DenoiseState*)state, samples, samples);
}
