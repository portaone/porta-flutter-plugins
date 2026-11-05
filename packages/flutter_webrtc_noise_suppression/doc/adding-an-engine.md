# Adding an engine

For contributors: an engine is added to the plugin by a pull request. An app picks one of the engines the plugin ships (`WebrtcNoiseSuppressionEngine.rnnoise`) and cannot bring its own: the registry, the format adapter and the test engine are internal.

What the pull request adds:

| Part | Where |
|---|---|
| The engine on Android: an implementation of `NoiseSuppressor` (Java or Kotlin, over JNI if its core is native) | `android/src/main/java/.../`, native code under `android/src/main/cpp` or as a prebuilt `jniLibs` library |
| The engine on iOS: an implementation of `NSPNoiseSuppressor` | `ios/flutter_webrtc_noise_suppression/Sources/NoiseSuppression/`, its C core as a target of `Package.swift` |
| Its name, one line per platform | the `init` block of `NoiseSuppressorRegistry.kt`, the `factories` of `NoiseSuppressorRegistry.swift` |
| Its name in Dart | `static const myEngine = WebrtcNoiseSuppressionEngine._('my-engine');` in `lib/` |
| Its license | `THIRD_PARTY_NOTICES.md` |
| Its check on a device | `example/integration_test`: `measure(engine: ...)` within the 10 ms budget and attenuating white noise |

What it does not touch: `WebrtcNoiseSuppressionPlugin` on either platform, the chain, the detach lines, the threading. In particular:

- **Its format.** An engine that works at another rate or frame length says so (`engineSampleRateHz()` / `engineFrameSize()` on Android, `engineSampleRate` / `engineFrameSize` on iOS; 0 or absent means the slot's own, 48 kHz in 10 ms frames). The add-on puts `FormatAdapter` in front of it, which works both ways. An engine below the slot's rate: a windowed-sinc low-pass, decimation by a whole factor (48 kHz to 16 kHz is 3), the engine's own frames gathered, interpolation back. An engine above it (RNNoise at 48 kHz on a 16 kHz call): interpolation up, the engine's frames, decimation back. Either costs one engine frame and the filters in delay (11.6 ms for a 16 kHz engine on a 48 kHz call, `measure` reports it as `latencyMs`; 11.5 ms for RNNoise on a 16 kHz call). Rates of no whole ratio are not taken: their frames pass unchanged.
- **Its cost.** The factory runs on the plugin's worker thread, so a model may take its time to load. `process` runs on the capture thread every 10 ms and must not allocate.
- **A chain.** `attach(engines: [a, b])` runs every frame through `a`, then `b`, in place. One chain is in the slot at a time; the next `attach` replaces it, the same chain again is left as it is.

The device tests use an engine of the plugin's own, `test-identity-16k` (16 kHz in 10 ms frames, left as they are), registered only by `registerTestEngines()`, which is `@visibleForTesting`; it is what shows the adapter and a chain work on a phone.
