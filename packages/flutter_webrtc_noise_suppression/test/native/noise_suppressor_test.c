/* Host test of the C core: make test (needs only a C compiler). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "noise_suppressor.h"

static int failures = 0;

#define CHECK(cond, msg)                         \
  do {                                           \
    if (!(cond)) {                               \
      fprintf(stderr, "FAIL: %s\n", msg);        \
      failures++;                                \
    }                                            \
  } while (0)

static double rms(const float* x, int n) {
  double s = 0;
  for (int i = 0; i < n; i++) s += (double)x[i] * x[i];
  return sqrt(s / n);
}

/* Deterministic white noise on the int16 scale. */
static unsigned int seed = 12345;
static float noise_sample(float amplitude) {
  seed = seed * 1103515245u + 12345u;
  return amplitude * (((float)((seed >> 8) & 0xffff) / 32768.0f) - 1.0f);
}

/* The whole contract on one engine. */
static void check_engine(NsEngine engine) {
  seed = 12345;
  NsSuppressor* s = ns_create_engine(engine);
  CHECK(s != NULL, "create");
  CHECK(ns_suppressor_engine(s) == engine, "engine kept");

  float frame[480];
  for (int i = 0; i < 480; i++) frame[i] = 1000.0f;
  CHECK(ns_process(s, 16000, 480, frame, NULL) == NS_UNSUPPORTED_RATE, "16 kHz refused");
  CHECK(frame[0] == 1000.0f && frame[479] == 1000.0f, "refused frame unchanged (rate)");
  CHECK(ns_process(s, 48000, 160, frame, NULL) == NS_UNSUPPORTED_FRAME, "160 samples refused");
  CHECK(frame[0] == 1000.0f, "refused frame unchanged (size)");
  CHECK(ns_process(NULL, 48000, 480, frame, NULL) == NS_INVALID, "NULL suppressor");
  CHECK(ns_process(s, 48000, 480, NULL, NULL) == NS_INVALID, "NULL samples");

  /* 3 s of steady white noise: after the model settles the output is far
   * quieter than the input. */
  double in_rms = 0, out_rms = 0;
  float vad = -1;
  for (int f = 0; f < 300; f++) {
    for (int i = 0; i < 480; i++) frame[i] = noise_sample(3000.0f);
    double r_in = rms(frame, 480);
    CHECK(ns_process(s, 48000, 480, frame, &vad) == NS_PROCESSED, "48 kHz / 480 processed");
    if (f >= 100) {
      in_rms += r_in;
      out_rms += rms(frame, 480);
    }
  }
  double attenuation_db = 20.0 * log10(in_rms / (out_rms + 1e-9));
  printf("%s: white noise attenuation: %.1f dB, last vad %.3f\n", ns_engine_name(engine), attenuation_db, vad);
  CHECK(attenuation_db > 10.0, "white noise attenuated by more than 10 dB");
  CHECK(vad >= 0.0f && vad <= 1.0f, "voice probability in 0..1");

  /* Silence stays silence once the overlap of the last noisy frame is out. */
  for (int f = 0; f < 5; f++) {
    for (int i = 0; i < 480; i++) frame[i] = 0.0f;
    ns_process(s, 48000, 480, frame, NULL);
  }
  printf("%s: silence rms after noise: %g\n", ns_engine_name(engine), rms(frame, 480));
  CHECK(rms(frame, 480) < 10.0, "silence stays below -70 dBFS");

  CHECK(ns_reset(s) == 1, "reset");
  CHECK(ns_reset(NULL) == 0, "reset NULL");
  for (int i = 0; i < 480; i++) frame[i] = noise_sample(3000.0f);
  CHECK(ns_process(s, 48000, 480, frame, NULL) == NS_PROCESSED, "process after reset");

  ns_destroy(s);

}

/* The dry/wet mix of one suppressor over `frames` frames of noise; `out` gets all of them. */
static void run_level(float level, float* in, float* out, int frames) {
  seed = 777;
  NsSuppressor* s = ns_create();
  ns_set_suppression_level(s, level);
  for (int f = 0; f < frames; f++) {
    float frame[480];
    for (int i = 0; i < 480; i++) frame[i] = in[f * 480 + i] = noise_sample(3000.0f);
    CHECK(ns_process(s, 48000, 480, frame, NULL) == NS_PROCESSED, "level: processed");
    memcpy(out + f * 480, frame, sizeof(frame));
  }
  ns_destroy(s);
}

