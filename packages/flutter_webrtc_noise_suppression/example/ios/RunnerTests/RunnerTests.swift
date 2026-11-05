import Flutter
import UIKit
import XCTest

import NoiseSuppression
@testable import flutter_webrtc_noise_suppression

/// The suppressor through its interface: 3 s of white noise come out quieter once the model has
/// settled (the first second is skipped, as in the C test). The add-on through its method channel
/// handler, without Dart: attach puts the suppressor into flutter_webrtc's process-wide slot, detach
/// takes it out, an unknown method is not implemented.
class RunnerTests: XCTestCase {

  private func call(_ plugin: WebrtcNoiseSuppressionPlugin, _ method: String) -> Any? {
    var answer: Any?
    let done = expectation(description: method)
    plugin.handle(FlutterMethodCall(methodName: method, arguments: nil)) { result in
      answer = result
      done.fulfill()
    }
    // attach answers from the main queue once its engines are created; the wait spins it.
    waitForExpectations(timeout: 5)
    return answer
  }

  func testAttachThenDetach() {
    let plugin = WebrtcNoiseSuppressionPlugin()
    XCTAssertEqual(call(plugin, "attach") as? Bool, true)
    XCTAssertEqual(call(plugin, "detach") as? Bool, true)
    XCTAssertEqual(call(plugin, "detach") as? Bool, false)
  }

  func testUnknownMethod() {
    let plugin = WebrtcNoiseSuppressionPlugin()
    XCTAssertTrue((call(plugin, "nope") as AnyObject) === FlutterMethodNotImplemented)
  }

  func testRnnoiseSuppressorDenoisesWhiteNoise() {
    denoisesWhiteNoise(.v0_1)
  }

  func testRnnoise02SuppressorDenoisesWhiteNoise() {
    denoisesWhiteNoise(.v0_2)
  }

  // The format adapter, with engines that only copy: the same cases as Android's FormatAdapterTest.

  private final class Identity: NSObject, NSPNoiseSuppressor {
    let rate: Int
    let frame: Int
    var lengths = Set<Int>()
    var level: Float = 1
    func setSuppressionLevel(_ level: Float) { self.level = level }
    func takeVoiceProbability() -> Float { 0.75 }
    init(_ rate: Int, _ frame: Int) {
      self.rate = rate
      self.frame = frame
    }
    var engine: String { "identity \(rate)/\(frame)" }
    var engineSampleRate: Int { rate }
    var engineFrameSize: Int { frame }
    func initialize(withSampleRate sampleRateHz: Int) -> Bool { rate == 0 || sampleRateHz == rate }
    func processSamples(_ samples: UnsafeMutablePointer<Float>, count: Int) -> NSPNoiseSuppressorResult {
      lengths.insert(count)
      return .processed
    }
    func releaseEngine() {}
  }

  private func sine(_ hz: Double) -> (Int) -> Float {
    { t in Float(10_000 * sin(2 * .pi * hz * Double(t) / 48_000)) }
  }

  private func run(_ adapter: FormatAdapter, seconds: Int, _ signal: (Int) -> Float) -> [Float] {
    var out = [Float]()
    var frame = [Float](repeating: 0, count: 480)
    for f in 0..<(seconds * 100) {
      for i in 0..<480 { frame[i] = signal(f * 480 + i) }
      _ = frame.withUnsafeMutableBufferPointer { adapter.processSamples($0.baseAddress!, count: 480) }
      out += frame
    }
    return out
  }

  private func bestCorrelation(_ out: [Float], _ signal: (Int) -> Float, maxLag: Int) -> (Int, Double) {
    var best = (0, -1.0)
    for lag in 0...maxLag {
      var xy = 0.0, xx = 0.0, yy = 0.0
      for i in 24_000..<out.count {
        let x = Double(signal(i - lag))
        xy += x * Double(out[i])
        xx += x * x
        yy += Double(out[i]) * Double(out[i])
      }
      let c = xy / sqrt(xx * yy)
      if c > best.1 { best = (lag, c) }
    }
    return best
  }

