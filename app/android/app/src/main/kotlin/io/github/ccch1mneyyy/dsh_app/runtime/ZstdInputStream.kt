package io.github.ccch1mneyyy.dsh_app.runtime

import com.github.luben.zstd.ZstdInputStream
import java.io.FilterInputStream
import java.io.InputStream

/**
 * Opens a Zstd-compressed [InputStream] as a plain tar stream.
 *
 * Single-stream decode on purpose: Zstd decompresses fast enough on one core that
 * the tar extract (file I/O) dominates, so a second decoder would only add thread
 * churn and buffer memory. [WINDOW_LOG] caps the back-reference window a frame may
 * demand, so a hostile archive cannot make the decoder allocate an unbounded buffer;
 * it must be >= the window the build compressed with (--long=27).
 */
internal object ZstdDecodedStream {
    /** 2^27 = 128 MiB window, matching the build's `--long=27`; bounds decoder memory. */
    private const val WINDOW_LOG = 27

    fun open(raw: InputStream, onProgress: (Long) -> Unit = {}): InputStream {
        val counting = object : FilterInputStream(raw) {
            var count = 0L
            override fun read(): Int = `in`.read().also { if (it >= 0) onProgress(++count) }
            override fun read(b: ByteArray, off: Int, len: Int): Int = `in`.read(b, off, len).also {
                if (it > 0) { count += it; onProgress(count) }
            }
        }
        val zstd = ZstdInputStream(counting)
        // Caps the decode window at 2^27 before the first read. A frame needing a
        // larger window fails rather than silently over-allocating; the installer
        // treats that as a blocked upgrade. This bounds the decoder window, not the
        // whole decompression's peak memory.
        zstd.setLongMax(WINDOW_LOG)
        return zstd
    }
}
