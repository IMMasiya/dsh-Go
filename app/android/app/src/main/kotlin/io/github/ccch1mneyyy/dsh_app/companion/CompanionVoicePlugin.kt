package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Her voice in 伙伴小屋: the phone's own text-to-speech, MethodChannel `dsh/companion_voice`
 * (lib/companion/companion_voice.dart). The app keeps no audio; the system's engine does what it
 * does with the text.
 *
 * `ready` starts the engine once and answers whether it can speak the language asked for.
 * `speak` queues one sentence under an id (or replaces everything with `flush`); `stop` drops what
 * is speaking and queued. Progress comes back on the same channel as `event` calls: `start`,
 * `range` (Android 8+: the characters being spoken now, for her mouth), `done`, `stopped`, `error`.
 */
class CompanionVoicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null

    /** The engine's init result; null while it starts. */
    private var status: Int? = null
    private val waiting = mutableListOf<Pair<String, MethodChannel.Result>>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        tts?.stop()
        tts?.shutdown()
        tts = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> ready(call.argument<String>("language") ?: "zh-CN", result)
            "speak" -> result.success(speak(call))
            "stop" -> {
                tts?.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ready(language: String, result: MethodChannel.Result) {
        val engine = tts
        if (engine != null && status != null) {
            result.success(use(engine, language))
            return
        }
        waiting.add(language to result)
        if (engine != null) return
        tts = TextToSpeech(context) { code ->
            main.post {
                status = code
                val started = tts
                started?.setOnUtteranceProgressListener(progress)
                val answers = waiting.toList()
                waiting.clear()
                for ((lang, answer) in answers) answer.success(started != null && use(started, lang))
            }
        }
    }

    private fun use(engine: TextToSpeech, language: String): Boolean {
        if (status != TextToSpeech.SUCCESS) return false
        return runCatching {
            val locale = Locale.forLanguageTag(language)
            val ok = engine.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE
            if (ok) engine.language = locale
            ok
        }.getOrDefault(false)
    }

    private fun speak(call: MethodCall): Boolean {
        val engine = tts ?: return false
        if (status != TextToSpeech.SUCCESS) return false
        val id = call.argument<String>("id") ?: return false
        val text = call.argument<String>("text") ?: return false
        engine.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
        engine.setPitch((call.argument<Double>("pitch") ?: 1.0).toFloat())
        val queue = if (call.argument<Boolean>("flush") == true) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
        return engine.speak(text, queue, Bundle(), id) == TextToSpeech.SUCCESS
    }

    private fun send(type: String, id: String?, start: Int? = null, end: Int? = null) {
        main.post {
            methods.invokeMethod("event", mapOf("type" to type, "id" to id, "start" to start, "end" to end))
        }
    }

    private val progress =
        object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = send("start", utteranceId)

            override fun onDone(utteranceId: String?) = send("done", utteranceId)

            override fun onStop(utteranceId: String?, interrupted: Boolean) = send("stopped", utteranceId)

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = send("error", utteranceId)

            override fun onError(utteranceId: String?, errorCode: Int) = send("error", utteranceId)

            override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) =
                send("range", utteranceId, start, end)
        }

    companion object {
        private const val CHANNEL = "dsh/companion_voice"
    }
}
