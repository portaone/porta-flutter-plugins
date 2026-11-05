package com.portaone.flutter_webrtc_noise_suppression;

import java.nio.ByteBuffer;

/**
 * Removes background noise from 10 ms frames of mono voice.
 *
 * <p>The package's contract on Android. It knows nothing about WebRTC: an audio pipeline (a bridge
 * to flutter_webrtc's capture post-processing, a recorder) adapts its own frames to this interface.
 *
 * <p>Threading: calls on one instance are serialized by the caller. {@link #process} never
 * allocates and is meant for the audio thread; {@link #initialize} and {@link #release} may
 * allocate or free.
 */
public interface NoiseSuppressor {
  /** What {@link #process} did with a frame. */
  enum Result {
    /** The frame was denoised in place. */
    PROCESSED,
    /** The sample rate is not supported; the frame is unchanged. */
    UNSUPPORTED_RATE,
    /** The frame length is not supported; the frame is unchanged. */
    UNSUPPORTED_FRAME,
    /** The buffer or the instance is not usable; the frame is unchanged. */
    INVALID
  }

  /** Engine name and version, for logs. */
  String engine();

  /**
   * Prepares for a stream of the given rate. Called again when the rate changes; the history of
   * the previous stream is dropped.
   *
   * @return false when the engine cannot run at this rate; {@link #process} then leaves frames
   *     unchanged.
   */
  boolean initialize(int sampleRateHz);

  /**
   * Denoises {@code numSamples} float samples on the int16 scale, in place.
   *
   * @param frame a direct buffer in native byte order; samples start at its position.
   */
  Result process(ByteBuffer frame, int numSamples);

  /** Frees the engine. The instance is not usable after this. */
  void release();

  /**
   * How much of the denoised signal the output carries: 1 is all of it (the default), 0 the input
   * as it came. Any thread may call this while {@link #process} runs. An engine without a level
   * keeps the default and ignores this.
   */
  default void setSuppressionLevel(float level) {}

  /**
   * The highest probability (0..1) that a frame held voice, over the frames processed since the
   * last call, and starts the next interval; NaN when no frame was processed in between or the
   * engine has no voice detection (the default). Any thread may call this while {@link #process}
   * runs; it must not block the audio thread.
   */
  default float takeVoiceProbability() {
    return Float.NaN;
  }

  /**
   * The rate the engine works at, Hz, or 0 when it takes the stream's own rate (the default). The
   * add-on reaches a rate the stream's divides by a whole number by resampling.
   */
  default int engineSampleRateHz() {
    return 0;
  }

  /**
   * Samples per frame the engine takes at {@link #engineSampleRateHz}, or 0 for frames of 10 ms
   * (the default). The add-on gathers the stream into frames of this length.
   */
  default int engineFrameSize() {
    return 0;
  }
}
