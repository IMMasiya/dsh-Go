package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/** One transport exchange at a time. Preview never queues ahead of an Agent call. */
internal class PrivilegedCalls {
    private val lock = ReentrantLock(true)

    fun <T> execute(action: () -> T): T {
        // A stopped Agent waiting behind a sent preview must not dispatch later.
        lock.lockInterruptibly()
        try { return action() } finally { lock.unlock() }
    }

    fun <T> tryPreview(action: () -> T): T? {
        // Unlike untimed tryLock(), the zero-time timed form honors the fair queue.
        if (!lock.tryLock(0, TimeUnit.NANOSECONDS)) return null
        try { return action() } finally { lock.unlock() }
    }
}
