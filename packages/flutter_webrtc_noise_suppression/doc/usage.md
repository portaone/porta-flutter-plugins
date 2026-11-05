# Usage

The dependency and the shortest use are in the [README](../README.md#use).

## Suppression level

`suppressionLevel` trades noise for naturalness: 1.0 (the default) is the fully denoised signal, 0.0 the voice as it reached the slot, in between a mix.

```dart
await bridge.attach(suppressionLevel: 0.75);
await bridge.setSuppressionLevel(0.5); // at once, during a call too
```

The mix lives in the C core. RNNoise's output is exactly one frame behind its input, so the dry signal is held back one frame to meet it (a mix with the undelayed input would comb-filter the voice), and a change is ramped over one frame so that it does not click. It costs no allocation on the capture thread, and the level is one atomic value. On a 16 kHz call the mix happens at the engine's 48 kHz, inside the format adapter, so it stays aligned there too. An engine without a level (`setSuppressionLevel` on `NoiseSuppressor` / `NSPNoiseSuppressor` is optional) ignores it.

## Voice activity

`vadStream` tells whether the microphone holds voice, as RNNoise judges it:

```dart
bridge.vadStream.listen((p) => print('voice $p')); // 0.0..1.0, about ten a second
```

Each event is the highest probability of the 10 ms frames over 100 ms, so a short word is not lost between events. On the capture thread the engine only raises one atomic value in the C core; a timer on the main thread takes it every 100 ms and sends one event, and sends nothing while no chain is attached, no audio flows or no engine of the chain detects voice (`takeVoiceProbability` on the interface is optional). The value is RNNoise's estimate on the voice after the platform's processing, not a calibrated detector.

## Attach and detach

`attach` returns false when flutter_webrtc has not built its factory yet (it does on its first use: `getUserMedia`, `createPeerConnection`), an engine cannot be created, or a later `attach` or a `detach` came while its engines were being created (they are created on a worker thread and go into the slot on the main one); the audio is then left as it was. An engine the native side does not have fails it with `PlatformException` `unknown_engine`. Attach when the microphone track opens and detach when it stops.

## Logs

The native side logs a line on attach and one per engine on detach (logcat tag `WebrtcNoiseSuppression`, os_log subsystem `com.portaone.flutter_webrtc_noise_suppression`): the chain and how long its engines took to create, then each engine's frames and their time in the call (the detach line is from a call on a Redmi A5; the bracket is in this version's form):

```
attached rnnoise 0.1.1 create_ms=<ms>
detached: rnnoise 0.1.1 processed=22581 unchanged=0 mean_us=818 p99_us=1200 max_us=3757 over_10ms=0 [initialize(48000, 1)][rnnoise: PROCESSED at frame 1 (480 samples, 3 bands)]
```

`unchanged` counts frames the engine could not take (another rate or length), left as they were; the percentile is read from 200 us buckets; `over_10ms` is the frames that took longer than the 10 ms they hold. The bracketed part is what the slot announced and each engine's result whenever it changed.

## Measure

```dart
final m = await bridge.measure(); // 3 s of white noise through a fresh engine, outside the slot
print(m); // rnnoise 0.1.1: mean 331 us, p99 465 us, attenuation 15.1 dB
```

## Diagnostics

Android only: `attach(dumpInputSeconds: 300)` keeps what reaches the slot, before the suppressor, in a buffer of that many seconds at 48 kHz allocated at attach, and writes it on detach as a 16-bit WAV at the slot's rate, `slot-input-<ms>.wav`; when the rate changes (a call settling on G.711 drops from 48 to 16 kHz) it starts again at the new rate, so the file is the call after its first frames, into the app's external files directory (`adb pull /sdcard/Android/data/<package>/files/...` reads it from a release build). The file stays until it is removed.
