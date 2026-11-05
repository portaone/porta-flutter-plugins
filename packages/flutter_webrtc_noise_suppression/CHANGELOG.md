## Unreleased

## 0.1.0

First release on pub.dev. Experimental.

* RNNoise v0.1.1 in flutter_webrtc's capture post-processing slot, after the platform's echo cancellation and noise suppression and right before the encoder, on Android and iOS; switched from Dart with `WebrtcNoiseSuppressionBridge.attach` / `detach`.
* Calls on G.711 and G.722, where the slot runs at 16 kHz, are denoised through a format adapter (up to 48 kHz and back, 11.5 ms of delay); `measure` reports the adapter's delay as `latencyMs`.
* `attach(suppressionLevel:)` and `setSuppressionLevel`: a dry/wet mix from 0.0 to 1.0, aligned with the engine's delay and ramped over one frame.
* `vadStream`: the voice probability of the microphone, the highest of each 100 ms.
* RNNoise v0.2 with its standard model as a second engine, `WebrtcNoiseSuppressionEngine.rnnoise02`, built only when the app asks for it (Android: Gradle property `flutter_webrtc_noise_suppression.rnnoise02=true`; iOS: `FLUTTER_WEBRTC_NS_RNNOISE02=1` at build time); about 5.3 MB more per ABI.
* `attach(engines:)` runs a chain of engines in order; engines are created off the main thread, and an attach overtaken by a later attach or a detach answers false.
* `measure(engine:)` times an engine on the device: 3 s of white noise, mean and p99 per frame, attenuation.
* A log line on attach and one per engine on detach, with the call's time per frame: mean, p99, max and the frames over 10 ms.
* `attach(dumpInputSeconds:)`, Android only: the slot input written as a WAV on detach, for diagnostics.
* Swift Package Manager and CocoaPods on iOS (15.0 and newer).
