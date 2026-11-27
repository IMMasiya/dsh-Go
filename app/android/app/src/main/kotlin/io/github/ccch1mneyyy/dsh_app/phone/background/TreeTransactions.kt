package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Owns the actual peer connection from registration through the final live node and close.
 * [close] is the required transaction close; [abandon] is the optional teardown escape hatch
 * ([abandonOwned]) and defaults to doing nothing.
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

    /**
     * Teardown-only release of an identity whose platform unregister could not be confirmed.
     * [abandon] gives the platform one more attempt at the same close, then the identity is
     * dropped regardless: the registration token is unique to that connection, so dropping
     * it cannot be mistaken for another peer's registration, and whatever the platform still
     * holds is reclaimed when this process exits. [read] keeps refusing while any identity is
     * pending, so this never loosens the read gate.
     */
    fun abandonOwned(scope: Any): Boolean = lock.withLock {
        val old = pending ?: return true
        if (old.first !== scope) return true
        abandon(old.second)
        pending = null
        true
    }

    fun <T> read(scope: Any, create: () -> C, body: (C) -> T): T = lock.withLock {
        if (pending != null) throw CleanupPending()
        val connection = create()
        pending = scope to connection
        try { body(connection) }
        finally {
            if (close(connection)) pending = null
            else throw CleanupPending()
        }
    }
}
