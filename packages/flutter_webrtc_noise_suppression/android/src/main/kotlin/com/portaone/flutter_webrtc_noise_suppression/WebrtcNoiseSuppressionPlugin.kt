package com.portaone.flutter_webrtc_noise_suppression

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.audio.AudioProcessingController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Puts a chain of [NoiseSuppressor]s into flutter_webrtc's capture post-processing slot of one
 * engine.
 *
 * The two plugins know nothing about each other: flutter_webrtc offers the slot through
 * [AudioProcessingAdapter.ExternalAudioFrameProcessing], noise_suppression offers
 * [NoiseSuppressor]. This plugin is the only place that joins them, so neither depends on the
 * other. Engines are found by name in [NoiseSuppressorRegistry]; one of another rate or frame length
 * goes through a [FormatAdapter]. A new engine of the plugin is registered there, not added here.
 *
 * Flutter registers the plugin on every engine that registers plugins, and each engine has its
 * own flutter_webrtc: the instance is bound to the engine it was attached to and reaches that
 * engine's flutter_webrtc, never [FlutterWebRTCPlugin.sharedSingleton], which names whichever
 * engine was created last (a background push engine has a factory that is never initialized).
 * The slot belongs to that engine's peer connection factory, so one attached processor covers
 * every call of the engine.
 *
 * Every method call runs on the main thread. Engines are created on one worker thread, since a
 * model may take most of a second to load, and go into the slot back on the main thread; a later
 * attach or a detach makes an attach still creating its engines answer false and free them.
 */
class WebrtcNoiseSuppressionPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var vadChannel: EventChannel? = null
    private var vadSink: EventChannel.EventSink? = null
    private var engine: FlutterEngine? = null
    private var filesDir: java.io.File? = null
    private var controller: AudioProcessingController? = null
    private var processor: ChainProcessor? = null
    private var generation = 0
    private var suppressionLevel = 1f
    private var worker: ExecutorService? = null
    private val main = Handler(Looper.getMainLooper())

    @Suppress("DEPRECATION")
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engine = binding.flutterEngine
        filesDir = binding.applicationContext.getExternalFilesDir(null)
        worker = Executors.newSingleThreadExecutor { Thread(it, "WebrtcNoiseSuppression").apply { isDaemon = true } }
        channel =
            MethodChannel(binding.binaryMessenger, CHANNEL).also {
                it.setMethodCallHandler(this)
            }
        vadChannel =
            EventChannel(binding.binaryMessenger, "$CHANNEL/vad").also {
                it.setStreamHandler(
                    object : EventChannel.StreamHandler {
                        override fun onListen(
                            arguments: Any?,
                            events: EventChannel.EventSink,
                        ) {
                            vadSink = events
                            main.removeCallbacks(vadTick)
                            main.postDelayed(vadTick, VAD_INTERVAL_MS)
                        }

                        override fun onCancel(arguments: Any?) {
                            vadSink = null
                            main.removeCallbacks(vadTick)
                        }
                    },
                )
            }
    }

    /**
     * Every [VAD_INTERVAL_MS] on the main thread while Dart listens: the chain's highest voice
     * probability since the last tick, one event, none when no engine of the chain detects voice
     * or no frame came. The audio thread only raises an atomic value; nothing here waits for it.
     */
    private val vadTick =
        object : Runnable {
            override fun run() {
                val sink = vadSink ?: return
                val peak = processor?.takeVoiceProbability() ?: Float.NaN
                if (!peak.isNaN()) sink.success(peak.toDouble())
                main.postDelayed(this, VAD_INTERVAL_MS)
            }
        }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detach()
        worker?.shutdown()
        worker = null
        channel?.setMethodCallHandler(null)
        channel = null
        main.removeCallbacks(vadTick)
        vadChannel?.setStreamHandler(null)
        vadChannel = null
        vadSink = null
        engine = null
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "attach" -> {
                val names = engineNames(call)
                val unknown = names.firstOrNull { NoiseSuppressorRegistry.factory(it) == null }
                when {
                    names.isEmpty() -> result.error("no_engine", "attach names no engine", null)
                    unknown != null -> result.error("unknown_engine", "unknown engine $unknown", null)
                    else -> {
                        setSuppressionLevel(call.argument<Double>("suppressionLevel") ?: 1.0)
                        attach(names, call.argument<Int>("dumpInputSeconds") ?: 0, result)
                    }
                }
            }
            "detach" -> result.success(detach())
            "setSuppressionLevel" -> {
                setSuppressionLevel(call.argument<Double>("level") ?: 1.0)
                result.success(null)
            }
            "registerTestEngines" -> {
                TestEngines.register()
                result.success(null)
            }
            "measure" -> {
                val name = call.argument<String>("engine") ?: NoiseSuppressorRegistry.RNNOISE
                val factory = NoiseSuppressorRegistry.factory(name)
                if (factory == null) {
                    result.error("unknown_engine", "unknown engine $name", null)
                } else {
                    // 3 s of audio is a few hundred ms of work on a slow phone: off the main thread.
                    Thread {
                        val measured =
                            try {
                                measure(factory)
                            } catch (e: Throwable) {
                                Log.w(TAG, "measure: $name not created", e)
                                null
                            }
                        main.post {
                            if (measured == null) {
                                result.error("no_engine", "engine $name not created", null)
                            } else {
                                result.success(measured)
                            }
                        }
                    }.start()
                }
            }
            else -> result.notImplemented()
        }
    }

    /** The level of the chain in the slot, and of the next one. The engines take it atomically. */
    private fun setSuppressionLevel(level: Double) {
        suppressionLevel = level.toFloat()
        processor?.setSuppressionLevel(suppressionLevel)
    }

    /**
     * Puts a chain of the engines [names], in that order, into the slot, and answers true when it is
     * there. A chain already in the slot is taken out first: the slot holds one chain at a time. The
     * same chain again is left as it is.
     */
    private fun attach(
        names: List<String>,
        dumpInputSeconds: Int,
        result: MethodChannel.Result,
    ) {
        if (processor?.names == names && dumpInputSeconds == 0) {
            // Still the chain asked for last: an attach of another chain still creating is dropped.
            generation++
            result.success(true)
            return
        }
        val pool = worker
        if (pool == null) {
            result.success(false)
            return
        }
        val asked = ++generation
        pool.execute {
            val start = System.nanoTime()
            val stages = create(names)
            val createMs = (System.nanoTime() - start) / 1_000_000
            main.post {
                if (stages == null) {
                    result.success(false)
                } else if (asked != generation) {
                    // A later attach or a detach came while these were created.
                    stages.forEach { it.release() }
                    result.success(false)
                } else {
                    result.success(install(names, stages, dumpInputSeconds, createMs))
                }
            }
        }
    }

    /** Fresh engines of [names], each in a [FormatAdapter]; null (and none left) when one fails. */
    private fun create(names: List<String>): List<Stage>? {
        FormatAdapter.warmUp()
        val stages = mutableListOf<Stage>()
        for (name in names) {
            try {
                val suppressor = NoiseSuppressorRegistry.factory(name)?.create() ?: error("unregistered")
                stages += Stage(name, FormatAdapter(suppressor))
            } catch (e: Throwable) {
                // An OutOfMemoryError of the state or a missing native library leaves the call with
                // the platform processing only, which is what it had before.
                Log.w(TAG, "not attached: engine $name not created", e)
                stages.forEach { it.release() }
                return null
            }
        }
        return stages
    }

    /** On the main thread: [stages] into the slot, after the chain that was there. */
    private fun install(
        names: List<String>,
        stages: List<Stage>,
        dumpInputSeconds: Int,
        createMs: Long,
    ): Boolean {
        // Looked up at call time: the plugins of an engine are registered in no fixed order.
        val webrtc = engine?.plugins?.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin
        // The controller exists once flutter_webrtc has built its peer connection factory, which
        // happens before the first microphone track is opened.
        val found = webrtc?.audioProcessingController
        if (found == null) {
            Log.w(TAG, "not attached: flutter_webrtc audio processing is not initialized")
            stages.forEach { it.release() }
            return false
        }
        if (processor != null) remove()

        // Diagnostics: the frames that reach the slot, before the chain, kept in memory for the
        // given seconds and written on detach. The buffer is allocated here, not per frame.
        val dump = if (dumpInputSeconds > 0) ShortArray(dumpInputSeconds * 48_000) else null
        val created = ChainProcessor(names, stages, dump)
        created.setSuppressionLevel(suppressionLevel)
        found.capturePostProcessing.addProcessor(created)
        controller = found
        processor = created
        Log.i(TAG, "attached ${stages.joinToString(" > ") { it.suppressor.engine() }} create_ms=$createMs")
        return true
    }

    /**
     * Runs 3 s of white noise through a fresh engine, frame by frame as the slot would, through the
     * same [FormatAdapter]: the time per frame on this phone and the attenuation once the model has
     * settled (the first second is skipped). A check of the engine on a device, not of call quality.
     */
    private fun measure(factory: NoiseSuppressorRegistry.Factory): Map<String, Any> {
        FormatAdapter.warmUp()
        val suppressor = FormatAdapter(factory.create())
        try {
            suppressor.initialize(SLOT_RATE)
            val n = SLOT_RATE / 100
            val frame = ByteBuffer.allocateDirect(n * 4).order(java.nio.ByteOrder.nativeOrder())
            val floats = frame.asFloatBuffer()
            // The generator of the C test and of iOS, so the three report on the same noise.
            var seed = 12345

            val times = LongArray(300)
            var inRms = 0.0
            var outRms = 0.0
            for (f in 0 until 300) {
                var before = 0.0
                for (i in 0 until n) {
                    seed = seed * 1103515245 + 12345
                    val v = 3000f * (((seed ushr 8) and 0xffff) / 32768f - 1f)
                    floats.put(i, v)
                    before += v * v
                }
                val start = System.nanoTime()
                suppressor.process(frame, n)
                times[f] = System.nanoTime() - start
                if (f >= 100) {
                    var after = 0.0
                    for (i in 0 until n) after += floats.get(i).toDouble() * floats.get(i)
                    inRms += Math.sqrt(before / n)
                    outRms += Math.sqrt(after / n)
                }
            }
            times.sort()
            return mapOf(
                "engine" to suppressor.engine(),
                "meanUs" to times.average() / 1000.0,
                "p99Us" to times[(times.size * 99) / 100] / 1000.0,
                "attenuationDb" to 20 * Math.log10(inRms / outRms),
                "latencyMs" to suppressor.latencySamples * 1000.0 / SLOT_RATE,
            )
        } finally {
            suppressor.release()
        }
    }

    /** Returns true when a chain was in the slot and has been removed; an attach still creating is dropped. */
    private fun detach(): Boolean {
        generation++
        return remove()
    }

    private fun remove(): Boolean {
        val attached = processor ?: return false
        // The adapter calls processors under the lock that removeProcessor takes, so once it
        // returns no frame is in flight and the native state can be freed.
        controller?.capturePostProcessing?.removeProcessor(attached)
        attached.release()
        attached.writeDump(filesDir)?.let { Log.i(TAG, "slot input written to $it") }
        processor = null
        controller = null
        attached.summary().forEach { Log.i(TAG, "detached: $it") }
        return true
    }

    private companion object {
        const val TAG = "WebrtcNoiseSuppression"
        const val CHANNEL = "com.portaone.flutter_webrtc_noise_suppression"
        const val SLOT_RATE = 48_000
        const val VAD_INTERVAL_MS = 100L

        /** The chain a call names: `engines`, or the older single `engine`, or RNNoise v0.1.1. */
        fun engineNames(call: MethodCall): List<String> =
            call.argument<List<String>>("engines")
                ?: listOf(call.argument<String>("engine") ?: NoiseSuppressorRegistry.RNNOISE)
    }
}

