# The capture path

Where the plugin's slot sits in a call, which rate it runs at, and what processes the voice before it. The diagram is in the [README](../README.md#architecture).

## Codecs and the slot rate

The slot comes before any encoder, so it works whatever the codec, but **the codec sets the slot's rate**. libwebrtc takes the microphone at the lowest native rate not below the send codec's (`InitializeCaptureFrame` in `audio/audio_transport_impl.cc`: 8 kHz for G.711), and the processing module, whose slot this is, runs at 16, 32 or 48 kHz, never lower (`SuitableProcessRate` in `audio_processing_impl.cc`): 48 kHz for Opus, 16 kHz for G.711 and G.722. RNNoise takes 48 kHz only, so on a 16 kHz call the format adapter interpolates every frame up to 48 kHz, runs RNNoise and decimates back, for 11.5 ms of delay. Measured on a Redmi A5 with a SIP party that speaks one codec, before the adapter learned the upward way: Opus 48 kHz, 1533 of 1533 frames denoised; PCMU and G.722 16 kHz, 160-sample frames, 10 and 9 denoised, 1502 and 1524 passed unchanged - the suppressor was in the call and did nothing. With the adapter going up, the same three codecs had every frame denoised on a Redmi A5 and a Galaxy Tab A, and on a PCMU call with noise played into the Redmi the far end's speech-to-pause gap on babble went from 11.2 to 17.4 dB against the switch off (one run each).

Which rates the slot can see, with the codecs of the built-in factory both platforms of flutter_webrtc 1.6.3 use (`CreateBuiltinAudioEncoderFactory`, libwebrtc m150):

| Send codec | Codec rate | Slot rate | RNNoise |
|---|---|---|---|
| Opus (RED carries Opus) | 48 kHz | 48 kHz | as it is |
| G.722 | 16 kHz | 16 kHz | through the adapter, up and back |
| G.711 PCMU, PCMA | 8 kHz | 16 kHz (the module never runs lower) | through the adapter, up and back |
| L16, multichannel Opus | - | - | built in but `NotAdvertised`: never offered in SDP |

iLBC, iSAC and G.729 are not in this build; a far end that insists on one gets a transcoding stand or no call. The microphone's own rate counts too (the lower of the two wins): a Bluetooth headset records at 8 or 16 kHz, so 16 kHz again; with `bypassVoiceProcessing` Android records at the phone's native rate, usually 48 or 44.1 kHz, so 48 kHz. 32 kHz, which the module also runs at, would need a microphone recording at 32 kHz; 48 kHz is not a whole multiple of it, so RNNoise would leave such a call unchanged. No phone seen here does that. G.711 and G.722 were measured on Android only; a Bluetooth call is not measured.

The engine hears the voice after echo cancellation, the platform's noise suppression and gain control, and is the last thing that changes it before the encoder. That is the place an extra denoiser does not hurt echo cancellation; a hook before the processing module (raw microphone samples) would feed the echo canceller a signal it no longer recognizes.

## Processing before the slot

What sits before the slot, read in the code (libwebrtc of webrtc-sdk `m150_release`, the `150.7871.04` flutter_webrtc 1.6.3 pins; flutter_webrtc 1.6.3):

| Step | Where it is set | What it does |
|---|---|---|
| Platform AEC and NS, Android | flutter_webrtc `MethodCallHandlerImpl.initialize`: `setUseHardwareAcousticEchoCanceler` / `setUseHardwareNoiseSuppressor` from Android 10, `setNoiseSuppressorEnabled(true)` where supported; all off with `bypassVoiceProcessing` | the device's own effects, whatever its maker built |
| Platform voice processing, iOS | flutter_webrtc's `AudioEngine` device module; its topology couples AEC and NS (`AudioEngineDevice::GetPlatformAudioProcessingTopology`) | Apple's AEC, NS and AGC, on or off together |
| WebRTC's own noise suppression | the app's `googNoiseSuppression` constraint if it names one, else libwebrtc's own default, on (`WebRtcVoiceEngine::Init`; flutter_webrtc adds `true` itself only for `audio: true`, not for a constraints map on Android); no `noiseSuppressionMode` is sent, so the mode is automatic (`sdk/media_constraints.cc`), and `media/engine/audio_processing_controller.cc` turns the software one on only when the platform's cannot be enabled, at level `kHigh` | where the phone has a noise suppressor of its own, that one ran before the engine, not WebRTC's |
| The processing order | `AudioProcessingImpl::ProcessCaptureStreamLocked` | high-pass, AEC3, NS, AGC1, bands merged, AGC2 (left off), the post filter (cascaded biquads libwebrtc adds by itself at high rates against the artefacts of the processing before), then `capture_post_processor`; after it only the output level statistics, a capture level adjustment flutter_webrtc does not configure, and zeroed frames right after an unmute |

Which platform effects run depends on the phone. Read on two of them during a call (`dumpsys media.audio_flinger`, the input thread's effect chain):

| Phone | Capture | Platform effects on the microphone | Noise suppression before the slot |
|---|---|---|---|
| Redmi A5 (Android 15 Go, Unisoc) | `VOICE_COMMUNICATION`, built-in mic, 48 kHz mono | Acoustic Echo Canceler (`sprd cvs`), enabled; the phone has no noise suppression effect at all | WebRTC's own (no platform NS to enable, so the rule above turns it on) |
| Galaxy Tab A SM-T505 (Android 12, Qualcomm) | `VOICE_COMMUNICATION`, back mic, 48 kHz | Acoustic Echo Canceler and Noise Suppression (Qualcomm Fluence), both enabled | Fluence; WebRTC's own is off |

A probe in a test build saw the same through libwebrtc's processing state: noise suppression `SOFTWARE` on the Redmi A5 (no hardware one), `PLATFORM` on the Galaxy Tab A, echo cancellation `PLATFORM` on both. Turning the platform's noise suppression off moved the far end's speech-to-pause gap by -1.8 to +2.6 dB on keyboard, babble, a colleague and a restaurant, within the run-to-run spread.
