import Flutter
import Foundation
import WebRTC
import flutter_webrtc
#if canImport(NoiseSuppression)
  // Swift Package Manager builds it as a module of its own; CocoaPods builds one module of all.
  import NoiseSuppression
#endif
import os.log

/// Puts a chain of `NSPNoiseSuppressor`s into flutter_webrtc's capture post-processing slot.
///
/// The two plugins know nothing about each other: flutter_webrtc offers the slot through
/// `ExternalAudioProcessingDelegate` and `AudioManager.capturePostProcessingAdapter`,
/// noise_suppression offers `NSPNoiseSuppressor`. This plugin is the only place that joins them,
/// so neither depends on the other. Engines are found by name in `NoiseSuppressorRegistry`; one of
/// another rate or frame length goes through a `FormatAdapter`. A new engine of the plugin is
/// registered there, not added here.
///
/// flutter_webrtc keeps one `AudioManager` for the process, so the slot, and the state here, are
/// process-wide: one attached chain covers every call, whichever engine asked. Every method call
/// runs on the main thread. Engines are created on one serial queue, since a model may take most of
/// a second to load, and go into the slot back on the main thread; a later attach or a detach makes
/// an attach still creating its engines answer false and free them.
public final class WebrtcNoiseSuppressionPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.portaone.flutter_webrtc_noise_suppression"
  private static let log = OSLog(subsystem: "com.portaone.flutter_webrtc_noise_suppression", category: "WebrtcNoiseSuppression")
  private static let worker = DispatchQueue(label: "com.portaone.flutter_webrtc_noise_suppression.create", qos: .userInitiated)
  private static let slotRate = 48_000
  fileprivate static var processor: ChainProcessor?
  private static var generation = 0
  private static var suppressionLevel: Float = 1
  // Two lines a call, at the default level: the device log keeps and streams it for any subsystem,
  // while an info line of a subsystem it has no configuration for may never reach a reader.

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(WebrtcNoiseSuppressionPlugin(), channel: channel)
    FlutterEventChannel(name: "\(channelName)/vad", binaryMessenger: registrar.messenger())
      .setStreamHandler(VoiceActivityStream.shared)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "attach":
      let names = Self.engineNames(arguments)
      if names.isEmpty {
        result(FlutterError(code: "no_engine", message: "attach names no engine", details: nil))
      } else if let unknown = names.first(where: { NoiseSuppressorRegistry.factory($0) == nil }) {
        result(FlutterError(code: "unknown_engine", message: "unknown engine \(unknown)", details: nil))
      } else {
        Self.setSuppressionLevel(arguments?["suppressionLevel"] as? Double ?? 1)
        Self.attach(names, result: result)
      }
    case "detach":
      result(Self.detach())
    case "setSuppressionLevel":
      Self.setSuppressionLevel(arguments?["level"] as? Double ?? 1)
      result(nil)
    case "registerTestEngines":
      TestEngines.register()
      result(nil)
    case "measure":
      let name = arguments?["engine"] as? String ?? NoiseSuppressorRegistry.rnnoise
      guard let factory = NoiseSuppressorRegistry.factory(name) else {
        result(FlutterError(code: "unknown_engine", message: "unknown engine \(name)", details: nil))
        return
      }
      // 3 s of audio is a few hundred ms of work on a slow phone: off the main thread.
      DispatchQueue.global(qos: .userInitiated).async {
        let measured = Self.measure(name, factory)
        DispatchQueue.main.async { result(measured) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The chain a call names: `engines`, or the older single `engine`, or RNNoise v0.1.1.
  private static func engineNames(_ arguments: [String: Any]?) -> [String] {
    if let names = arguments?["engines"] as? [String] { return names }
    return [arguments?["engine"] as? String ?? NoiseSuppressorRegistry.rnnoise]
  }

  /// The level of the chain in the slot, and of the next one. The engines take it atomically.
  private static func setSuppressionLevel(_ level: Double) {
    suppressionLevel = Float(level)
    processor?.setSuppressionLevel(suppressionLevel)
  }

  /// Puts a chain of the engines `names`, in that order, into the slot, and answers true when it is
  /// there. A chain already in the slot is taken out first: the slot holds one chain at a time. The
  /// same chain again is left as it is.
  private static func attach(_ names: [String], result: @escaping FlutterResult) {
    if let attached = processor, attached.names == names {
      // Still the chain asked for last: an attach of another chain still creating is dropped.
      generation += 1
      result(true)
      return
    }
    generation += 1
    let asked = generation
    worker.async {
      let start = DispatchTime.now().uptimeNanoseconds
      let stages = create(names)
      let createMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      DispatchQueue.main.async {
        guard let stages = stages else {
          result(false)
          return
        }
        guard asked == generation else {
          // A later attach or a detach came while these were created.
          stages.forEach { $0.suppressor.releaseEngine() }
          result(false)
          return
        }
        if processor != nil { _ = remove() }
        let created = ChainProcessor(names: names, stages: stages)
        created.setSuppressionLevel(suppressionLevel)
        AudioManager.sharedInstance().capturePostProcessingAdapter.addProcessing(created)
        processor = created
        let engines = stages.map { $0.suppressor.engine }.joined(separator: " > ")
        os_log("attached %{public}@ create_ms=%llu", log: log, type: .default, engines, createMs)
        result(true)
      }
    }
  }

  /// Fresh engines of `names`, each in a `FormatAdapter`; nil (and none left) when one fails.
  private static func create(_ names: [String]) -> [Stage]? {
    var stages = [Stage]()
    for name in names {
      guard let suppressor = NoiseSuppressorRegistry.factory(name)?() else {
        // The call keeps the platform processing only, which is what it had before.
        os_log("not attached: engine %{public}@ not created", log: log, type: .error, name)
        stages.forEach { $0.suppressor.releaseEngine() }
        return nil
      }
      stages.append(Stage(name: name, suppressor: FormatAdapter(suppressor)))
    }
    return stages
  }

  /// Runs 3 s of white noise through a fresh engine, frame by frame as the slot would, through the
  /// same `FormatAdapter`: the time per frame on this phone and the attenuation once the model has
  /// settled (the first second is skipped). A check of the engine on a device, not of call quality.
  private static func measure(_ name: String, _ factory: NoiseSuppressorRegistry.Factory) -> Any {
    guard let created = factory() else {
      return FlutterError(code: "no_engine", message: "engine \(name) not created", details: nil)
    }
    let suppressor = FormatAdapter(created)
    defer { suppressor.releaseEngine() }
    _ = suppressor.initialize(withSampleRate: slotRate)
    let n = slotRate / 100
    var frame = [Float](repeating: 0, count: n)
    var seed: UInt32 = 12345
    var times = [Double]()
    var inRms = 0.0, outRms = 0.0
    for f in 0..<300 {
      for i in 0..<n {
        seed = seed &* 1103515245 &+ 12345
        frame[i] = 3000 * (Float((seed >> 8) & 0xffff) / 32768 - 1)
      }
      let before = sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(n))
      let start = DispatchTime.now().uptimeNanoseconds
      _ = frame.withUnsafeMutableBufferPointer { suppressor.processSamples($0.baseAddress!, count: n) }
      times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
      if f >= 100 {
        inRms += before
        outRms += sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(n))
      }
    }
    times.sort()
    return [
      "engine": suppressor.engine,
      "meanUs": times.reduce(0, +) / Double(times.count),
      "p99Us": times[times.count * 99 / 100],
      "attenuationDb": 20 * log10(inRms / outRms),
      "latencyMs": Double(suppressor.latencySamples) * 1000 / Double(slotRate),
    ] as [String: Any]
  }

  /// Returns true when a chain was in the slot and has been removed; an attach still creating is
  /// dropped.
  private static func detach() -> Bool {
    generation += 1
    return remove()
  }

  private static func remove() -> Bool {
    guard let attached = processor else { return false }
    // The adapter calls processors under the lock that removeProcessing: takes, so once it
    // returns no frame is in flight and the engines can be freed.
    AudioManager.sharedInstance().capturePostProcessingAdapter.removeProcessing(attached)
    attached.releaseEngines()
    processor = nil
    for line in attached.summary() {
      os_log("detached: %{public}@", log: log, type: .default, line)
    }
    return true
  }
}

