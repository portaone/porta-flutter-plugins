## Unreleased

* RNNoise v0.2 with its standard model as a second engine, `WebrtcNoiseSuppressionEngine.rnnoise02` (`rnnoise-0.2`), for evaluation; v0.1.1 stays the default. Built only when the app asks for it (Android: Gradle property `flutter_webrtc_noise_suppression.rnnoise02=true`; iOS: `FLUTTER_WEBRTC_NS_RNNOISE02=1` at build time); then about 5.3 MB more per ABI.
* `vadStream`: the voice probability of the microphone, the highest of each 100 ms, through the event channel `com.portaone.flutter_webrtc_noise_suppression/vad`; the capture thread only raises an atomic value.
* `attach(suppressionLevel:)` and `setSuppressionLevel`: a dry/wet mix from 0.0 to 1.0, aligned with the engine's delay and ramped over one frame.
* `measure(engine:)` times an engine on the device: 3 s of white noise, mean and p99 per frame, attenuation.
* The detach line carries the call's time per frame: mean, p99, max and the frames over 10 ms.
* `attach(dumpInputSeconds:)`, Android only: the slot input written as a WAV on detach, for diagnostics, at the slot's rate (it starts again when a call drops from 48 to 16 kHz).
* Engines by name: an internal `NoiseSuppressorRegistry` (Android and iOS), where a new engine of the plugin is one line; `WebrtcNoiseSuppressionEngine` is a class of the engines the plugin ships, RNNoise v0.1.1 (`rnnoise`). An app cannot register its own engine.
* `attach(engines:)` puts a chain of engines into the slot, run in order; one detach line per engine.
* A format adapter in front of an engine of another rate or frame length, both ways: down (low-pass, decimation by a whole factor, the engine's frames, interpolation) and up (interpolation, the engine's frames, decimation). RNNoise now denoises calls on G.711 and G.722, where libwebrtc's slot runs at 16 kHz and every frame used to pass unchanged; `measure` reports the adapter's delay as `latencyMs`.
* Engines are created off the main thread; an attach overtaken by a later attach or a detach answers false.

## 0.0.1

* Experimental. The noise_suppression plugin's suppressor (RNNoise v0.1.1) in flutter_webrtc's capture post-processing slot, Android and iOS, switched from Dart with `WebrtcNoiseSuppressionBridge.attach` / `detach`.
