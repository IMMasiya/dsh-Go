package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Owns the actual peer connection from registration through the final live node and close.
 * [close] is the required transaction close; [abandon] is the escape hatch when [close] cannot
 * be confirmed ([read] calls it once) and defaults to doing nothing.
 */
internal class TreeTransactions<C : Any>(private val abandon: (C) -> Unit = { }, private val close: (C) -> Boolean) {
    class CleanupPending : Exception()
    private val lock = ReentrantLock()
    private var pending: Pair<Any, C>? = null

    fun ready(): Boolean = lock.withLock { pending == null }
    fun closeOwned(scope: Any): Boolean = lock.withLock {
        val old = pending ?: return true
        if (old.first !== scope) return true
        if (!close(old.second)) return false
        pending = null
        true
    }
    fun <T> read(scope: Any, create: () -> C, body: (C) -> T): T = lock.withLock {
        if (pending != null) throw CleanupPending()
        val connection = create()
        pending = scope to connection
        try { body(connection) }
        finally {
            // The platform may not confirm the unregister (UiAutomation marks itself
            // DISCONNECTED before the RPC and may then return without invoking our proxy,
            // and the fallback unregister can fail). That connection's registration token
            // is unique to it, so a later read cannot be mistaken for this one, and the
            // platform reclaims whatever it still holds when this process exits. Drop the
            // identity and free the read gate instead of deadlocking every later read.
            if (!close(connection)) abandon(connection)
            pending = null
        }
    }
}
