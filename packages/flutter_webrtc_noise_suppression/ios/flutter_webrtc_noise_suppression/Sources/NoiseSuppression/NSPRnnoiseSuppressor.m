#import "./include/NoiseSuppression/NSPRnnoiseSuppressor.h"

#import "noise_suppressor.h"

@implementation NSPRnnoiseSuppressor {
  NsSuppressor* _suppressor;
  NSInteger _sampleRate;
  BOOL _initialized;
}

+ (NSInteger)sampleRate {
  return ns_sample_rate();
}

+ (NSInteger)frameSize {
  return ns_frame_size();
}

+ (BOOL)isAvailable:(NSPRnnoiseModel)model {
  return ns_engine_name((NsEngine)model) != NULL;
}

- (nullable instancetype)init {
  return [self initWithModel:NSPRnnoiseModelV01];
}

- (nullable instancetype)initWithModel:(NSPRnnoiseModel)model {
  self = [super init];
  if (self == nil) return nil;
  _model = model;
  _suppressor = ns_create_engine((NsEngine)model);
  if (_suppressor == NULL) return nil;
  return self;
}

- (void)dealloc {
  ns_destroy(_suppressor);
}

- (NSInteger)engineSampleRate {
  return ns_sample_rate();
}

- (NSInteger)engineFrameSize {
  return ns_frame_size();
}

- (NSString*)engine {
  return [NSString stringWithUTF8String:ns_engine_name((NsEngine)_model)];
}

- (BOOL)initializeWithSampleRate:(NSInteger)sampleRateHz {
  if (_suppressor == NULL) return NO;
  if (_initialized) ns_reset(_suppressor);
  _initialized = YES;
  _sampleRate = sampleRateHz;
  return sampleRateHz == ns_sample_rate();
}

- (NSPNoiseSuppressorResult)processSamples:(float*)samples count:(NSInteger)count {
  return (NSPNoiseSuppressorResult)ns_process(_suppressor, (int)_sampleRate, (int)count, samples,
                                              NULL);
}

- (void)setSuppressionLevel:(float)level {
  ns_set_suppression_level(_suppressor, level);
}

- (float)takeVoiceProbability {
  float peak = ns_take_voice_probability(_suppressor);
  return peak < 0 ? NAN : peak;
}

- (void)releaseEngine {
  ns_destroy(_suppressor);
  _suppressor = NULL;
}

@end
