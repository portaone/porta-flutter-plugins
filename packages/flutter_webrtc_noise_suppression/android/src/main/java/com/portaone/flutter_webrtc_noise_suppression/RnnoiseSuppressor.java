package com.portaone.flutter_webrtc_noise_suppression;

import java.nio.ByteBuffer;

/** {@link NoiseSuppressor} on RNNoise: 48 kHz mono, 480 samples per frame. */
public final class RnnoiseSuppressor implements NoiseSuppressor {
  /** The RNNoise build and model a suppressor runs; the ids are the C core's NsEngine. */
  public enum Model {
    /** RNNoise v0.1.1. */
    V0_1(0),
    /** RNNoise v0.2 (2024) with its standard model. */
    V0_2(1);

    final int id;

    Model(int id) {
      this.id = id;
    }
  }

  static {
    System.loadLibrary("flutter_webrtc_noise_suppression");
  }

  private static final Result[] RESULTS = Result.values();

  private long handle;
  private int sampleRateHz;

  private final Model model;

  /** RNNoise v0.1.1. @throws OutOfMemoryError when the engine state cannot be allocated. */
  public RnnoiseSuppressor() {
    this(Model.V0_1);
  }

  /** @throws OutOfMemoryError when the engine state cannot be allocated. */
  public RnnoiseSuppressor(Model model) {
    this.model = model;
    handle = nativeCreate(model.id);
    if (handle == 0) throw new OutOfMemoryError("noise suppressor state");
  }

  /** The model this suppressor runs. */
  public Model model() {
    return model;
  }

  @Override
  public String engine() {
    return nativeEngine(model.id);
  }

  @Override
  public boolean initialize(int sampleRateHz) {
    if (handle == 0) return false;
    if (this.sampleRateHz != 0) nativeReset(handle);
    this.sampleRateHz = sampleRateHz;
    return sampleRateHz == nativeSampleRate();
  }

  @Override
  public Result process(ByteBuffer frame, int numSamples) {
    if (handle == 0 || frame == null || !frame.isDirect()) return Result.INVALID;
    if (frame.remaining() < numSamples * 4) return Result.INVALID;
    int code = nativeProcess(handle, sampleRateHz, numSamples, frame, frame.position());
    return code >= 0 && code < RESULTS.length ? RESULTS[code] : Result.INVALID;
  }

  @Override
  public void setSuppressionLevel(float level) {
    if (handle != 0) nativeSetSuppressionLevel(handle, level);
  }

  @Override
  public float takeVoiceProbability() {
    if (handle == 0) return Float.NaN;
    float peak = nativeTakeVoiceProbability(handle);
    return peak < 0 ? Float.NaN : peak;
  }

  @Override
  public void release() {
    if (handle != 0) {
      nativeDestroy(handle);
      handle = 0;
    }
  }

  @Override
  public int engineSampleRateHz() {
    return nativeSampleRate();
  }

  @Override
  public int engineFrameSize() {
    return nativeFrameSize();
  }

  /** Whether this build has [model]: RNNoise v0.2 only when the app built it in. */
  public static boolean isAvailable(Model model) {
    return nativeEngine(model.id) != null;
  }

  /** Samples per frame the engine accepts. */
  public static int frameSize() {
    return nativeFrameSize();
  }

  /** The only sample rate the engine accepts, Hz. */
  public static int sampleRate() {
    return nativeSampleRate();
  }

  private static native long nativeCreate(int engine);

  private static native void nativeDestroy(long handle);

  private static native void nativeReset(long handle);

  private static native int nativeProcess(
      long handle, int sampleRateHz, int numSamples, ByteBuffer frame, int byteOffset);

  private static native void nativeSetSuppressionLevel(long handle, float level);

  private static native float nativeTakeVoiceProbability(long handle);

  private static native String nativeEngine(int engine);

  private static native int nativeFrameSize();

  private static native int nativeSampleRate();
}
