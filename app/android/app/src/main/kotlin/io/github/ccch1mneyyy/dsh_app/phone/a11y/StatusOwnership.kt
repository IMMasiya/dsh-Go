package io.github.ccch1mneyyy.dsh_app.phone.a11y

/** Main-queue confined ownership of the displayed status, independent of prompt cards.
 * Checks only short task state. Platform/UI work always runs after the check returns. */
internal class StatusOwnership {
    private var current: ((() -> Unit) -> Boolean)? = null

    fun publish(ifCurrent: (() -> Unit) -> Boolean): Boolean {
        if (!ifCurrent {}) return false
        current = ifCurrent
        return true
    }

    fun clear() { current = null }

    /** A newer task may invalidate an old cleanup ticket without owning the old status. */
    fun takeStale(): Boolean {
        val owner = current ?: return false
        if (owner {}) return false
        current = null
        return true
    }
}
