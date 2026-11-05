package com.portaone.flutter_webrtc_noise_suppression

import java.nio.ByteBuffer

/**
 * Engines for the plugin's own device tests, registered only when a test asks
 * (`WebrtcNoiseSuppressionBridge.registerTestEngines`), never in an app's normal run.
 */
internal object TestEngines {
    /** 16 kHz in 10 ms frames, left as they are: what reaches the slot back is the format adapter's. */
    const val IDENTITY_16K = "test-identity-16k"

    fun register() {
        NoiseSuppressorRegistry.register(IDENTITY_16K) { Identity16k() }
    }

    private class Identity16k : NoiseSuppressor {
        override fun engine() = "test identity 16 kHz"

        override fun initialize(sampleRateHz: Int) = sampleRateHz == 16_000

        override fun process(
            frame: ByteBuffer,
            numSamples: Int,
        ) = if (numSamples == 160) NoiseSuppressor.Result.PROCESSED else NoiseSuppressor.Result.UNSUPPORTED_FRAME

        override fun release() {}

        override fun engineSampleRateHz() = 16_000

        override fun engineFrameSize() = 160
    }
}