/// One engine of a chain and what it did in the call.
private final class Stage {
  let name: String
  let suppressor: NSPNoiseSuppressor
  var processed = 0
  var unchanged = 0
  var lastResult: NSPNoiseSuppressorResult?

  // Time per frame in the call, without allocating on the audio thread: 200 us buckets up to 20 ms,
  // the last one for everything longer.
  static let bucketNs: UInt64 = 200_000
  static let bucketCount = 100
  var buckets = [Int](repeating: 0, count: Stage.bucketCount + 1)
  var totalNs: UInt64 = 0
  var maxNs: UInt64 = 0

  init(name: String, suppressor: NSPNoiseSuppressor) {
    self.name = name
    self.suppressor = suppressor
  }

  func summary(_ announced: String) -> String {
    let frames = processed + unchanged
    let meanUs = frames == 0 ? 0 : totalNs / UInt64(frames) / 1000
    let overBudget = buckets[Int(10_000_000 / Self.bucketNs)...].reduce(0, +)
    return "\(suppressor.engine) processed=\(processed) unchanged=\(unchanged) mean_us=\(meanUs)"
      + " p99_us=\(percentileUs(0.99)) max_us=\(maxNs / 1000) over_10ms=\(overBudget) \(announced)"
  }

  /// The upper edge of the bucket the `q` quantile falls in; the last bucket reads as its floor.
  private func percentileUs(_ q: Double) -> UInt64 {
    let frames = buckets.reduce(0, +)
    if frames == 0 { return 0 }
    var seen = 0
    for (i, count) in buckets.enumerated() {
      seen += count
      if Double(seen) >= q * Double(frames) {
        return UInt64(i == Self.bucketCount ? i : i + 1) * Self.bucketNs / 1000
      }
    }
    return UInt64(Self.bucketCount) * Self.bucketNs / 1000
  }
}

