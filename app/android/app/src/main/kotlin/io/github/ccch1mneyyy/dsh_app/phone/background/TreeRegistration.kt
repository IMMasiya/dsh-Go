package io.github.ccch1mneyyy.dsh_app.phone.background

/** Exact platform registration retained across an uncertain RPC; caller serializes access. */
internal class TreeRegistration<C : Any>(private val unregisterClient: (C) -> Unit) {
    private var client: C? = null
    private var unregisterAttempts = 0L

    fun register(value: C, registerClient: (C) -> Unit) {
        check(client == null)
        client = value // The remote side may register before its reply fails.
        try {
            registerClient(value)
            TreeTrace.log("reg sent id=${System.identityHashCode(value)} ok")
        } catch (e: Throwable) {
            TreeTrace.log("reg sent id=${System.identityHashCode(value)} FAILED ${e.message}")
            throw e
        }
    }

    fun unregister() {
        val original = client ?: run { TreeTrace.log("unreg skipped id=${System.identityHashCode(this)} clientNull"); return }
        unregisterAttempts++
        try {
            unregisterClient(original)
            TreeTrace.log("unreg id=${System.identityHashCode(original)} attempts=$unregisterAttempts ok")
            client = null // Only an actual successful call discharges this identity.
        } catch (e: Throwable) {
            TreeTrace.log("unreg id=${System.identityHashCode(original)} attempts=$unregisterAttempts FAILED ${e.message}")
            throw e
        }
    }

    fun close(disconnect: () -> Unit): Boolean {
        val before = unregisterAttempts
        val disconnected = try { disconnect(); true } catch (e: Throwable) {
            TreeTrace.log("disconnect FAILED ${e::class.java.simpleName}: ${e.message}")
            false
        }
        TreeTrace.log("close entered id=${System.identityHashCode(this)} disconnected=$disconnected client=${client != null} attempts=$unregisterAttempts")
        // UiAutomation sets DISCONNECTED before the remote call. On retry it may return
        // without invoking our proxy at all. Retry the SAME client, at most once per close.
        if (client != null && unregisterAttempts == before) runCatching { unregister() }
            .onFailure { TreeTrace.log("fallback unregister FAILED ${it::class.java.simpleName}: ${it.message}") }
        return client == null
    }
}
