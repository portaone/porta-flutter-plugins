package com.portaone.flutter_webrtc_noise_suppression

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Puts an engine that works at another rate or frame length into the slot's 10 ms frames.
 *
 * The engine names its format through [NoiseSuppressor.engineSampleRateHz] and
 * [NoiseSuppressor.engineFrameSize]. When that is the stream's own (RNNoise: 48 kHz, 480 samples),
 * the adapter hands the frames over as they are. When the stream's rate is a whole multiple of the
 * engine's, the stream is low-passed and decimated (48 kHz to 16 kHz is 3), gathered into the
 * engine's frames, denoised, and interpolated back with the same filter. When the engine's rate is a
 * whole multiple of the stream's, the other way round: interpolated up (a call on G.711 or G.722
 * gives libwebrtc's slot 16 kHz, RNNoise takes 48 kHz), denoised, decimated back. Either way it
 * costs a delay of [latencySamples]: one engine frame and a little more for the filters. Rates of no
 * whole ratio are not taken; their frames come back unchanged.
 *
 * Buffers are allocated in [initialize]; [process] allocates nothing and is meant for the audio
 * thread. Calls are serialized by the caller, as for any [NoiseSuppressor].
 */
internal class FormatAdapter(
    private val inner: NoiseSuppressor,
) : NoiseSuppressor {
    private var passthrough = true
    private var supported = false
    private var upward = false // the engine's rate above the stream's
    private var factor = 1
    private var engineFrame = 0

    private var taps = FloatArray(0)
    private var poly = FloatArray(0) // poly[p * polyLen + m] = taps[p + m * factor] * factor
    private var polyLen = 0
    private var down = FloatArray(0) // the last taps.size samples of the stream, a ring
    private var downPos = 0
    private var downPhase = 0
    private var up = FloatArray(0) // the last polyLen samples of the engine's output, a ring
    private var upPos = 0
    private var upPhase = 0
    private var engineIn: ByteBuffer = ByteBuffer.allocateDirect(0)
    private var engineFill = 0
    private var fifo = FloatArray(0) // engine output waiting to be interpolated, a ring
    private var fifoRead = 0
    private var fifoCount = 0
    private var input = FloatArray(0) // upward: the stream's last polyLen samples, a ring
    private var inputPos = 0

    /** The delay the adapter adds, in samples of the stream; 0 when frames pass as they are. */
    var latencySamples = 0
        private set

    override fun engine(): String = inner.engine()

    override fun setSuppressionLevel(level: Float) = inner.setSuppressionLevel(level)

    override fun takeVoiceProbability(): Float = inner.takeVoiceProbability()

    override fun engineSampleRateHz(): Int = 0

    override fun engineFrameSize(): Int = 0

    override fun initialize(sampleRateHz: Int): Boolean {
        val rate = inner.engineSampleRateHz().let { if (it == 0) sampleRateHz else it }
        val frame = inner.engineFrameSize().let { if (it == 0) rate / 100 else it }
        if (rate == sampleRateHz && frame == sampleRateHz / 100) {
            passthrough = true
            supported = true
            latencySamples = 0
            return inner.initialize(sampleRateHz)
        }
        passthrough = false
        if (rate <= 0 || frame <= 0 || sampleRateHz <= 0) {
            supported = false
            return false
        }
        if (rate > sampleRateHz && rate % sampleRateHz == 0) return initializeUpward(sampleRateHz, rate, frame)
        if (sampleRateHz % rate != 0) {
            supported = false
            return false
        }
        upward = false
        factor = sampleRateHz / rate
        engineFrame = frame
        taps = lowPass(factor)
        polyLen = (taps.size + factor - 1) / factor
        poly = FloatArray(factor * polyLen)
        for (p in 0 until factor) {
            for (m in 0 until polyLen) {
                val k = p + m * factor
                poly[p * polyLen + m] = if (k < taps.size) taps[k] * factor else 0f
            }
        }
        down = FloatArray(taps.size)
        downPos = 0
        downPhase = 0
        up = FloatArray(polyLen)
        upPos = 0
        upPhase = 0
        engineIn = ByteBuffer.allocateDirect(frame * 4).order(ByteOrder.nativeOrder())
        engineFill = 0
        // One engine frame of silence ahead, so the interpolator never waits for the engine.
        val prefill = frame + 1
        fifo = FloatArray(2 * frame + 2)
        fifoRead = 0
        fifoCount = prefill
        latencySamples = prefill * factor + taps.size - 1
        supported = inner.initialize(rate)
        return supported
    }

    /** The stream below the engine: [rate] is [sampleRateHz] times a whole factor. */
    private fun initializeUpward(
        sampleRateHz: Int,
        rate: Int,
        frame: Int,
    ): Boolean {
        upward = true
        factor = rate / sampleRateHz
        engineFrame = frame
        taps = lowPass(factor)
        polyLen = (taps.size + factor - 1) / factor
        poly = FloatArray(factor * polyLen)
        for (p in 0 until factor) {
            for (m in 0 until polyLen) {
                val k = p + m * factor
                poly[p * polyLen + m] = if (k < taps.size) taps[k] * factor else 0f
            }
        }
        input = FloatArray(polyLen)
        inputPos = 0
        down = FloatArray(taps.size)
        downPos = 0
        engineIn = ByteBuffer.allocateDirect(frame * 4).order(ByteOrder.nativeOrder())
        engineFill = 0
        // At least one engine frame of silence ahead, so the decimator never waits for the engine.
        // The decimator reads the last of every `factor` samples; a prefill of factor - 1 beyond a
        // whole number of stream samples puts its output on the stream's own grid, so the delay is
        // a whole number of stream samples rather than a fraction of one.
        val ahead = (frame + factor - 1) / factor
        fifo = FloatArray(2 * frame + 2 * factor)
        fifoRead = 0
        fifoCount = ahead * factor + factor - 1
        latencySamples = ahead + (taps.size - 1) / factor
        supported = inner.initialize(rate)
        return supported
    }

    override fun process(
        frame: ByteBuffer,
        numSamples: Int,
    ): NoiseSuppressor.Result {
        if (passthrough) return inner.process(frame, numSamples)
        if (!supported) return NoiseSuppressor.Result.UNSUPPORTED_RATE
        if (!frame.isDirect || frame.remaining() < numSamples * 4) return NoiseSuppressor.Result.INVALID
        if (upward) return processUpward(frame, numSamples)
        if (numSamples % factor != 0) return NoiseSuppressor.Result.UNSUPPORTED_FRAME
        // The slot's buffer wraps native memory: read it in native order. order() sets the buffer's
        // flag and allocates nothing.
        frame.order(ByteOrder.nativeOrder())
        val base = frame.position()
        var result = NoiseSuppressor.Result.PROCESSED
        for (i in 0 until numSamples) {
            down[downPos] = frame.getFloat(base + 4 * i)
            downPos = if (downPos + 1 == down.size) 0 else downPos + 1
            if (++downPhase == factor) {
                downPhase = 0
                // The filter is symmetric, so the ring can be read from its oldest sample on.
                var acc = 0f
                var j = downPos
                for (k in taps.indices) {
                    acc += taps[k] * down[j]
                    j = if (j + 1 == down.size) 0 else j + 1
                }
                engineIn.putFloat(4 * engineFill, acc)
                if (++engineFill == engineFrame) {
                    engineFill = 0
                    engineIn.position(0)
                    val r = inner.process(engineIn, engineFrame)
                    if (r != NoiseSuppressor.Result.PROCESSED) result = r
                    for (n in 0 until engineFrame) {
                        fifo[(fifoRead + fifoCount) % fifo.size] = engineIn.getFloat(4 * n)
                        fifoCount++
                    }
                }
            }
            if (upPhase == 0) {
                up[upPos] = fifo[fifoRead]
                upPos = if (upPos + 1 == up.size) 0 else upPos + 1
                fifoRead = if (fifoRead + 1 == fifo.size) 0 else fifoRead + 1
                fifoCount--
            }
            // Polyphase interpolation: the newest engine sample meets the filter's phase upPhase.
            var acc = 0f
            var j = if (upPos == 0) up.size - 1 else upPos - 1
            val row = upPhase * polyLen
            for (m in 0 until polyLen) {
                acc += poly[row + m] * up[j]
                j = if (j == 0) up.size - 1 else j - 1
            }
            upPhase = if (upPhase + 1 == factor) 0 else upPhase + 1
            frame.putFloat(base + 4 * i, acc)
        }
        return result
    }

    /** The stream below the engine: every sample interpolated to `factor` engine samples and back. */
    private fun processUpward(
        frame: ByteBuffer,
        numSamples: Int,
    ): NoiseSuppressor.Result {
        frame.order(ByteOrder.nativeOrder())
        val base = frame.position()
        var result = NoiseSuppressor.Result.PROCESSED
        for (i in 0 until numSamples) {
            input[inputPos] = frame.getFloat(base + 4 * i)
            inputPos = if (inputPos + 1 == input.size) 0 else inputPos + 1
            // Polyphase interpolation: `factor` engine samples from the newest stream samples.
            for (p in 0 until factor) {
                var acc = 0f
                var j = if (inputPos == 0) input.size - 1 else inputPos - 1
                val row = p * polyLen
                for (m in 0 until polyLen) {
                    acc += poly[row + m] * input[j]
                    j = if (j == 0) input.size - 1 else j - 1
                }
                engineIn.putFloat(4 * engineFill, acc)
                if (++engineFill == engineFrame) {
                    engineFill = 0
                    engineIn.position(0)
                    val r = inner.process(engineIn, engineFrame)
                    if (r != NoiseSuppressor.Result.PROCESSED) result = r
                    for (n in 0 until engineFrame) {
                        fifo[(fifoRead + fifoCount) % fifo.size] = engineIn.getFloat(4 * n)
                        fifoCount++
                    }
                }
            }
            // Decimation: `factor` engine samples in, one stream sample out.
            for (u in 0 until factor) {
                down[downPos] = fifo[fifoRead]
                downPos = if (downPos + 1 == down.size) 0 else downPos + 1
                fifoRead = if (fifoRead + 1 == fifo.size) 0 else fifoRead + 1
                fifoCount--
            }
            var acc = 0f
            var j = downPos
            for (k in taps.indices) {
                acc += taps[k] * down[j]
                j = if (j + 1 == down.size) 0 else j + 1
            }
            frame.putFloat(base + 4 * i, acc)
        }
        return result
    }

    override fun release() = inner.release()

    companion object {
        private val warm = java.util.concurrent.atomic.AtomicBoolean(false)

        /**
         * Runs the adapter's code over a second of silence once per process, off the audio thread.
         * ART interprets a method before it compiles it, and the first frames through a fresh
         * adapter took up to 12 ms on a Galaxy Tab A (SM-T505) against 0.5 ms once compiled; the
         * plugin calls this before an adapted engine reaches the slot.
         */
        fun warmUp() {
            if (!warm.compareAndSet(false, true)) return
            // Both ways: a 16 kHz engine on the 48 kHz stream, a 48 kHz engine on a 16 kHz one.
            warmUp(engineRate = 16_000, streamRate = 48_000)
            warmUp(engineRate = 48_000, streamRate = 16_000)
        }

        private fun warmUp(
            engineRate: Int,
            streamRate: Int,
        ) {
            val engine =
                object : NoiseSuppressor {
                    override fun engine() = "warm-up"

                    override fun initialize(sampleRateHz: Int) = true

                    override fun process(
                        frame: ByteBuffer,
                        numSamples: Int,
                    ) = NoiseSuppressor.Result.PROCESSED

                    override fun release() {}

                    override fun engineSampleRateHz() = engineRate

                    override fun engineFrameSize() = engineRate / 100
                }
            val adapter = FormatAdapter(engine)
            adapter.initialize(streamRate)
            val n = streamRate / 100
            val frame = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder())
            repeat(100) {
                frame.position(0)
                adapter.process(frame, n)
            }
        }

        /**
         * A windowed-sinc low-pass (Blackman) for decimating and interpolating by [factor]: cut at
         * 0.9 of the lower rate's Nyquist, 24 taps per factor, unit gain at DC.
         */
        private fun lowPass(factor: Int): FloatArray {
            val n = 24 * factor + 1
            val cutoff = 0.45 / factor
            val center = (n - 1) / 2.0
            val h = DoubleArray(n)
            for (i in 0 until n) {
                val x = i - center
                val sinc = if (x == 0.0) 2 * cutoff else Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x)
                val window = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / (n - 1)) + 0.08 * Math.cos(4 * Math.PI * i / (n - 1))
                h[i] = sinc * window
            }
            val sum = h.sum()
            return FloatArray(n) { (h[it] / sum).toFloat() }
        }
    }
}