/// Adapts flutter_webrtc's frames to a chain of `NSPNoiseSuppressor`s: each frame goes through
/// every engine in order, in place.
///
/// libwebrtc calls it on the capture thread with 10 ms of audio after its own processing (and,
/// with voice processing on, after Apple's echo cancellation, noise suppression and gain
/// control), right before the encoder. The adapter serializes all three callbacks under one
/// lock. The buffer of channel 0 is full band even when the frame reports several bands: the
/// post-processor runs after the bands were merged back.
private final class ChainProcessor: NSObject, ExternalAudioProcessingDelegate {
  let names: [String]
  private let stages: [Stage]
  private var initialized = false
  private var announced = ""

  init(names: [String], stages: [Stage]) {
    self.names = names
    self.stages = stages
  }

  func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
    note("initialize(\(sampleRateHz), \(channels))")
    stages.forEach { _ = $0.suppressor.initialize(withSampleRate: sampleRateHz) }
    initialized = true
  }

  func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
    guard audioBuffer.channels > 0 else { return }
    let frames = audioBuffer.frames
    // A processor added while the microphone is already running is never told the rate: the
    // adapter announces it only when the stream starts. A frame is 10 ms, so its length gives the
    // rate.
    if !initialized {
      stages.forEach { _ = $0.suppressor.initialize(withSampleRate: frames * 100) }
      initialized = true
    }
    // A frame an engine cannot take comes back unchanged, so the call keeps the audio it would have
    // had without that engine.
    let samples = audioBuffer.rawBuffer(forChannel: 0)
    for stage in stages {
      let start = DispatchTime.now().uptimeNanoseconds
      let result = stage.suppressor.processSamples(samples, count: frames)
      let spent = DispatchTime.now().uptimeNanoseconds - start
      stage.totalNs += spent
      stage.maxNs = max(stage.maxNs, spent)
      stage.buckets[min(Int(spent / Stage.bucketNs), Stage.bucketCount)] += 1
      if result == .processed { stage.processed += 1 } else { stage.unchanged += 1 }
      if result != stage.lastResult {
        stage.lastResult = result
        note("\(stage.name): result \(result.rawValue) at frame \(stage.processed + stage.unchanged) (\(frames) samples, \(audioBuffer.bands) bands)")
      }
    }
  }

  func audioProcessingRelease() {
    // The engines belong to the plugin and are freed on detach.
  }

  /// One log line per engine: how many frames were denoised and how many left unchanged (a rate or
  /// length the engine does not take), the time per frame, and what the slot announced. Read after
  /// the processor left the slot, so no frame is counted at the same time.
  func summary() -> [String] {
    stages.map { $0.summary(announced) }
  }

  func setSuppressionLevel(_ level: Float) {
    stages.forEach { $0.suppressor.setSuppressionLevel?(level) }
  }

  /// The highest voice probability any engine of the chain saw since the last call; NaN for none.
  func takeVoiceProbability() -> Float {
    var peak = Float.nan
    for stage in stages {
      let p = stage.suppressor.takeVoiceProbability?() ?? .nan
      if !p.isNaN && (peak.isNaN || p > peak) { peak = p }
    }
    return peak
  }

  func releaseEngines() {
    stages.forEach { $0.suppressor.releaseEngine() }
  }

  private func note(_ event: String) {
    if announced.count < 400 { announced += "[\(event)]" }
  }
}

/// The voice probability of the chain in the slot, to Dart while it listens: every 100 ms on the main
/// queue, the highest probability since the last tick, one event; none when no engine of the chain
/// detects voice or no frame came. The audio thread only raises an atomic value in the C core.
private final class VoiceActivityStream: NSObject, FlutterStreamHandler {
  static let shared = VoiceActivityStream()
  private var sink: FlutterEventSink?
  private var timer: Timer?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self = self, let sink = self.sink else { return }
      let peak = WebrtcNoiseSuppressionPlugin.processor?.takeVoiceProbability() ?? .nan
      if !peak.isNaN { sink(Double(peak)) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    return nil
  }
}