/** One engine of a chain and what it did in the call. */
private class Stage(
    val name: String,
    val suppressor: NoiseSuppressor,
) {
    var processed = 0L
    var unchanged = 0L
    var lastResult: NoiseSuppressor.Result? = null

    // Time per frame in the call, without allocating on the audio thread: 200 us buckets up to
    // 20 ms, the last one for everything longer.
    val buckets = IntArray(BUCKETS + 1)
    var totalNs = 0L
    var maxNs = 0L

    fun release() = suppressor.release()

    fun summary(announced: CharSequence): String {
        val frames = processed + unchanged
        val meanUs = if (frames == 0L) 0 else totalNs / frames / 1000
        return "${suppressor.engine()} processed=$processed unchanged=$unchanged" +
            " mean_us=$meanUs p99_us=${percentileUs(0.99)} max_us=${maxNs / 1000}" +
            " over_10ms=${overBudget()} $announced"
    }

    /** The upper edge of the bucket the [q] quantile falls in; the last bucket reads as its floor. */
    private fun percentileUs(q: Double): Long {
        val frames = buckets.sum()
        if (frames == 0) return 0
        var seen = 0
        for (i in buckets.indices) {
            seen += buckets[i]
            if (seen >= q * frames) return (if (i == BUCKETS) i else i + 1) * BUCKET_NS / 1000
        }
        return BUCKETS * BUCKET_NS / 1000
    }

    /** Frames that took longer than the 10 ms they hold. */
    private fun overBudget(): Int {
        var over = 0
        for (i in (10_000_000 / BUCKET_NS).toInt()..BUCKETS) over += buckets[i]
        return over
    }

    companion object {
        const val BUCKET_NS = 200_000L
        const val BUCKETS = 100
    }
}

