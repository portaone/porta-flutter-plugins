#include "noise_suppressor.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "rnnoise.h"

/* RNNoise v0.2 is in the build only when it was asked for (NS_WITH_RNNOISE02): it adds about 5 MB
 * of weights. Without it the engine has no name and is never created. */
#ifdef NS_WITH_RNNOISE02
#include "ns_rnnoise02.h"
#else
typedef struct NsRnnoise02 NsRnnoise02;
static NsRnnoise02* ns_rnnoise02_create(void) { return NULL; }
static void ns_rnnoise02_destroy(NsRnnoise02* state) { (void)state; }
static float ns_rnnoise02_process_frame(NsRnnoise02* state, float* samples) {
  (void)state;
  (void)samples;
  return 0.0f;
}
#endif

#define NS_RATE 48000
#define NS_FRAME 480

struct NsSuppressor {
  NsEngine engine;
  DenoiseState* state; /* v0.1.1 */
  NsRnnoise02* v02;
  /* RNNoise's output is one frame behind its input, so a mix with the input
   * as it arrives would comb-filter the voice; `dry` holds the frame before. */
  float dry[NS_FRAME];
  _Atomic float level;
  float applied; /* the level the last frame ended on; audio thread only */
  _Atomic float voice_peak; /* the highest voice probability since the last take; -1 for none */
};

int ns_sample_rate(void) { return NS_RATE; }

int ns_frame_size(void) { return NS_FRAME; }

const char* ns_engine(void) { return ns_engine_name(NS_ENGINE_RNNOISE); }

const char* ns_engine_name(NsEngine engine) {
  switch (engine) {
    case NS_ENGINE_RNNOISE:
      return "rnnoise 0.1.1";
    case NS_ENGINE_RNNOISE_02:
#ifdef NS_WITH_RNNOISE02
      return "rnnoise 0.2";
#else
      return NULL;
#endif
  }
  return NULL;
}

/* A fresh state of `engine`; 0 when it cannot be allocated. */
static int new_state(NsEngine engine, DenoiseState** v01, NsRnnoise02** v02) {
  if (engine == NS_ENGINE_RNNOISE) {
    *v01 = rnnoise_create(NULL);
    return *v01 != NULL;
  }
  *v02 = ns_rnnoise02_create();
  return *v02 != NULL;
}

static void free_state(DenoiseState* v01, NsRnnoise02* v02) {
  if (v01 != NULL) rnnoise_destroy(v01);
  ns_rnnoise02_destroy(v02);
}

static float run(NsEngine engine, DenoiseState* v01, NsRnnoise02* v02, float* samples) {
  if (engine == NS_ENGINE_RNNOISE) return rnnoise_process_frame(v01, samples, samples);
  return ns_rnnoise02_process_frame(v02, samples);
}

static void warm_up(NsEngine engine) {
  /* RNNoise v0.1.1 builds its FFT tables in process-wide storage on the first
   * frame it processes, with malloc. One frame of silence here keeps that off
   * the audio thread; v0.2 gets the same, in case it does too. */
  DenoiseState* v01 = NULL;
  NsRnnoise02* v02 = NULL;
  if (!new_state(engine, &v01, &v02)) return;
  float silence[NS_FRAME];
  memset(silence, 0, sizeof(silence));
  run(engine, v01, v02, silence);
  free_state(v01, v02);
}

NsSuppressor* ns_create(void) { return ns_create_engine(NS_ENGINE_RNNOISE); }

NsSuppressor* ns_create_engine(NsEngine engine) {
  if (ns_engine_name(engine) == NULL) return NULL;
  NsSuppressor* suppressor = (NsSuppressor*)calloc(1, sizeof(NsSuppressor));
  if (suppressor == NULL) return NULL;
  suppressor->engine = engine;
  atomic_init(&suppressor->level, 1.0f);
  atomic_init(&suppressor->voice_peak, -1.0f);
  suppressor->applied = 1.0f;
  warm_up(engine);
  if (!new_state(engine, &suppressor->state, &suppressor->v02)) {
    free(suppressor);
    return NULL;
  }
  return suppressor;
}

