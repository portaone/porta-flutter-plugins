# Engines

| `WebrtcNoiseSuppressionEngine` | What | Weights | CPU (M5 host, per 10 ms frame) |
|---|---|---|---|
| `rnnoise` (default) | RNNoise v0.1.1 | ~90 KB | ~80 us |
| `rnnoise02` (`rnnoise-0.2`) | RNNoise v0.2 (2024) with its standard model, for evaluation beside v0.1.1; built only when the app asks for it | ~5.3 MB per ABI | see below |

`measure(engine:)` gives the time per frame and the attenuation on the device it runs on: on a Redmi A5 (Android 15 Go) p99 465 us, on a Galaxy Tab A SM-T505 (Android 12) p99 496 us. In a real call, from the detach line, the same engine took p99 1.2 ms per frame on the Redmi A5 and 3.8 ms on the SM-T505 on Opus, no frame over its 10 ms; on a 16 kHz call, through the adapter, p99 1.4-1.8 ms and 4.6-6.2 ms, one frame of about 1500 over 10 ms on the SM-T505.

RNNoise main's little model and DeepFilterNet 3 were measured for this slot and not taken (little takes the voice down under babble; DeepFilterNet 3 misses frames on the SM-T505 and costs about 19 MB per ABI). Either can come back as an engine of the plugin, as [Adding an engine](adding-an-engine.md) describes.

RNNoise v0.2 lives beside v0.1.1 in one library: its globals have the same names, so it is compiled only through `NoiseSuppressionRnnoise02/units/`, each of which includes `rnnoise02_prefix.h` (every global renamed `ns02_`, the list taken from `nm` of the compiled units) and then the vendored source, and its own `rnnoise.h` by path first, because v0.1.1's has the same name and guard. The v0.2 release names an `os_support.h` it does not ship (in `vec_neon.h`); `compat/os_support.h` stands in with the one macro it needs. It adds about 5.3 MB to the plugin's library per ABI (0.12 MB without it), most of it the model's weights. On white noise it attenuates 82 dB against v0.1.1's 15 dB (`make test`), which says nothing yet about a voice in a call. `measure` on the phones, p99 per 10 ms frame: Redmi A5 1.46 ms (v0.1.1 0.41), Galaxy Tab A 6.62 ms (0.47), iPhone 1.31 ms (1.68).

It is left out of the build unless the app asks for it, so an app that does not use it carries none of its weights:

- **Android:** `flutter_webrtc_noise_suppression.rnnoise02=true` in the app's `android/gradle.properties` (Gradle passes `NS_WITH_RNNOISE02` to CMake).
- **iOS:** `FLUTTER_WEBRTC_NS_RNNOISE02=1` in the environment of the build, `flutter build ios` or Xcode; both Swift Package Manager (`Package.swift`) and CocoaPods (the podspec) read it.

Without it `rnnoise02` is not registered, and `attach` or `measure` naming it fails with `unknown_engine`.
