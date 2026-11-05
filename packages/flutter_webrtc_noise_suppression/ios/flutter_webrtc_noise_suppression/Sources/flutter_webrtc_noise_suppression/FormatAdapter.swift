import Accelerate
import Foundation
#if canImport(NoiseSuppression)
  // Swift Package Manager builds it as a module of its own; CocoaPods builds one module of all.
  import NoiseSuppression
#endif

/// Puts an engine that works at another rate or frame length into the slot's 10 ms frames.
///
/// The engine names its format through `engineSampleRate` and `engineFrameSize`. When that is the
/// stream's own (RNNoise: 48 kHz, 480 samples), or the engine names none, the adapter hands the
/// frames over as they are. When the stream's rate is a whole multiple of the engine's, the stream
/// is low-passed and decimated (48 kHz to 16 kHz is 3), gathered into the engine's frames, denoised,
/// and interpolated back with the same filter. When the engine's rate is a whole multiple of the
/// stream's, the other way round: interpolated up (a call on G.711 or G.722 gives libwebrtc's slot
/// 16 kHz, RNNoise takes 48 kHz), denoised, decimated back. Either way it costs a delay of
/// `latencySamples`: one engine frame and a little more for the filters. Rates of no whole ratio are
/// not taken; their frames come back unchanged. The same algorithm as the Android FormatAdapter.
///
/// The filters run on Accelerate over flat buffers: in a debug build Swift's own loops over arrays
/// took 2.5 ms a frame on an iPhone. Each history is a ring written twice, at i and i + length, so
/// its last `length` samples are always one contiguous run for `vDSP_dotpr`.
///
/// Buffers are allocated in `initialize(withSampleRate:)`; `processSamples(_:count:)` allocates
/// nothing and is meant for the audio thread. Calls are serialized by the caller.
final class FormatAdapter: NSObject, NSPNoiseSuppressor {
  private let inner: NSPNoiseSuppressor
  private var passthrough = true
  private var supported = false
  private var upward = false  // the engine's rate above the stream's
  private var factor = 1
  private var engineFrame = 0

  private var tapCount = 0
  private var taps = Buffer()
  private var polyLen = 0
  private var polyReversed = Buffer()  // row p, column j: taps[p + (polyLen - 1 - j) * factor] * factor
  private var down = Buffer()  // the stream's last tapCount samples, a ring written twice
  private var downPos = 0
  private var downPhase = 0
  private var up = Buffer()  // the engine output's last polyLen samples, a ring written twice
  private var upPos = 0
  private var upPhase = 0
  private var engineIn = Buffer()
  private var engineFill = 0
  private var fifo = Buffer()  // engine output waiting to be interpolated, a ring
  private var fifoSize = 0
  private var fifoRead = 0
  private var fifoCount = 0
  private var input = Buffer()  // upward: the stream's last polyLen samples, a ring written twice
  private var inputPos = 0

  /// The delay the adapter adds, in samples of the stream; 0 when frames pass as they are.
  private(set) var latencySamples = 0

  init(_ inner: NSPNoiseSuppressor) {
    self.inner = inner
  }

  var engine: String { inner.engine }

  func initialize(withSampleRate sampleRateHz: Int) -> Bool {
    let named = inner.engineSampleRate ?? 0
    let rate = named == 0 ? sampleRateHz : named
    let namedFrame = inner.engineFrameSize ?? 0
    let frame = namedFrame == 0 ? rate / 100 : namedFrame
    if rate == sampleRateHz && frame == sampleRateHz / 100 {
      passthrough = true
      supported = true
      latencySamples = 0
      return inner.initialize(withSampleRate: sampleRateHz)
    }
    passthrough = false
    guard rate > 0, frame > 0, sampleRateHz > 0 else {
      supported = false
      return false
    }
    if rate > sampleRateHz && rate % sampleRateHz == 0 {
      return initializeUpward(sampleRateHz, rate: rate, frame: frame)
    }
    guard sampleRateHz % rate == 0 else {
      supported = false
      return false
    }
    upward = false
    factor = sampleRateHz / rate
    engineFrame = frame
    let h = Self.lowPass(factor)
    tapCount = h.count
    taps = Buffer(h)
    polyLen = (tapCount + factor - 1) / factor
    var reversed = [Float](repeating: 0, count: factor * polyLen)
    for p in 0..<factor {
      for j in 0..<polyLen {
        let k = p + (polyLen - 1 - j) * factor
        reversed[p * polyLen + j] = k < tapCount ? h[k] * Float(factor) : 0
      }
    }
    polyReversed = Buffer(reversed)
    down = Buffer(count: 2 * tapCount)
    downPos = 0
    downPhase = 0
    up = Buffer(count: 2 * polyLen)
    upPos = 0
    upPhase = 0
    engineIn = Buffer(count: frame)
    engineFill = 0
    // One engine frame of silence ahead, so the interpolator never waits for the engine.
    let prefill = frame + 1
    fifoSize = 2 * frame + 2
    fifo = Buffer(count: fifoSize)
    fifoRead = 0
    fifoCount = prefill
    latencySamples = prefill * factor + tapCount - 1
    supported = inner.initialize(withSampleRate: rate)
    return supported
  }