static void check_level(void) {
  enum { FRAMES = 300, N = FRAMES * 480 };
  float* in = malloc(sizeof(float) * N);
  float* wet = malloc(sizeof(float) * N);
  float* dry = malloc(sizeof(float) * N);
  float* half = malloc(sizeof(float) * N);
  run_level(1.0f, in, wet, FRAMES);
  run_level(0.0f, in, dry, FRAMES);
  run_level(0.5f, in, half, FRAMES);

  /* Level 0 is the input, exactly one frame late. */
  int same = 1;
  for (int i = 480; i < N; i++) same &= dry[i] == in[i - 480];
  CHECK(same, "level 0 is the input one frame late");

  /* The dry path has to sit where the engine's output sits, or the mix would
   * comb-filter: the wet output correlates best with the input one frame back. */
  int best_lag = -1;
  double best = -1;
  for (int lag = 0; lag <= 960; lag += 10) {
    double xy = 0;
    for (int i = 48000; i < N; i++) xy += (double)wet[i] * in[i - lag];
    if (xy > best) { best = xy; best_lag = lag; }
  }
  printf("level: the engine's output is %d samples behind its input\n", best_lag);
  CHECK(best_lag == 480, "the engine's delay is the dry path's");

  /* Level 0.5 is the mean of the two others. */
  double worst = 0;
  for (int i = 48000; i < N; i++) {
    double d = fabs(half[i] - 0.5 * (wet[i] + dry[i]));
    if (d > worst) worst = d;
  }
  CHECK(worst < 0.01, "level 0.5 is half of each");
  double r_wet = rms(wet + 48000, N - 48000), r_half = rms(half + 48000, N - 48000);
  double r_dry = rms(dry + 48000, N - 48000);
  printf("level: rms 0 -> %.0f, 0.5 -> %.0f, 1 -> %.0f\n", r_dry, r_half, r_wet);
  CHECK(r_wet < r_half && r_half < r_dry, "the noise falls with the level");

  /* A change is ramped, not stepped. */
  NsSuppressor* s = ns_create();
  float frame[480];
  for (int i = 0; i < 480; i++) frame[i] = 1000.0f;
  ns_process(s, 48000, 480, frame, NULL);
  ns_set_suppression_level(s, 0.0f);
  for (int i = 0; i < 480; i++) frame[i] = 1000.0f;
  ns_process(s, 48000, 480, frame, NULL);
  double jump = 0;
  for (int i = 1; i < 480; i++) {
    double d = fabs(frame[i] - frame[i - 1]);
    if (d > jump) jump = d;
  }
  CHECK(jump < 100.0, "no step inside the frame of a change");
  for (int i = 0; i < 480; i++) frame[i] = 1000.0f;
  ns_process(s, 48000, 480, frame, NULL);
  CHECK(frame[0] == 1000.0f && frame[479] == 1000.0f, "the next frame is all dry");

  ns_set_suppression_level(s, 3.0f);
  CHECK(ns_suppression_level(s) == 1.0f, "above 1 clamps");
  ns_set_suppression_level(s, -1.0f);
  CHECK(ns_suppression_level(s) == 0.0f, "below 0 clamps");
  ns_set_suppression_level(s, NAN);
  CHECK(ns_suppression_level(s) == 1.0f, "NaN is full suppression");
  ns_set_suppression_level(s, 0.25f);
  CHECK(ns_reset(s) == 1, "reset");
  CHECK(ns_suppression_level(s) == 0.25f, "reset keeps the level");
  ns_set_suppression_level(NULL, 0.5f);
  CHECK(ns_suppression_level(NULL) == 1.0f, "NULL reads 1");
  ns_destroy(s);
  free(in); free(wet); free(dry); free(half);
}

static void check_voice_probability(void) {
  NsSuppressor* s = ns_create();
  CHECK(ns_take_voice_probability(s) == -1.0f, "no frame yet: -1");
  float frame[480], vad, peak = 0;
  seed = 4242;
  for (int f = 0; f < 10; f++) {
    for (int i = 0; i < 480; i++) frame[i] = noise_sample(3000.0f);
    ns_process(s, 48000, 480, frame, &vad);
    if (vad > peak) peak = vad;
  }
  float taken = ns_take_voice_probability(s);
  CHECK(taken == peak, "the take is the highest of the frames");
  CHECK(taken >= 0.0f && taken <= 1.0f, "the take is a probability");
  CHECK(ns_take_voice_probability(s) == -1.0f, "a take starts the next interval");
  ns_process(s, 16000, 480, frame, NULL);
  CHECK(ns_take_voice_probability(s) == -1.0f, "a refused frame leaves no probability");
  CHECK(ns_take_voice_probability(NULL) == -1.0f, "NULL takes -1");
  ns_destroy(s);
}

int main(void) {
  CHECK(ns_sample_rate() == 48000, "sample rate is 48000");
  CHECK(ns_frame_size() == 480, "frame size is 480");
  CHECK(ns_create_engine((NsEngine)99) == NULL, "unknown engine refused");
  CHECK(ns_engine_name((NsEngine)99) == NULL, "unknown engine has no name");
  NsSuppressor* d = ns_create();
  CHECK(ns_suppressor_engine(d) == NS_ENGINE_RNNOISE, "ns_create is RNNoise v0.1.1");
  ns_destroy(d);
  ns_destroy(NULL);

  check_engine(NS_ENGINE_RNNOISE);
#ifdef NS_WITH_RNNOISE02
  check_engine(NS_ENGINE_RNNOISE_02);
#else
  CHECK(ns_engine_name(NS_ENGINE_RNNOISE_02) == NULL, "v0.2 not built: no name");
  CHECK(ns_create_engine(NS_ENGINE_RNNOISE_02) == NULL, "v0.2 not built: not created");
  printf("rnnoise 0.2: not in this build\n");
#endif
  check_level();
  check_voice_probability();

  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  printf("ok\n");
  return 0;
}
