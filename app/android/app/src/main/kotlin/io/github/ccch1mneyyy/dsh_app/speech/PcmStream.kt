package io.github.ccch1mneyyy.dsh_app.speech

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

/**
 * One stream of raw PCM16 mono audio played as it arrives (DeepSeek's TTS sends 24 kHz little-endian
 * samples while it is still synthesizing). The app writes chunks in order; a writer thread feeds an
 * [AudioTrack] in stream mode, so the first chunk is heard as soon as it lands.
 *
 * [end] means nothing more is coming: the stream reports [Listener.onDone] once the last sample has
 * actually played. [stop] silences it at once (from any thread); a stopped stream reports nothing
 * more after [Listener.onStopped]. The writer thread owns the track and releases it.
 *
 * With [levels] on, it reports how loud each 40 ms is, timed to when that audio is heard (for a mouth
 * or a speaking indicator).
 */
class PcmStream(
    val id: String,
    private val rate: Int,
    val call: Boolean,
    private val levels: Boolean,
    private val main: Handler,
    private val listener: Listener,
) {
    interface Listener {
        fun onStart(stream: PcmStream)
        fun onLevel(stream: PcmStream, value: Double)
        fun onDone(stream: PcmStream)
        fun onStopped(stream: PcmStream)
        fun onError(stream: PcmStream, reason: String)
    }

    private val queue = LinkedBlockingQueue<ByteArray>()
    @Volatile private var stopped = false
    @Volatile private var finished = false
    private var track: AudioTrack? = null
    private var thread: Thread? = null

    /** Heard or about to be: the track has started. */
    @Volatile var started = false
        private set

    fun open(): Boolean {
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val t = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(if (call) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(rate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                // About 400 ms: enough to ride out network jitter, small enough to stop at once.
                .setBufferSizeInBytes(max(min, rate * 2 * 2 / 5))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        }.getOrNull() ?: return false
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            t.release()
            return false
        }
        track = t
        thread = Thread({ run(t) }, "dsh-speech-pcm").also { it.start() }
        return true
    }

    /** Queues one chunk; false once the stream has ended or stopped. */
    fun write(bytes: ByteArray): Boolean {
        if (stopped || finished || bytes.isEmpty()) return !stopped && !finished
        queue.offer(bytes)
        return true
    }

    /** Nothing more is coming. */
    fun end() {
        if (stopped || finished) return
        finished = true
        queue.offer(END)
    }

    /** Silence now. Safe from any thread; the writer releases the track. */
    fun stop() {
        if (stopped) return
        stopped = true
        queue.offer(END)
        val t = track ?: return
        runCatching {
            t.pause()
            t.flush()
        }
    }

    private fun run(t: AudioTrack) {
        var frames = 0L
        var carry: Byte? = null
        val frameBytes = rate * 2 * LEVEL_MS / 1000
        val pending = ByteArray(frameBytes)
        var pendingLength = 0
        var failed: String? = null
        try {
            while (!stopped) {
                val chunk = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
                if (chunk === END) break
                // Samples are two bytes; an odd chunk leaves its last byte for the next.
                val data = carry?.let { byteArrayOf(it) + chunk } ?: chunk
                val even = data.size and 1.inv()
                carry = if (even < data.size) data[data.size - 1] else null
                if (even == 0) continue
                if (!started) {
                    t.play()
                    started = true
                    main.post { if (!stopped) listener.onStart(this) }
                }
                var offset = 0
                while (offset < even && !stopped) {
                    val n = t.write(data, offset, even - offset)
                    if (n < 0) {
                        failed = "write $n"
                        break
                    }
                    if (n == 0) Thread.sleep(5)
                    if (levels) {
                        // Levels per 40 ms of what was just written, posted for when it will be heard.
                        var i = offset
                        while (i < offset + n) {
                            val take = min(frameBytes - pendingLength, offset + n - i)
                            System.arraycopy(data, i, pending, pendingLength, take)
                            pendingLength += take
                            i += take
                            if (pendingLength == frameBytes) {
                                val value = loudness(pending, pendingLength)
                                // Frames queued ahead of this one: written before it, less what has played.
                                val ahead = (frames + (i - offset) / 2 - t.playbackHeadPosition.toLong()).coerceAtLeast(0)
                                main.postDelayed({ if (!stopped) listener.onLevel(this, value) }, ahead * 1000 / rate)
                                pendingLength = 0
                            }
                        }
                    }
                    frames += n / 2
                    offset += n
                }
                if (failed != null) break
            }
            if (!stopped && failed == null && started) {
                // Ended: wait until the last written sample has played (head position counts frames).
                val deadline = System.nanoTime() + (frames * 1000 / rate + 1500) * 1_000_000
                while (!stopped && t.playbackHeadPosition.toLong() and 0xFFFFFFFFL < frames && System.nanoTime() < deadline) {
                    Thread.sleep(20)
                }
            }
        } catch (_: InterruptedException) {
            stopped = true
        } catch (error: RuntimeException) {
            failed = error.javaClass.simpleName
        } finally {
            runCatching { t.stop() }
            runCatching { t.release() }
            track = null
        }
        val reason = failed
        main.post {
            when {
                stopped -> listener.onStopped(this)
                reason != null -> listener.onError(this, reason)
                else -> listener.onDone(this)
            }
        }
    }

    private fun loudness(bytes: ByteArray, length: Int): Double {
        val samples = ShortArray(length / 2)
        for (k in samples.indices) {
            samples[k] = ((bytes[2 * k].toInt() and 0xFF) or (bytes[2 * k + 1].toInt() shl 8)).toShort()
        }
        val db = SpeechGate.levelOf(samples, samples.size)
        // −50 dBFS and below is closed; −10 dBFS is wide open.
        return ((db + 50.0) / 40.0).coerceIn(0.0, 1.0)
    }

    private companion object {
        val END = ByteArray(0)
        const val LEVEL_MS = 40
    }
}
