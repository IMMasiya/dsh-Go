package io.github.ccch1mneyyy.dsh_app.phone

import android.os.Bundle
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Reason
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Stage
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.State
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundControl
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundDisplayIo
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundReleaseReceipt
import io.github.ccch1mneyyy.dsh_app.phone.background.PrivilegedChannel
import io.github.ccch1mneyyy.dsh_app.phone.background.Proto
import java.util.UUID
import java.util.concurrent.Executors

/**
 * One local diagnostic, with the same registry and original physical peer as phone tasks.
 * This lock owns only the run/report. Registry, background, UI and physical I/O are all outside it.
 */
internal class PhoneSelfCheck(
    private val sessions: PhoneTaskSessions,
    private val background: BackgroundControl,
    private val clock: () -> Long,
    private val unavailable: () -> Reason?,
    private val prepareReceiver: () -> Boolean,
    private val changed: () -> Unit,
) {
    private class Starting(val client: Any, val live: () -> Boolean) { var cancelled = false }
    private class Run(
        val client: Any,
        val live: () -> Boolean,
        val lease: PhoneTaskSessions.SelfCheckLease,
        val borrow: BackgroundControl.SelfCheckBorrow,
    ) {
        val handle = UUID.randomUUID().toString()
        val io = BackgroundDisplayIo<PrivilegedChannel>()
        val report = PhoneSelfCheckReport()
        var state = "running"
        var cancelled = false
        var workerActive = true
        var held = true
    }
    private val lock = Any()
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "dsh-phone-selfcheck").apply { isDaemon = true }
    }
    private var starting: Starting? = null
    private var latest: Run? = null

    val needsReceiver: Boolean get() = synchronized(lock) { starting != null || latest?.held == true }

    /** Called by the local main-thread UI entry; reservation and receiver setup do not run a probe. */
    fun start(client: Any, live: () -> Boolean): Map<String, Any?> {
        unavailable()?.let { return refused(it) }
        val ticket = synchronized(lock) {
            if (!live()) return responseLocked(false, Reason.RETIRED)
            if (starting != null || latest?.held == true) return responseLocked(false, Reason.BUSY)
            Starting(client, live).also { starting = it }
        }
        // Registration is on the existing main-thread entry, before the physical reservation.
        if (!prepareReceiver()) return abandonStart(ticket, Reason.UNAVAILABLE)
        val lease = sessions.tryReserveSelfCheck() ?: return abandonStart(ticket, Reason.BUSY)
        val borrow = background.tryBorrowSelfCheck()
        if (borrow == null) {
            sessions.releaseSelfCheck(lease) // No peer was pinned and no operation was dispatched.
            return abandonStart(ticket, Reason.CHANNEL_UNAVAILABLE)
        }
        val run = Run(client, live, lease, borrow)
        val accepted = synchronized(lock) {
            val active = !ticket.cancelled && ticket.live()
            starting = null
            latest = run
            if (!active) { run.cancelled = true; run.state = "cleaning" }
            run.report.update(Stage.DEVICE, State.PASS, true)
            active
        }
        if (!accepted) seal(run)
        worker.execute { if (accepted) execute(run) else cleanup(run) }
        changed()
        return synchronized(lock) { responseLocked(accepted, if (accepted) null else Reason.CANCELLED) }
    }

    private fun abandonStart(ticket: Starting, reason: Reason): Map<String, Any?> {
        val result = synchronized(lock) {
            if (starting === ticket) starting = null
            responseLocked(false, if (ticket.cancelled || !ticket.live()) Reason.CANCELLED else reason)
        }
        changed()
        return result
    }

    fun status(): Map<String, Any?> = synchronized(lock) { responseLocked(true) }
    fun refused(reason: Reason): Map<String, Any?> = synchronized(lock) { responseLocked(false, reason) }

    fun cancel(handle: String): Map<String, Any?> {
        val run = synchronized(lock) {
            val current = latest ?: return responseLocked(false, Reason.UNAVAILABLE)
            if (current.handle != handle) return responseLocked(false, Reason.IDENTITY_CHANGED)
            if (current.held) {
                current.cancelled = true
                if (current.workerActive) current.state = "cleaning"
            }
            current
        }
        if (synchronized(lock) { run.held }) seal(run)
        changed()
        return synchronized(lock) { responseLocked(true) }
    }

    /** Local detach affects only its captured attachment; global stops seal every pending run. */
    fun stop(client: Any? = null) {
        val run = synchronized(lock) {
            starting?.takeIf { client == null || it.client === client }?.cancelled = true
            latest?.takeIf { it.held && (client == null || it.client === client) }?.also {
                it.cancelled = true
                if (it.workerActive) it.state = "cleaning"
            }
        }
        run?.let(::seal)
        changed()
    }

    fun retryCleanup(handle: String): Map<String, Any?> {
        val run = synchronized(lock) {
            val current = latest ?: return responseLocked(false, Reason.UNAVAILABLE)
            if (current.handle != handle) return responseLocked(false, Reason.IDENTITY_CHANGED)
            if (!current.held || current.workerActive || current.state != "cleanup_pending")
                return responseLocked(false, Reason.BUSY)
            current.workerActive = true
            current.state = "cleaning"
            current
        }
        worker.execute { cleanup(run) }
        changed()
        return synchronized(lock) { responseLocked(true) }
    }

    private fun seal(run: Run) {
        sessions.sealSelfCheck(run.lease)
        run.io.seal()
    }

    private fun mayStart(run: Run): Boolean =
        synchronized(lock) { latest === run && !run.cancelled && run.live() } &&
            sessions.selfCheckCurrent(run.lease) && background.selfCheckBorrowCurrent(run.borrow) &&
            unavailable() == null

    private fun execute(run: Run) {
        var channelReady = false
        var beginAttempted = false
        val startedAt = clock()
        try {
            if (!mayStart(run)) { cancelFromWorker(run); return }
            update(run, Stage.CHANNEL, State.RUNNING, false)
            run.io.call {
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                val peer = run.borrow.channel
                val probeStarted = clock()
                val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                if ((cap.get(Proto.OK) as? Boolean) != true) {
                    update(run, Stage.CHANNEL, State.UNKNOWN, false, Reason.CHANNEL_UNAVAILABLE, clock() - probeStarted)
                    return@call
                }
                if ((cap.get(Proto.SELF_CHECK_PROBE_VERSION) as? Int) != 1 ||
                    (cap.get(Proto.RELEASE_RECEIPT) as? Int) != 1) {
                    update(run, Stage.CHANNEL, State.FAIL, true, Reason.UNSUPPORTED_PEER, clock() - probeStarted)
                    return@call
                }
                channelReady = true
                update(run, Stage.CHANNEL, State.PASS, true, durationMs = clock() - probeStarted)
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                update(run, Stage.DISPLAY, State.RUNNING, false)
                update(run, Stage.INPUT_PROBE, State.RUNNING, false)
                val request = Bundle().apply {
                    putString(Proto.OP, Proto.OP_SELF_CHECK_PROBE)
                    putString(Proto.OWNER, run.io.owner)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                    putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
                }
                val beginStarted = clock()
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                // No UI callback, new call admission or cancellation check after this pin.
                run.io.pin(peer)
                beginAttempted = true
                val reply = peer.execute(request)
                synchronized(lock) {
                    // Keep actual late facts on this original run, even when cancellation was requested.
                    run.report.acceptProbe(run.io.owner, reply.get(Proto.OWNER),
                        reply.get(Proto.SELF_CHECK_PROBE_VERSION), reply.get(Proto.OK),
                        reply.get(Proto.SELF_CHECK_DISPLAY_READY), reply.get(Proto.INJECT_OK),
                        reply.get(Proto.ERROR), reply.get(Proto.INJECT_ERROR), clock() - beginStarted)
                }
                changed()
            }
        } catch (_: Exception) {
            synchronized(lock) {
                if (beginAttempted) run.report.unknownProbe(Reason.DEVICE_UNAVAILABLE, clock() - startedAt)
                else if (!channelReady) run.report.update(Stage.CHANNEL, State.UNKNOWN, false,
                    Reason.CHANNEL_UNAVAILABLE, clock() - startedAt)
            }
        } finally { cleanup(run) }
    }

    private fun cancelFromWorker(run: Run) {
        synchronized(lock) { run.cancelled = true; run.state = "cleaning" }
        seal(run)
    }

    private fun cleanup(run: Run) {
        seal(run)
        synchronized(lock) {
            run.state = "cleaning"
            run.report.finishPending(run.cancelled || !run.live())
            run.report.update(Stage.CLEANUP, State.RUNNING, false)
        }
        changed()
        val startedAt = clock()
        val physical = try {
            run.io.release { peer ->
                val reply = peer.execute(Bundle().apply {
                    putString(Proto.OP, Proto.OP_RELEASE)
                    putString(Proto.OWNER, run.io.owner)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                })
                BackgroundReleaseReceipt.accepts(run.io.owner, reply.get(Proto.RELEASE_RECEIPT),
                    reply.get(Proto.OWNER), reply.get(Proto.OK), reply.get("released"),
                    reply.get(Proto.TASK_SCOPE_EMPTY), reply.get("neverCreated"))
            }
        } catch (_: Exception) { false }
        // Resource completion, return of the original borrow, then registry release, in that order.
        val returned = physical && background.releaseSelfCheckBorrow(run.borrow)
        val completed = returned && sessions.releaseSelfCheck(run.lease)
        synchronized(lock) {
            run.workerActive = false
            if (completed) {
                run.held = false
                run.state = if (run.cancelled || !run.live()) "cancelled" else "done"
                run.report.update(Stage.CLEANUP, State.PASS, true, durationMs = clock() - startedAt)
            } else {
                run.state = "cleanup_pending"
                run.report.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.CLEANUP_FAILED, clock() - startedAt)
            }
        }
        changed()
    }

    private fun update(run: Run, stage: Stage, state: State, observed: Boolean,
                       reason: Reason? = null, durationMs: Long? = null) {
        synchronized(lock) { run.report.update(stage, state, observed, reason, durationMs) }
        changed()
    }

    private fun responseLocked(accepted: Boolean, reason: Reason? = null): Map<String, Any?> {
        val current = latest
        return linkedMapOf<String, Any?>(
            "v" to 1, "accepted" to accepted, "state" to (current?.state ?: "idle"),
            "coverage" to "partial", "steps" to (current?.report ?: PhoneSelfCheckReport()).toMaps(),
        ).apply {
            current?.let { put("runHandle", it.handle) }
            reason?.let { put("reason", it.wire) }
        }
    }
}