  /// The stream below the engine: `rate` is `sampleRateHz` times a whole factor.
  private func initializeUpward(_ sampleRateHz: Int, rate: Int, frame: Int) -> Bool {
    upward = true
    factor = rate / sampleRateHz
    engineFrame = frame
    let h = Self.lowPass(factor)
    tapCount = h.count
    taps = Buffer(h)
    polyLen = (tapCount + factor - 1) / factor
    var reversed = [Float](repeating: 0, count: factor * polyLen)
    for p in 0..<factor {
      for j in 0..<polyLen {
        let k = p + (polyLen - 1 - j) * factor
        reversed[p * polyLen + j] = k < tapCount ? h[k] * Float(factor) : 0
      }
    }
    polyReversed = Buffer(reversed)
    input = Buffer(count: 2 * polyLen)
    inputPos = 0
    down = Buffer(count: 2 * tapCount)
    downPos = 0
    engineIn = Buffer(count: frame)
    engineFill = 0
    // At least one engine frame of silence ahead, so the decimator never waits for the engine. The
    // decimator reads the last of every `factor` samples; a prefill of factor - 1 beyond a whole
    // number of stream samples puts its output on the stream's own grid, so the delay is a whole
    // number of stream samples rather than a fraction of one.
    let ahead = (frame + factor - 1) / factor
    fifoSize = 2 * frame + 2 * factor
    fifo = Buffer(count: fifoSize)
    fifoRead = 0
    fifoCount = ahead * factor + factor - 1
    latencySamples = ahead + (tapCount - 1) / factor
    supported = inner.initialize(withSampleRate: rate)
    return supported
  }

  func processSamples(_ samples: UnsafeMutablePointer<Float>, count: Int) -> NSPNoiseSuppressorResult {
    if passthrough { return inner.processSamples(samples, count: count) }
    guard supported else { return .unsupportedRate }
    if upward { return processUpward(samples, count: count) }
    guard count % factor == 0 else { return .unsupportedFrame }
    var result = NSPNoiseSuppressorResult.processed
    let taps = self.taps.pointer, poly = polyReversed.pointer, down = self.down.pointer
    let up = self.up.pointer, engineIn = self.engineIn.pointer, fifo = self.fifo.pointer
    let tapLength = vDSP_Length(tapCount), polyLength = vDSP_Length(polyLen)
    for i in 0..<count {
      down[downPos] = samples[i]
      down[downPos + tapCount] = samples[i]
      downPos = downPos + 1 == tapCount ? 0 : downPos + 1
      downPhase += 1
      if downPhase == factor {
        downPhase = 0
        // down[downPos...] holds the last tapCount samples, oldest first; the filter is symmetric.
        var acc: Float = 0
        vDSP_dotpr(taps, 1, down + downPos, 1, &acc, tapLength)
        engineIn[engineFill] = acc
        engineFill += 1
        if engineFill == engineFrame {
          engineFill = 0
          let r = inner.processSamples(engineIn, count: engineFrame)
          if r != .processed { result = r }
          for n in 0..<engineFrame {
            fifo[(fifoRead + fifoCount) % fifoSize] = engineIn[n]
            fifoCount += 1
          }
        }
      }
      if upPhase == 0 {
        up[upPos] = fifo[fifoRead]
        up[upPos + polyLen] = fifo[fifoRead]
        upPos = upPos + 1 == polyLen ? 0 : upPos + 1
        fifoRead = fifoRead + 1 == fifoSize ? 0 : fifoRead + 1
        fifoCount -= 1
      }
      // Polyphase interpolation: up[upPos...] holds the last polyLen engine samples, oldest first,
      // against the filter's phase upPhase read backwards.
      var acc: Float = 0
      vDSP_dotpr(up + upPos, 1, poly + upPhase * polyLen, 1, &acc, polyLength)
      upPhase = upPhase + 1 == factor ? 0 : upPhase + 1
      samples[i] = acc
    }
    return result
  }

