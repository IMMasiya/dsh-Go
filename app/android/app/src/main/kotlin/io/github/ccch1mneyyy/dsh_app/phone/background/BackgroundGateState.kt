package io.github.ccch1mneyyy.dsh_app.phone.background

/** Capability facts and known transport failures; an untested channel is still unknown. */
internal class BackgroundGateState {
    data class Snapshot(
        val trustedDisplayOk: Boolean? = null,
        val injectOk: Boolean? = null,
        val injectError: String? = null,
        val gateDetail: String? = null,
        val connectionError: Int? = null,
    )

    /** One accepted response, not the latest capability cache or a strict cleanup receipt. */
    data class Receipt(
        val trustedDisplayOk: Boolean,
        val injectOk: Boolean?,
        val injectFailure: InjectFailure?,
        val observation: InputProbeDiagnostics.Observation?,
    )

    enum class InjectFailure {
        API_UNAVAILABLE, PERMISSION_DENIED, WINDOW_NOT_READY, UNCONFIRMED, CLEANUP_FAILED, CANCELLED, OTHER;

        companion object {
            fun fromWire(error: String?): InjectFailure = when (error) {
                "inputApiUnavailable" -> API_UNAVAILABLE
                "systemOperationDenied" -> PERMISSION_DENIED
                "inputWindowNotReady" -> WINDOW_NOT_READY
                "inputUnconfirmed" -> UNCONFIRMED
                "inputProbeCleanupFailed" -> CLEANUP_FAILED
                "cancelled" -> CANCELLED
                else -> OTHER
            }
        }
    }

    sealed interface Update {
        data class Accepted(val receipt: Receipt) : Update
        object Busy : Update
        object Cancelled : Update
    }

    class Probe internal constructor(internal val mayApply: () -> Boolean)
    private var probe: Probe? = null
    private var failedChannel: Any? = null

    @Volatile var snapshot = Snapshot()
        private set

    @Synchronized fun reset() { probe = null; failedChannel = null; snapshot = Snapshot() }

    /** A deliberate retry can enter even after a failure; it does not erase capability facts. */
    @Synchronized fun begin(mayApply: () -> Boolean): Probe? {
        if (!mayApply()) return null
        failedChannel = null
        if (snapshot.connectionError != null) snapshot = snapshot.copy(connectionError = null)
        return Probe(mayApply).also { probe = it }
    }

    /** Revoke an old UI attempt before its worker returns, without forgetting completed facts. */
    @Synchronized fun cancelUnwantedPending() {
        if (probe?.mayApply?.invoke() == false) probe = null
    }

    @Synchronized fun current(owner: Probe): Boolean = probe === owner && owner.mayApply()

    @Synchronized fun failed(owner: Probe, reason: Int, channel: Any? = null): Boolean {
        if (!current(owner)) return false
        failedChannel = channel
        snapshot = snapshot.copy(connectionError = reason)
        return true
    }

    /** A connection can replace only the failure observed before that attempt started. */
    @Synchronized fun connected(observed: Snapshot, channel: Any) {
        if (snapshot === observed && snapshot.connectionError != null && failedChannel !== channel) {
            probe = null
            failedChannel = null
            snapshot = snapshot.copy(connectionError = null)
        }
    }

    /** Accept the response and freeze its safe facts under the same owner check. */
    @Synchronized fun update(owner: Probe, ok: Boolean, error: String?, injectOk: Boolean?, injectError: String?, detail: String?): Update {
        if (!current(owner)) return Update.Cancelled
        if (error == "probeBusy") return Update.Busy // Not run: keep historical facts unchanged.
        val receipt = Receipt(ok, injectOk,
            if (injectOk == false) InjectFailure.fromWire(injectError) else null,
            InputProbeDiagnostics.decode(detail))
        failedChannel = null
        snapshot = Snapshot(ok, injectOk, if (injectOk == false) injectError else null, detail)
        return Update.Accepted(receipt)
    }
}