NsEngine ns_suppressor_engine(const NsSuppressor* suppressor) {
  return suppressor == NULL ? NS_ENGINE_RNNOISE : suppressor->engine;
}

void ns_destroy(NsSuppressor* suppressor) {
  if (suppressor == NULL) return;
  free_state(suppressor->state, suppressor->v02);
  free(suppressor);
}

int ns_reset(NsSuppressor* suppressor) {
  if (suppressor == NULL) return 0;
  /* rnnoise_init on a live state re-allocates its GRU buffers and leaks the
   * old ones, so a fresh state replaces the old one. */
  DenoiseState* state = NULL;
  NsRnnoise02* v02 = NULL;
  if (!new_state(suppressor->engine, &state, &v02)) return 0;
  free_state(suppressor->state, suppressor->v02);
  suppressor->state = state;
  suppressor->v02 = v02;
  memset(suppressor->dry, 0, sizeof(suppressor->dry));
  return 1;
}

void ns_set_suppression_level(NsSuppressor* suppressor, float level) {
  if (suppressor == NULL) return;
  /* The comparison is written so that NaN also lands on 1. */
  float clamped = level >= 0.0f ? (level < 1.0f ? level : 1.0f) : (level < 0.0f ? 0.0f : 1.0f);
  atomic_store_explicit(&suppressor->level, clamped, memory_order_relaxed);
}

float ns_suppression_level(const NsSuppressor* suppressor) {
  if (suppressor == NULL) return 1.0f;
  return atomic_load_explicit(&((NsSuppressor*)suppressor)->level, memory_order_relaxed);
}

float ns_take_voice_probability(NsSuppressor* suppressor) {
  if (suppressor == NULL) return -1.0f;
  return atomic_exchange_explicit(&suppressor->voice_peak, -1.0f, memory_order_relaxed);
}

/* Raises the interval's peak to `vad`; a taker that reset it in between only costs a retry. */
static void raise_voice_peak(NsSuppressor* suppressor, float vad) {
  float seen = atomic_load_explicit(&suppressor->voice_peak, memory_order_relaxed);
  while (vad > seen &&
         !atomic_compare_exchange_weak_explicit(&suppressor->voice_peak, &seen, vad,
                                                memory_order_relaxed, memory_order_relaxed)) {
  }
}

/* Mixes the denoised `wet` with the frame before `input`, ramping from the last
 * frame's level to `target`, and keeps `input` for the next frame. */
static void mix(NsSuppressor* suppressor, float* wet, const float* input, float target) {
  float gain = suppressor->applied;
  const float step = (target - gain) / NS_FRAME;
  for (int i = 0; i < NS_FRAME; i++) {
    gain += step;
    wet[i] = gain * wet[i] + (1.0f - gain) * suppressor->dry[i];
  }
  suppressor->applied = target;
}

NsResult ns_process(NsSuppressor* suppressor, int sample_rate_hz, int num_samples, float* samples,
                    float* voice_probability) {
  if (suppressor == NULL || samples == NULL) return NS_INVALID;
  if (sample_rate_hz != NS_RATE) return NS_UNSUPPORTED_RATE;
  if (num_samples != NS_FRAME) return NS_UNSUPPORTED_FRAME;
  float input[NS_FRAME];
  memcpy(input, samples, sizeof(input));
  float vad = run(suppressor->engine, suppressor->state, suppressor->v02, samples);
  const float target = atomic_load_explicit(&suppressor->level, memory_order_relaxed);
  if (target < 1.0f || suppressor->applied < 1.0f) mix(suppressor, samples, input, target);
  memcpy(suppressor->dry, input, sizeof(input));
  raise_voice_peak(suppressor, vad);
  if (voice_probability != NULL) *voice_probability = vad;
  return NS_PROCESSED;
}