  private func levelDb(_ out: [Float]) -> Double {
    let tail = out[24_000...]
    let rms = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count))
    return 20 * log10(rms / (10_000 / sqrt(2)))
  }

  func testAnEngineOfTheSlotFormatGetsTheFramesAsTheyAre() {
    let engine = Identity(0, 0)
    let adapter = FormatAdapter(engine)
    XCTAssertTrue(adapter.initialize(withSampleRate: 48_000))
    XCTAssertEqual(adapter.latencySamples, 0)
    let out = run(adapter, seconds: 1, sine(1000))
    for i in 0..<out.count { XCTAssertEqual(out[i], sine(1000)(i)) }
    XCTAssertEqual(engine.lengths, [480])
  }

  func testA16kHzEngineGetsItsOwnFramesAndTheVoiceBandComesBack() {
    let engine = Identity(16_000, 160)
    let adapter = FormatAdapter(engine)
    XCTAssertTrue(adapter.initialize(withSampleRate: 48_000))
    let out = run(adapter, seconds: 2, sine(1000))
    XCTAssertEqual(engine.lengths, [160])
    let (lag, corr) = bestCorrelation(out, sine(1000), maxLag: adapter.latencySamples + 48)
    XCTAssertGreaterThan(corr, 0.9999, "lag \(lag)")
    XCTAssertLessThanOrEqual(lag, adapter.latencySamples)
    XCTAssertEqual(levelDb(out), 0, accuracy: 0.2)
  }

  func testAFrameLengthThatIsNot10msIsGathered() {
    let engine = Identity(16_000, 256)
    let adapter = FormatAdapter(engine)
    XCTAssertTrue(adapter.initialize(withSampleRate: 48_000))
    let out = run(adapter, seconds: 2, sine(440))
    XCTAssertEqual(engine.lengths, [256])
    XCTAssertGreaterThan(bestCorrelation(out, sine(440), maxLag: adapter.latencySamples + 48).1, 0.9999)
  }

  private func runAt(_ adapter: FormatAdapter, rate: Int, seconds: Int, _ signal: (Int) -> Float) -> [Float] {
    let n = rate / 100
    var out = [Float]()
    var frame = [Float](repeating: 0, count: n)
    for f in 0..<(seconds * 100) {
      for i in 0..<n { frame[i] = signal(f * n + i) }
      let result = frame.withUnsafeMutableBufferPointer { adapter.processSamples($0.baseAddress!, count: n) }
      XCTAssertEqual(result, .processed)
      out += frame
    }
    return out
  }

  private func sineAt(_ hz: Double, _ rate: Int) -> (Int) -> Float {
    { t in Float(10_000 * sin(2 * .pi * hz * Double(t) / Double(rate))) }
  }

  private func correlationAt(_ out: [Float], _ signal: (Int) -> Float, maxLag: Int) -> (Int, Double) {
    var best = (0, -1.0)
    for lag in 0...maxLag {
      var xy = 0.0, xx = 0.0, yy = 0.0
      for i in (out.count / 2)..<out.count {
        let x = Double(signal(i - lag))
        xy += x * Double(out[i])
        xx += x * x
        yy += Double(out[i]) * Double(out[i])
      }
      let c = xy / sqrt(xx * yy)
      if c > best.1 { best = (lag, c) }
    }
    return best
  }

  func testA48kHzEngineOnA16kHzStreamGetsItsFramesAndTheVoiceComesBack() {
    // A call on G.711 or G.722: libwebrtc's slot runs at 16 kHz, RNNoise takes 48 kHz.
    let engine = Identity(48_000, 480)
    let adapter = FormatAdapter(engine)
    XCTAssertTrue(adapter.initialize(withSampleRate: 16_000))
    let out = runAt(adapter, rate: 16_000, seconds: 2, sineAt(1000, 16_000))
    XCTAssertEqual(engine.lengths, [480])
    let (lag, corr) = correlationAt(out, sineAt(1000, 16_000), maxLag: adapter.latencySamples + 16)
    XCTAssertGreaterThan(corr, 0.9999, "lag \(lag)")
    XCTAssertLessThanOrEqual(lag, adapter.latencySamples)
    XCTAssertEqual(adapter.latencySamples, (480 + 73 - 1) / 3)
    let tail = out[(out.count / 2)...]
    let rms = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count))
    XCTAssertEqual(20 * log10(rms / (10_000 / sqrt(2))), 0, accuracy: 0.2)
  }

  func testA48kHzEngineOnAn8kHzStreamWorksToo() {
    let engine = Identity(48_000, 480)
    let adapter = FormatAdapter(engine)
    XCTAssertTrue(adapter.initialize(withSampleRate: 8_000))
    let out = runAt(adapter, rate: 8_000, seconds: 2, sineAt(440, 8_000))
    XCTAssertEqual(engine.lengths, [480])
    XCTAssertGreaterThan(correlationAt(out, sineAt(440, 8_000), maxLag: adapter.latencySamples + 8).1, 0.9999)
  }

  func testWhatTheLowerRateCannotCarryIsFilteredOut() {
    let adapter = FormatAdapter(Identity(16_000, 160))
    XCTAssertTrue(adapter.initialize(withSampleRate: 48_000))
    XCTAssertLessThan(levelDb(run(adapter, seconds: 2, sine(12_000))), -40)
  }

  func testARateTheStreamDoesNotDivideLeavesFramesUnchanged() {
    let adapter = FormatAdapter(Identity(44_100, 441))
    XCTAssertFalse(adapter.initialize(withSampleRate: 48_000))
    var frame = (0..<480).map { sine(1000)($0) }
    let result = frame.withUnsafeMutableBufferPointer { adapter.processSamples($0.baseAddress!, count: 480) }
    XCTAssertEqual(result, .unsupportedRate)
    XCTAssertEqual(frame, (0..<480).map { sine(1000)($0) })
  }

  func testTheLevelReachesTheEngineThroughTheAdapter() {
    let engine = Identity(16_000, 160)
    FormatAdapter(engine).setSuppressionLevel(0.25)
    XCTAssertEqual(engine.level, 0.25)
  }

  func testTheVoiceProbabilityComesThroughTheAdapter() {
    XCTAssertEqual(FormatAdapter(Identity(16_000, 160)).takeVoiceProbability(), 0.75)
    let rnnoise = NSPRnnoiseSuppressor(model: .v0_1)!
    XCTAssertTrue(rnnoise.takeVoiceProbability().isNaN, "no frame yet")
    rnnoise.releaseEngine()
  }

  func testTheRegistryNamesRnnoiseAndTakesAnotherEngine() {
    XCTAssertTrue(NoiseSuppressorRegistry.names.contains(NoiseSuppressorRegistry.rnnoise))
    NoiseSuppressorRegistry.register("test-identity") { Identity(16_000, 160) }
    XCTAssertEqual(NoiseSuppressorRegistry.factory("test-identity")?()?.engine, "identity 16000/160")
    NoiseSuppressorRegistry.unregister("test-identity")
    XCTAssertFalse(NoiseSuppressorRegistry.names.contains("test-identity"))
  }

  private func denoisesWhiteNoise(_ model: NSPRnnoiseModel) {
    guard let suppressor = NSPRnnoiseSuppressor(model: model) else {
      return XCTFail("no engine state")
    }
    let engine: NSPNoiseSuppressor = suppressor
    XCTAssertTrue(engine.initialize(withSampleRate: NSPRnnoiseSuppressor.sampleRate))
    let n = NSPRnnoiseSuppressor.frameSize
    var frame = [Float](repeating: 0, count: n)
    var seed: UInt32 = 12345
    var inRms = 0.0, outRms = 0.0
    for f in 0..<300 {
      for i in 0..<n {
        seed = seed &* 1103515245 &+ 12345
        frame[i] = 3000 * (Float((seed >> 8) & 0xffff) / 32768 - 1)
      }
      let before = sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(n))
      let result = frame.withUnsafeMutableBufferPointer {
        engine.processSamples($0.baseAddress!, count: n)
      }
      XCTAssertEqual(result, .processed)
      if f >= 100 {
        inRms += before
        outRms += sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(n))
      }
    }
    XCTAssertGreaterThan(20 * log10(inRms / outRms), 10)
    engine.releaseEngine()
  }
}
