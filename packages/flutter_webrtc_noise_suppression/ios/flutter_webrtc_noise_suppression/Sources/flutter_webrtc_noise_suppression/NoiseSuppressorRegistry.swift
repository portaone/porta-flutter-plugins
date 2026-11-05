import Foundation
#if canImport(NoiseSuppression)
  // Swift Package Manager builds it as a module of its own; CocoaPods builds one module of all.
  import NoiseSuppression
#endif

/// The engines `attach` and `measure` can name, each by the name the Dart side sends.
///
/// Internal to the plugin: an app picks one of the engines the plugin ships
/// (`WebrtcNoiseSuppressionEngine.rnnoise`), it does not bring its own. A new engine comes as a pull
/// request: its `NSPNoiseSuppressor`, one entry in `factories` below, its name in Dart (see the
/// docs/adding-an-engine.md). The plugin, the chain and the `FormatAdapter` do not change for it.
/// Safe to use from any thread; a factory runs off the main thread and may take its time (loading
/// a model). A factory that returns nil could not create its engine.
final class NoiseSuppressorRegistry {
  typealias Factory = () -> NSPNoiseSuppressor?

  /// The name of RNNoise v0.1.1, the default engine.
  static let rnnoise = "rnnoise"

  /// The name of RNNoise v0.2 with its standard model, under evaluation beside v0.1.1.
  static let rnnoise02 = "rnnoise-0.2"

  private static let lock = NSLock()
  private static var factories: [String: Factory] = {
    var all: [String: Factory] = [rnnoise: { NSPRnnoiseSuppressor(model: .v0_1) }]
    // Only in a build that has it (FLUTTER_WEBRTC_NS_RNNOISE02=1 at build time).
    if NSPRnnoiseSuppressor.isAvailable(.v0_2) { all[rnnoise02] = { NSPRnnoiseSuppressor(model: .v0_2) } }
    return all
  }()

  private init() {}

  /// Adds the engine `name`, or replaces the one of that name.
  static func register(_ name: String, factory: @escaping Factory) {
    lock.lock()
    defer { lock.unlock() }
    factories[name] = factory
  }

  /// Removes the engine `name`; a suppressor already in the slot stays until it is detached.
  static func unregister(_ name: String) {
    lock.lock()
    defer { lock.unlock() }
    factories.removeValue(forKey: name)
  }

  /// The names registered, sorted.
  static var names: [String] {
    lock.lock()
    defer { lock.unlock() }
    return factories.keys.sorted()
  }

  static func factory(_ name: String) -> Factory? {
    lock.lock()
    defer { lock.unlock() }
    return factories[name]
  }
}

/// Engines for the plugin's own device tests, registered only when a test asks
/// (`WebrtcNoiseSuppressionBridge.registerTestEngines`), never in an app's normal run.
enum TestEngines {
  /// 16 kHz in 10 ms frames, left as they are: what reaches the slot back is the format adapter's.
  static let identity16k = "test-identity-16k"

  static func register() {
    NoiseSuppressorRegistry.register(identity16k) { Identity16k() }
  }

  private final class Identity16k: NSObject, NSPNoiseSuppressor {
    var engine: String { "test identity 16 kHz" }
    var engineSampleRate: Int { 16_000 }
    var engineFrameSize: Int { 160 }

    func initialize(withSampleRate sampleRateHz: Int) -> Bool { sampleRateHz == 16_000 }

    func processSamples(_ samples: UnsafeMutablePointer<Float>, count: Int) -> NSPNoiseSuppressorResult {
      count == 160 ? .processed : .unsupportedFrame
    }

    func releaseEngine() {}
  }
}
