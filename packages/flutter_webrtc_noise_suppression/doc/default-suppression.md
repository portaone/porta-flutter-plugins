# The default suppression and RNNoise

Two things suppress noise in a call, and they do not replace each other: the default one comes first, and RNNoise, when an app turns it on, works on what is left.

| | Default suppression | RNNoise (this plugin) |
|---|---|---|
| What it is | the phone maker's effect, Apple's voice processing, or WebRTC's software suppressor where the phone has none | a small neural network, RNNoise v0.1.1 |
| Where it runs | on the microphone path and in the processing module, before the slot | in the slot, last before the encoder |
| State | on unless the app turns it off (`googNoiseSuppression: false`) | off until the app calls `attach()` |
| Rates | what the platform and the module run at | 48 kHz; 16 kHz calls through the format adapter |
| Cost | none the app sees | about 90 KB of weights, p99 1-6 ms per 10 ms frame on the phones measured, 10 ms of delay of its own, 11.5 ms more on a 16 kHz call |

What the default does differs by phone ([the capture path](capture-path.md): WebRTC's on a Redmi A5, Qualcomm Fluence on a Galaxy Tab A, Apple's on an iPhone), and on these noises it did little: turning it off moved the far end's speech-to-pause gap by -1.8 to +2.6 dB, within the run-to-run spread of the setup.

RNNoise added on top of the default, gain in that gap at the far end in dB, Opus calls with voice and noise played from one speaker at the phone (the spread is about 2 dB, the real recordings are one run each):

| Noise | Redmi A5 | Galaxy Tab A |
|---|---|---|
| Keyboard | +9 | +11 |
| Real crowd | +5 | +8 |
| Babble of six voices | +3 | +3 |
| Real restaurant | +1 | +3 |
| Synthetic restaurant | 0 | +2 |
| One colleague close by | +5 | +2 |

The two settings measured on their own, through an app's settings, Opus calls, voice and noise from one speaker at the phone, speech-to-pause gap at the far end in dB, the mean of 2-3 calls:

| Variant | Redmi A5 (default: WebRTC's) | | | Galaxy Tab A (default: Qualcomm Fluence) | | |
|---|---|---|---|---|---|---|
| | Keyboard | Babble | A colleague | Keyboard | Babble | A colleague |
| Neither | 23.8 | 12.7 | 9.6 | 10.2 | 10.4 | 10.5 |
| Default only (a call today) | 27.5 | 12.7 | 9.2 | 10.6 | 10.3 | 10.1 |
| RNNoise only | 34.3 | 14.2 | 9.4 | 25.2 | 14.2 | 12.0 |
| Default and RNNoise | 32.7 | 14.4 | 8.7 | 26.2 | 14.1 | 11.8 |

RNNoise is the step that counts: +9 to +10 dB on keyboard on the Redmi A5, +15 on the Galaxy Tab A, about +1.5 and +4 on babble, nothing and +1.5 on a colleague. The default gives +3.7 dB on keyboard on the Redmi A5 and nothing anywhere else. RNNoise with the default against RNNoise alone differs within the spread (keyboard calls of one variant differed by up to 9 dB on the Redmi A5, 3 on the Galaxy Tab A). The voice stayed within 0.2 dB on the Redmi A5 and fell 0.5-0.7 dB on the Galaxy Tab A with RNNoise on. Every frame was denoised (`unchanged=0`), p99 1.2 ms and 3.6-4.0 ms. On the Galaxy Tab A `dumpsys media.audio_flinger` shows Fluence's suppressor `enabled=y` with the default on and `enabled=n` with it off; on the Redmi A5 the default is inside libwebrtc, where that dump does not reach.

On a PCMU call on the Redmi A5, one run with the switch on against off: babble +6.2, keyboard +1.0, colleague +0.1 dB, the voice within 0.2 dB. On an iPhone over Apple's processing, one run: the gap went from 9.9 to 20.3 dB on keyboard and from 10.4 to 23.8 on a real crowd, and did not improve on babble, a restaurant or a colleague (11.1 to 8.4, 8.7 to 7.6, 4.2 to 3.0).

With a person holding a Redmi A5 as in a call, read offline from the slot's input: the voice did not change (0.0 dB). With the person silent RNNoise took 7 and 2 dB off keyboard noise in two takes, and under 1 dB off babble or a colleague: it keeps whatever sounds like a voice, so another person's speech mostly passes.

So: it is worth having against keyboards and other noise that is not a voice, it does not make a neighbour's voice go away, and it does no harm to the default running before it. Echo was not worse with it on the Galaxy Tab A (the Redmi A5 has no reference run). The numbers above say nothing of artefacts.