  /// The stream below the engine: every sample interpolated to `factor` engine samples and back.
  private func processUpward(_ samples: UnsafeMutablePointer<Float>, count: Int) -> NSPNoiseSuppressorResult {
    var result = NSPNoiseSuppressorResult.processed
    let taps = self.taps.pointer, poly = polyReversed.pointer, down = self.down.pointer
    let input = self.input.pointer, engineIn = self.engineIn.pointer, fifo = self.fifo.pointer
    let tapLength = vDSP_Length(tapCount), polyLength = vDSP_Length(polyLen)
    for i in 0..<count {
      input[inputPos] = samples[i]
      input[inputPos + polyLen] = samples[i]
      inputPos = inputPos + 1 == polyLen ? 0 : inputPos + 1
      // Polyphase interpolation: input[inputPos...] holds the last polyLen stream samples, oldest
      // first, against each phase of the filter read backwards.
      for p in 0..<factor {
        var acc: Float = 0
        vDSP_dotpr(input + inputPos, 1, poly + p * polyLen, 1, &acc, polyLength)
        engineIn[engineFill] = acc
        engineFill += 1
        if engineFill == engineFrame {
          engineFill = 0
          let r = inner.processSamples(engineIn, count: engineFrame)
          if r != .processed { result = r }
          for n in 0..<engineFrame {
            fifo[(fifoRead + fifoCount) % fifoSize] = engineIn[n]
            fifoCount += 1
          }
        }
      }
      // Decimation: `factor` engine samples in, one stream sample out; the filter is symmetric.
      for _ in 0..<factor {
        down[downPos] = fifo[fifoRead]
        down[downPos + tapCount] = fifo[fifoRead]
        downPos = downPos + 1 == tapCount ? 0 : downPos + 1
        fifoRead = fifoRead + 1 == fifoSize ? 0 : fifoRead + 1
        fifoCount -= 1
      }
      var acc: Float = 0
      vDSP_dotpr(taps, 1, down + downPos, 1, &acc, tapLength)
      samples[i] = acc
    }
    return result
  }

  func releaseEngine() {
    inner.releaseEngine()
  }

  func setSuppressionLevel(_ level: Float) {
    inner.setSuppressionLevel?(level)
  }

  func takeVoiceProbability() -> Float {
    inner.takeVoiceProbability?() ?? .nan
  }

  /// A windowed-sinc low-pass (Blackman) for decimating and interpolating by `factor`: cut at 0.9 of
  /// the lower rate's Nyquist, 24 taps per factor, unit gain at DC.
  static func lowPass(_ factor: Int) -> [Float] {
    let n = 24 * factor + 1
    let cutoff = 0.45 / Double(factor)
    let center = Double(n - 1) / 2
    var h = [Double](repeating: 0, count: n)
    for i in 0..<n {
      let x = Double(i) - center
      let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
      let window = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
        + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
      h[i] = sinc * window
    }
    let sum = h.reduce(0, +)
    return h.map { Float($0 / sum) }
  }
}

/// A zeroed block of floats the adapter owns; freed with it.
private final class Buffer {
  let pointer: UnsafeMutablePointer<Float>
  private let count: Int

  init(count: Int = 0) {
    self.count = max(count, 1)
    pointer = UnsafeMutablePointer<Float>.allocate(capacity: self.count)
    pointer.initialize(repeating: 0, count: self.count)
  }

  convenience init(_ values: [Float]) {
    self.init(count: values.count)
    for (i, v) in values.enumerated() { pointer[i] = v }
  }

  deinit {
    pointer.deallocate()
  }
}
