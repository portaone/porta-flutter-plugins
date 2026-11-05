package com.portaone.flutter_webrtc_noise_suppression

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The adapter on the JVM, with engines that only copy or count: no native library, no phone. */
class FormatAdapterTest {
    /** Leaves its frames as they are, at the format it names; counts the frames it was given. */
    private class Identity(
        private val rate: Int,
        private val frame: Int,
        private val answer: NoiseSuppressor.Result = NoiseSuppressor.Result.PROCESSED,
    ) : NoiseSuppressor {
        var lengths = mutableSetOf<Int>()
        var initializedAt = 0
        var level = 1f

        override fun setSuppressionLevel(level: Float) {
            this.level = level
        }

        override fun takeVoiceProbability() = 0.75f

        override fun engine() = "identity $rate/$frame"

        override fun initialize(sampleRateHz: Int): Boolean {
            initializedAt = sampleRateHz
            return rate == 0 || sampleRateHz == rate
        }

        override fun process(
            frame: ByteBuffer,
            numSamples: Int,
        ): NoiseSuppressor.Result {
            lengths += numSamples
            return answer
        }

        override fun release() {}

        override fun engineSampleRateHz() = rate

        override fun engineFrameSize() = frame
    }

    private val slot = 48_000
    private val n = 480

    /** [seconds] of [signal] through [adapter] in 10 ms frames, as the slot hands them over. */
    private fun run(
        adapter: NoiseSuppressor,
        seconds: Int,
        signal: (Int) -> Float,
    ): Pair<FloatArray, List<NoiseSuppressor.Result>> {
        val frame = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder())
        val out = FloatArray(seconds * slot)
        val results = mutableListOf<NoiseSuppressor.Result>()
        for (f in 0 until seconds * 100) {
            for (i in 0 until n) frame.putFloat(4 * i, signal(f * n + i))
            frame.position(0)
            results += adapter.process(frame, n)
            for (i in 0 until n) out[f * n + i] = frame.getFloat(4 * i)
        }
        return out to results
    }

    private fun sine(hz: Double) = { t: Int -> (10_000 * Math.sin(2 * Math.PI * hz * t / slot)).toFloat() }

    private fun rms(
        x: FloatArray,
        from: Int,
    ): Double {
        var s = 0.0
        for (i in from until x.size) s += x[i].toDouble() * x[i]
        return Math.sqrt(s / (x.size - from))
    }

    /** The largest normalized correlation of out against the input delayed by 0..maxLag samples. */
    private fun bestLag(
        out: FloatArray,
        signal: (Int) -> Float,
        maxLag: Int,
    ): Pair<Int, Double> {
        var best = 0 to -1.0
        val from = slot / 2
        for (lag in 0..maxLag) {
            var xy = 0.0
            var xx = 0.0
            var yy = 0.0
            for (i in from until out.size) {
                val x = signal(i - lag).toDouble()
                xy += x * out[i]
                xx += x * x
                yy += out[i].toDouble() * out[i]
            }
            val c = xy / Math.sqrt(xx * yy)
            if (c > best.second) best = lag to c
        }
        return best
    }

    @Test
    fun anEngineOfTheSlotFormatGetsTheFramesAsTheyAre() {
        val engine = Identity(0, 0)
        val adapter = FormatAdapter(engine)
        assertTrue(adapter.initialize(slot))
        assertEquals(0, adapter.latencySamples)
        val (out, _) = run(adapter, 1, sine(1000.0))
        for (i in out.indices) assertEquals(sine(1000.0)(i), out[i], 0f)
        assertEquals(setOf(n), engine.lengths)
        assertEquals(slot, engine.initializedAt)
    }

    @Test
    fun a16kHzEngineGetsItsOwnFramesAndTheVoiceBandComesBack() {
        val engine = Identity(16_000, 160)
        val adapter = FormatAdapter(engine)
        assertTrue(adapter.initialize(slot))
        assertEquals(16_000, engine.initializedAt)
        val (out, results) = run(adapter, 2, sine(1000.0))
        assertEquals(setOf(160), engine.lengths)
        assertTrue(results.all { it == NoiseSuppressor.Result.PROCESSED })
        val (lag, corr) = bestLag(out, sine(1000.0), adapter.latencySamples + 48)
        assertTrue("correlation $corr at lag $lag", corr > 0.9999)
        assertTrue("lag $lag within ${adapter.latencySamples}", lag <= adapter.latencySamples)
        val gainDb = 20 * Math.log10(rms(out, slot / 2) / (10_000 / Math.sqrt(2.0)))
        assertEquals("gain $gainDb dB", 0.0, gainDb, 0.2)
    }

    @Test
    fun aFrameLengthThatIsNot10msIsGathered() {
        val engine = Identity(16_000, 256)
        val adapter = FormatAdapter(engine)
        assertTrue(adapter.initialize(slot))
        val (out, _) = run(adapter, 2, sine(440.0))
        assertEquals(setOf(256), engine.lengths)
        val (_, corr) = bestLag(out, sine(440.0), adapter.latencySamples + 48)
        assertTrue("correlation $corr", corr > 0.9999)
    }

    /** [seconds] of [signal] at [rate] through [adapter] in 10 ms frames. */
    private fun runAt(
        adapter: NoiseSuppressor,
        rate: Int,
        seconds: Int,
        signal: (Int) -> Float,
    ): FloatArray {
        val n = rate / 100
        val frame = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder())
        val out = FloatArray(seconds * rate)
        for (f in 0 until seconds * 100) {
            for (i in 0 until n) frame.putFloat(4 * i, signal(f * n + i))
            frame.position(0)
            assertEquals(NoiseSuppressor.Result.PROCESSED, adapter.process(frame, n))
            for (i in 0 until n) out[f * n + i] = frame.getFloat(4 * i)
        }
        return out
    }

    private fun sineAt(
        hz: Double,
        rate: Int,
    ) = { t: Int -> (10_000 * Math.sin(2 * Math.PI * hz * t / rate)).toFloat() }

    private fun correlationAt(
        out: FloatArray,
        signal: (Int) -> Float,
        maxLag: Int,
    ): Pair<Int, Double> {
        var best = 0 to -1.0
        for (lag in 0..maxLag) {
            var xy = 0.0
            var xx = 0.0
            var yy = 0.0
            for (i in out.size / 2 until out.size) {
                val x = signal(i - lag).toDouble()
                xy += x * out[i]
                xx += x * x
                yy += out[i].toDouble() * out[i]
            }
            val c = xy / Math.sqrt(xx * yy)
            if (c > best.second) best = lag to c
        }
        return best
    }

    @Test
    fun a48kHzEngineOnA16kHzStreamGetsItsFramesAndTheVoiceComesBack() {
        // A call on G.711 or G.722: libwebrtc's slot runs at 16 kHz, RNNoise takes 48 kHz.
        val engine = Identity(48_000, 480)
        val adapter = FormatAdapter(engine)
        assertTrue(adapter.initialize(16_000))
        assertEquals(48_000, engine.initializedAt)
        val out = runAt(adapter, 16_000, 2, sineAt(1000.0, 16_000))
        assertEquals(setOf(480), engine.lengths)
        val (lag, corr) = correlationAt(out, sineAt(1000.0, 16_000), adapter.latencySamples + 16)
        assertTrue("correlation $corr at lag $lag", corr > 0.9999)
        assertTrue("lag $lag within ${adapter.latencySamples}", lag <= adapter.latencySamples)
        val gainDb = 20 * Math.log10(rms(out, out.size / 2) / (10_000 / Math.sqrt(2.0)))
        assertEquals("gain $gainDb dB", 0.0, gainDb, 0.2)
        assertEquals("one engine frame and the filters", (480 + 73 - 1) / 3, adapter.latencySamples)
    }

    @Test
    fun a48kHzEngineOnAn8kHzStreamWorksToo() {
        val engine = Identity(48_000, 480)
        val adapter = FormatAdapter(engine)
        assertTrue(adapter.initialize(8_000))
        val out = runAt(adapter, 8_000, 2, sineAt(440.0, 8_000))
        assertEquals(setOf(480), engine.lengths)
        val (_, corr) = correlationAt(out, sineAt(440.0, 8_000), adapter.latencySamples + 8)
        assertTrue("correlation $corr", corr > 0.9999)
    }

    @Test
    fun whatTheLowerRateCannotCarryIsFilteredOut() {
        val adapter = FormatAdapter(Identity(16_000, 160))
        assertTrue(adapter.initialize(slot))
        val (out, _) = run(adapter, 2, sine(12_000.0))
        val db = 20 * Math.log10(rms(out, slot / 2) / (10_000 / Math.sqrt(2.0)))
        assertTrue("12 kHz through a 16 kHz engine: $db dB", db < -40)
    }

    @Test
    fun aRateTheStreamDoesNotDivideLeavesFramesUnchanged() {
        val adapter = FormatAdapter(Identity(44_100, 441))
        assertFalse(adapter.initialize(slot))
        val (out, results) = run(adapter, 1, sine(1000.0))
        assertTrue(results.all { it == NoiseSuppressor.Result.UNSUPPORTED_RATE })
        for (i in out.indices) assertEquals(sine(1000.0)(i), out[i], 0f)
    }

    @Test
    fun anEngineThatRefusesAFrameIsReported() {
        val adapter = FormatAdapter(Identity(16_000, 160, NoiseSuppressor.Result.INVALID))
        assertTrue(adapter.initialize(slot))
        val (_, results) = run(adapter, 1, sine(1000.0))
        assertTrue(results.all { it == NoiseSuppressor.Result.INVALID })
    }

    @Test
    fun theLevelReachesTheEngineThroughTheAdapter() {
        val engine = Identity(16_000, 160)
        FormatAdapter(engine).setSuppressionLevel(0.25f)
        assertEquals(0.25f, engine.level, 0f)
    }

    @Test
    fun theVoiceProbabilityComesThroughTheAdapterAndIsNaNWithoutOne() {
        assertEquals(0.75f, FormatAdapter(Identity(16_000, 160)).takeVoiceProbability(), 0f)
        val plain =
            object : NoiseSuppressor {
                override fun engine() = "plain"

                override fun initialize(sampleRateHz: Int) = true

                override fun process(
                    frame: ByteBuffer,
                    numSamples: Int,
                ) = NoiseSuppressor.Result.PROCESSED

                override fun release() {}
            }
        assertTrue(FormatAdapter(plain).takeVoiceProbability().isNaN())
    }

    @Test
    fun theRegistryNamesRnnoiseAndTakesAnotherEngine() {
        assertTrue(NoiseSuppressorRegistry.RNNOISE in NoiseSuppressorRegistry.names())
        NoiseSuppressorRegistry.register("test-identity") { Identity(16_000, 160) }
        try {
            assertTrue("test-identity" in NoiseSuppressorRegistry.names())
            assertEquals("identity 16000/160", NoiseSuppressorRegistry.factory("test-identity")!!.create().engine())
        } finally {
            NoiseSuppressorRegistry.unregister("test-identity")
        }
        assertFalse("test-identity" in NoiseSuppressorRegistry.names())
    }
}