/**
 * Adapts flutter_webrtc's frames to a chain of [NoiseSuppressor]s: each frame goes through every
 * engine in order, in place.
 *
 * libwebrtc calls it on the capture thread with 10 ms of channel 0 of the full-band buffer, after
 * its own echo cancellation, noise suppression and gain control and right before the encoder.
 * The adapter serializes all three callbacks under one lock.
 */
private class ChainProcessor(
    val names: List<String>,
    private val stages: List<Stage>,
    private val dump: ShortArray? = null,
) : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private var dumped = 0
    private var dumpRate = 0
    private var initialized = false
    private val announced = StringBuilder()

    override fun initialize(
        sampleRateHz: Int,
        numChannels: Int,
    ) {
        note("initialize($sampleRateHz, $numChannels)")
        stages.forEach { it.suppressor.initialize(sampleRateHz) }
        initialized = true
    }

    override fun reset(newRate: Int) {
        note("reset($newRate)")
        stages.forEach { it.suppressor.initialize(newRate) }
        initialized = true
    }

    override fun process(
        numBands: Int,
        numFrames: Int,
        buffer: ByteBuffer,
    ) {
        // A processor added while the microphone is already running is never told the rate:
        // the adapter announces it only when the stream starts. A frame is 10 ms, so its length
        // gives the rate.
        if (!initialized) {
            stages.forEach { it.suppressor.initialize(numFrames * 100) }
            initialized = true
        }
        // One WAV holds one rate: a call starts at 48 kHz and drops to 16 kHz once a G.711 or G.722
        // codec is chosen, so the dump starts again at the rate the call settles on.
        if (dump != null && dumpRate != numFrames * 100) {
            dumpRate = numFrames * 100
            dumped = 0
        }
        if (dump != null && dumped + numFrames <= dump.size) {
            // The buffer wraps native memory: read it in native order (Java's default is big endian).
            // A view object per frame: diagnostics only, never in a normal call.
            val floats = buffer.duplicate().order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer()
            for (i in 0 until numFrames) {
                dump[dumped + i] = floats.get(i).coerceIn(-32768f, 32767f).toInt().toShort()
            }
            dumped += numFrames
        }
        // A frame an engine cannot take comes back unchanged, so the call keeps the audio it would
        // have had without that engine.
        for (stage in stages) {
            val start = System.nanoTime()
            val result = stage.suppressor.process(buffer, numFrames)
            val spent = System.nanoTime() - start
            stage.totalNs += spent
            if (spent > stage.maxNs) stage.maxNs = spent
            stage.buckets[minOf((spent / Stage.BUCKET_NS).toInt(), Stage.BUCKETS)]++
            if (result == NoiseSuppressor.Result.PROCESSED) stage.processed++ else stage.unchanged++
            if (result != stage.lastResult) {
                stage.lastResult = result
                note("${stage.name}: $result at frame ${stage.processed + stage.unchanged} ($numFrames samples, $numBands bands)")
            }
        }
    }

    /**
     * One log line per engine: how many frames were denoised and how many left unchanged (a rate or
     * length the engine does not take), the time per frame, and what the slot announced. Read
     * after the processor left the slot, so no frame is counted at the same time.
     */
    fun summary(): List<String> = stages.map { it.summary(announced) }

    private fun note(event: String) {
        if (announced.length < 400) announced.append('[').append(event).append(']')
    }

    fun release() = stages.forEach { it.release() }

    fun setSuppressionLevel(level: Float) = stages.forEach { it.suppressor.setSuppressionLevel(level) }

    /** The highest voice probability any engine of the chain saw since the last call; NaN for none. */
    fun takeVoiceProbability(): Float {
        var peak = Float.NaN
        for (stage in stages) {
            val p = stage.suppressor.takeVoiceProbability()
            if (!p.isNaN() && (peak.isNaN() || p > peak)) peak = p
        }
        return peak
    }

    /** The dumped slot input as a 16-bit mono WAV in [dir]; null when nothing was dumped. */
    fun writeDump(dir: java.io.File?): java.io.File? {
        if (dump == null || dumped == 0 || dir == null) return null
        val file = java.io.File(dir, "slot-input-${System.currentTimeMillis()}.wav")
        val data = dumped * 2
        val out = ByteBuffer.allocate(44 + data).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        out.put("RIFF".toByteArray()).putInt(36 + data).put("WAVE".toByteArray())
        out.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        out.putInt(dumpRate).putInt(dumpRate * 2).putShort(2).putShort(16)
        out.put("data".toByteArray()).putInt(data)
        for (i in 0 until dumped) out.putShort(dump[i])
        file.writeBytes(out.array())
        return file
    }
}
