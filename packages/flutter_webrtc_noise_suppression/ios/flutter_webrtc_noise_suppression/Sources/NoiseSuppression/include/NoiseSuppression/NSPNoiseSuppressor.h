#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What -processSamples:count: did with a frame.
typedef NS_ENUM(NSInteger, NSPNoiseSuppressorResult) {
  /// The frame was denoised in place.
  NSPNoiseSuppressorResultProcessed = 0,
  /// The sample rate is not supported; the frame is unchanged.
  NSPNoiseSuppressorResultUnsupportedRate = 1,
  /// The frame length is not supported; the frame is unchanged.
  NSPNoiseSuppressorResultUnsupportedFrame = 2,
  /// The samples or the instance are not usable; the frame is unchanged.
  NSPNoiseSuppressorResultInvalid = 3,
};

/// Removes background noise from 10 ms frames of mono voice.
///
/// The package's contract on iOS. It knows nothing about WebRTC: an audio pipeline (a bridge to
/// flutter_webrtc's capture post-processing, a recorder) adapts its own frames to this protocol.
///
/// Threading: calls on one instance are serialized by the caller. -processSamples:count: never
/// allocates and is meant for the audio thread; -initializeWithSampleRate: and -releaseEngine may
/// allocate or free.
@protocol NSPNoiseSuppressor <NSObject>

/// Engine name and version, for logs.
@property(nonatomic, readonly) NSString* engine;

/// Prepares for a stream of the given rate. Called again when the stream restarts or its rate
/// changes; the history of the previous stream is dropped. Returns NO when the engine cannot run
/// at this rate; frames are then left unchanged.
- (BOOL)initializeWithSampleRate:(NSInteger)sampleRateHz;

/// Denoises `count` float samples on the int16 scale, in place.
- (NSPNoiseSuppressorResult)processSamples:(float*)samples count:(NSInteger)count;

/// Frees the engine. The instance is not usable after this.
- (void)releaseEngine;

@optional

/// How much of the denoised signal the output carries: 1 is all of it (the default), 0 the input as
/// it came. Any thread may call this while -processSamples:count: runs. An engine without a level
/// does not implement it.
- (void)setSuppressionLevel:(float)level;

/// The highest probability (0..1) that a frame held voice, over the frames processed since the last
/// call, and starts the next interval; NaN when no frame was processed in between. Any thread may
/// call it while -processSamples:count: runs; it must not block the audio thread. An engine without
/// voice detection does not implement it.
- (float)takeVoiceProbability;

/// The rate the engine works at, Hz, or 0 (or not implemented) when it takes the stream's own rate.
/// The add-on reaches a rate the stream's divides by a whole number by resampling.
@property(nonatomic, readonly) NSInteger engineSampleRate;

/// Samples per frame the engine takes at engineSampleRate, or 0 (or not implemented) for frames of
/// 10 ms. The add-on gathers the stream into frames of this length.
@property(nonatomic, readonly) NSInteger engineFrameSize;

@end

NS_ASSUME_NONNULL_END
