import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An engine the plugin ships, by the name its native side registers it under.
@immutable
class WebrtcNoiseSuppressionEngine {
  const WebrtcNoiseSuppressionEngine._(this.wire);

  /// RNNoise v0.1.1: strong on steady and impulsive noise, weak on other voices.
  static const rnnoise = WebrtcNoiseSuppressionEngine._('rnnoise');

  /// RNNoise v0.2 (2024) with its standard model, beside [rnnoise] for evaluation: much larger
  /// weights and more CPU; how it sounds in a call is being measured.
  static const rnnoise02 = WebrtcNoiseSuppressionEngine._('rnnoise-0.2');

  /// The plugin's own device tests: 16 kHz in 10 ms frames, left as they are, so what comes back is
  /// the format adapter's. Registered only after [WebrtcNoiseSuppressionBridge.registerTestEngines].
  @visibleForTesting
  static const testIdentity16k = WebrtcNoiseSuppressionEngine._('test-identity-16k');

  /// An engine the native side does not register, for the test of that refusal.
  @visibleForTesting
  static const testUnknown = WebrtcNoiseSuppressionEngine._('test-unknown');

  /// The name the native side knows it by.
  final String wire;

  @override
  bool operator ==(Object other) => other is WebrtcNoiseSuppressionEngine && other.wire == wire;

  @override
  int get hashCode => wire.hashCode;

  @override
  String toString() => 'WebrtcNoiseSuppressionEngine($wire)';
}

/// Noise suppression in flutter_webrtc's capture post-processing slot, switched from Dart.
///
/// The native side of this plugin (Android `WebrtcNoiseSuppressionPlugin`, iOS
/// `WebrtcNoiseSuppressionPlugin`) puts the noise_suppression plugin's suppressor into the slot,
/// after the platform's own echo cancellation and noise suppression and before the encoder.
/// Android binds it to the engine that called; iOS keeps one for the process.
class WebrtcNoiseSuppressionBridge {
  const WebrtcNoiseSuppressionBridge({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The channel the native side answers on.
  static const channelName = 'com.portaone.flutter_webrtc_noise_suppression';

  /// The channel of [vadStream].
  static const vadChannelName = '$channelName/vad';

  static const _vadChannel = EventChannel(vadChannelName);

  /// The probability (0.0..1.0) that the microphone held voice: the highest of its 10 ms frames over
  /// each 100 ms, while a chain is in the slot and one of its engines detects voice (RNNoise does).
  /// Nothing comes while no chain is attached or no audio flows. A broadcast stream; the native side
  /// counts only while someone listens.
  Stream<double> get vadStream => _vadChannel.receiveBroadcastStream().map((value) => (value as num).toDouble());

  final MethodChannel _channel;

  /// Whether the native side exists on this platform: Android and iOS only.
  static bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Puts a chain of [engines] into the slot: every frame goes through them in this order. A chain
  /// already there is taken out first; the same chain again is left as it is. True when the chain
  /// is there after the call; false when flutter_webrtc has no audio processing yet, an engine could
  /// not be created, or a later [attach] or a [detach] came while the engines were being created
  /// (they are created off the main thread, a model may take most of a second). An engine the
  /// native side does not have fails the call with a [PlatformException] `unknown_engine`.
  ///
  /// [suppressionLevel] is how much of the denoised signal goes out, see [setSuppressionLevel].
  ///
  /// [dumpInputSeconds] is diagnostics, Android only: the first that many seconds of what reaches
  /// the slot, before the suppressor, are kept and written on detach as a 48 kHz 16-bit WAV into the
  /// app's external files directory (`adb pull` reads it from a release build).
  Future<bool> attach({
    List<WebrtcNoiseSuppressionEngine> engines = const [WebrtcNoiseSuppressionEngine.rnnoise],
    double suppressionLevel = 1.0,
    int dumpInputSeconds = 0,
  }) async =>
      await _channel.invokeMethod<bool>('attach', {
        'engines': [for (final e in engines) e.wire],
        'suppressionLevel': _checked(suppressionLevel),
        if (dumpInputSeconds > 0) 'dumpInputSeconds': dumpInputSeconds,
      }) ??
      false;

  /// Sets how much of the denoised signal goes out, from 0.0 (the voice as it reached the slot, one
  /// engine frame late) to 1.0 (fully denoised, the default). It applies at once to the chain in the
  /// slot, ramped over one frame so that it does not click; every [attach] sets the level again, to
  /// 1.0 unless it names another. Throws a [RangeError] outside 0.0..1.0.
  Future<void> setSuppressionLevel(double level) =>
      _channel.invokeMethod<void>('setSuppressionLevel', {'level': _checked(level)});

  static double _checked(double level) {
    if (level.isNaN || level < 0.0 || level > 1.0) {
      throw RangeError.value(level, 'level', 'must be within 0.0..1.0');
    }
    return level;
  }

  /// Registers the engines of the plugin's own device tests ([WebrtcNoiseSuppressionEngine.testIdentity16k]).
  @visibleForTesting
  Future<void> registerTestEngines() => _channel.invokeMethod<void>('registerTestEngines');

  /// Runs 3 s of white noise through a fresh suppressor of [engine] on this device, outside the
  /// slot but through the same format adapter: the time per 10 ms frame, the attenuation and the
  /// delay the adapter adds. A check that the engine fits the phone's audio thread, not a
  /// measurement of call quality.
  Future<WebrtcNoiseSuppressionMeasurement> measure({
    WebrtcNoiseSuppressionEngine engine = WebrtcNoiseSuppressionEngine.rnnoise,
  }) async {
    final map = await _channel.invokeMapMethod<String, Object?>('measure', {'engine': engine.wire}) ?? const {};
    return WebrtcNoiseSuppressionMeasurement(
      engine: map['engine'] as String? ?? '',
      meanUs: (map['meanUs'] as num?)?.toDouble() ?? double.nan,
      p99Us: (map['p99Us'] as num?)?.toDouble() ?? double.nan,
      attenuationDb: (map['attenuationDb'] as num?)?.toDouble() ?? double.nan,
      latencyMs: (map['latencyMs'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Takes the suppressor out of the slot. True when one was there.
  Future<bool> detach() async => await _channel.invokeMethod<bool>('detach') ?? false;
}

/// What [WebrtcNoiseSuppressionBridge.measure] saw on the device.
@immutable
class WebrtcNoiseSuppressionMeasurement {
  const WebrtcNoiseSuppressionMeasurement({
    required this.engine,
    required this.meanUs,
    required this.p99Us,
    required this.attenuationDb,
    this.latencyMs = 0,
  });

  /// The engine's name and version, as the native side reports it.
  final String engine;

  /// Mean and 99th percentile time per 10 ms frame, microseconds: the budget is 10000.
  final double meanUs;
  final double p99Us;

  /// White noise in against out once the model has settled, dB.
  final double attenuationDb;

  /// The delay the format adapter adds for an engine of another rate or frame length, ms; 0 for an
  /// engine that takes the slot's frames as they are.
  final double latencyMs;

  @override
  String toString() =>
      '$engine: mean ${meanUs.toStringAsFixed(0)} us, p99 ${p99Us.toStringAsFixed(0)} us, '
      'attenuation ${attenuationDb.toStringAsFixed(1)} dB'
      '${latencyMs > 0 ? ', adapter delay ${latencyMs.toStringAsFixed(1)} ms' : ''}';
}
