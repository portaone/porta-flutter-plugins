package com.portaone.flutter_webrtc_noise_suppression

import java.util.concurrent.ConcurrentHashMap

/**
 * The engines `attach` and `measure` can name, each by the name the Dart side sends.
 *
 * Internal to the plugin: an app picks one of the engines the plugin ships
 * (`WebrtcNoiseSuppressionEngine.rnnoise`), it does not bring its own. A new engine comes as a
 * pull request: its [NoiseSuppressor], one line in the `init` block below, its name in Dart (see
 * docs/adding-an-engine.md). The plugin, the chain and the [FormatAdapter] do not change for
 * it. Safe to use from any thread; a factory runs off the main thread and may take its time
 * (loading a model).
 */
internal object NoiseSuppressorRegistry {
    /** Creates a fresh engine; throws (or runs out of memory) when it cannot. */
    fun interface Factory {
        fun create(): NoiseSuppressor
    }

    /** The name of RNNoise v0.1.1, the default engine. */
    const val RNNOISE = "rnnoise"

    /** The name of RNNoise v0.2 with its standard model, under evaluation beside v0.1.1. */
    const val RNNOISE_02 = "rnnoise-0.2"

    private val factories = ConcurrentHashMap<String, Factory>()

    init {
        register(RNNOISE) { RnnoiseSuppressor() }
        // Only in a build that has it (gradle property flutter_webrtc_noise_suppression.rnnoise02).
        if (hasRnnoise02()) {
            register(RNNOISE_02) { RnnoiseSuppressor(RnnoiseSuppressor.Model.V0_2) }
        }
    }

    /**
     * Asks the native library; a library that does not load (an ABI it was not built for, a JVM
     * test) leaves v0.2 out instead of failing the registry, so RNNoise v0.1.1 still reports its own
     * error at attach.
     */
    private fun hasRnnoise02(): Boolean =
        try {
            RnnoiseSuppressor.isAvailable(RnnoiseSuppressor.Model.V0_2)
        } catch (e: Throwable) {
            false
        }

    /** Adds the engine [name], or replaces the one of that name. */
    fun register(
        name: String,
        factory: Factory,
    ) {
        factories[name] = factory
    }

    /** Removes the engine [name]; a suppressor already in the slot stays until it is detached. */
    fun unregister(name: String) {
        factories.remove(name)
    }

    /** The names registered, sorted. */
    fun names(): List<String> = factories.keys.sorted()

    fun factory(name: String): Factory? = factories[name]
}
