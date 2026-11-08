package io.github.ccch1mneyyy.dsh_app.phone

import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real registry -> real Core -> shared worker. Only device services are synthetic. */
class PhoneTaskSessionsTest {
    private val ids = AtomicLong()
    private val time = AtomicLong(1_000)
    @Volatile private var beforeTaskClock: () -> Unit = {}
    private fun taskClock(): Long { beforeTaskClock(); return time.get() }
    private val worker = SerialWorker("session-test", time::get) { false }
    private val pool = Executors.newCachedThreadPool()
    @Volatile private var confirm: (ConfirmRequest) -> Decision = { Decision.UNAVAILABLE }
    private val actions = AtomicLong()
    @Volatile private var changed: () -> Unit = {}
    @Volatile private var lookup: () -> Unit = {}
    @Volatile private var observe: () -> Unit = {}
    @Volatile private var cleanup: (Long) -> Unit = {}
    @Volatile private var cleanupDispatch: (() -> Unit) -> Unit = { it() }
    @Volatile private var cancelScope: (PhoneTaskSessions.Task, PhoneTasks.Snapshot) -> Unit = { task, state ->
        if (state.stopped) task.core.worker.interruptCurrent(task.tasks)
    }
    private val env = object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = PhonePolicies()
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest) = this@PhoneTaskSessionsTest.confirm(request)
            override fun handoff(reason: String, timeoutMs: Long) = HandoffResult.STOP
            override fun status(text: String?) {}
        }
        override fun driver(screen: PhoneScreen) = object : PhoneDriver {
            override val screen = screen
            override fun availability() = Availability(true)
            override fun foregroundPackage() = "example.app"
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot { this@PhoneTaskSessionsTest.observe(); return ScreenSnapshot("${screen.prefix}1", "screen", "Example", "example.app") }
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
            override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "button", "Button", "example.app", "Example", false, false, false)
            override fun perform(action: PhoneAction): ActionResult { actions.incrementAndGet(); return ActionResult(true, "done") }
            override fun open(target: PhoneAppIdentity) = error("unexpected launch")
        }
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun system() = object : SystemApi {
            override fun apps(): List<AppEntry> { lookup(); return listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123))) }
            override fun isInstalled(pkg: String) = true
            override fun resolveLaunch(app: AppEntry): Either<String, AppEntry> = Either.Right(app)
            override fun launch(app: AppEntry, dispatch: PhoneTasks.SystemDispatch): SysResult = error("unexpected launch")
            override fun urlTarget(url: String): UrlTarget = error("unexpected lookup")
            override fun openUrl(url: String, target: UrlTarget, dispatch: PhoneTasks.SystemDispatch): SysResult = error("unexpected url")
            override fun intent(spec: IntentSpec, shareTo: AppEntry?, dispatch: PhoneTasks.SystemDispatch): SysResult = error("unexpected intent")
            override fun notify(title: String, text: String): SysResult = error("unexpected notify")
            override fun clipboardSet(text: String): SysResult = error("unexpected clipboard")
            override fun clipboardGet(): SysResult = error("unexpected clipboard")
        }
    }
    private val legacy = PhoneTasks(clock = ::taskClock, idSource = ids::incrementAndGet)
    private val legacyCore = PhoneCore(env, legacy, ActionLog(), worker)
    private val sessions = PhoneTaskSessions(::taskClock, ids::incrementAndGet,
        { tasks, _ -> PhoneCore(env, tasks, ActionLog(), worker) }, legacy, legacyCore, { changed() }, settleResources = { cleanup(it) }, dispatchCleanup = { cleanupDispatch(it) }, cancelScope = { task, state -> cancelScope(task, state) })
    private fun admit(session: String?, run: String = "1") = sessions.admit(session?.let { PhoneCaller(it, run, "call", runLifecycle = 1) })
    private fun invoke(session: String?, run: String = "1", tool: String = PhoneToolCatalog.APPS) =
        sessions.run(admit(session, run), tool, emptyMap())
    private fun task(session: String, run: String = "1") = sessions.all().single { it.sessionId == session && it.runId == run }
    private fun end(session: String, run: String = "1") { sessions.admitEnd(session, run)?.let(sessions::settleEnd) }
    @After fun close() { pool.shutdownNow(); worker.shutdown() }

    @Test fun selfCheckReservationBlocksEvenMetadataWithoutCreatingATask() {
        val before = sessions.all().toList()
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.selfCheckCurrent(lease))
        assertNull(sessions.tryReserveSelfCheck())
        assertTrue(invoke("new-session").isError)
        assertTrue(invoke(null).isError)
        assertEquals(before, sessions.all())
        assertFalse(legacy.isActive)
        assertEquals(0L, ids.get())
        assertTrue(sessions.releaseSelfCheck(lease))
        assertFalse(invoke("new-session").isError)
    }

    @Test fun pendingCallAndActiveThinkingBothExcludeSelfCheck() {
        val pending = admit("A")
        assertNull(sessions.tryReserveSelfCheck())
        assertFalse(sessions.run(pending, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertNull(sessions.tryReserveSelfCheck()) // no worker body, but original task remains active
        end("A")
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.releaseSelfCheck(lease))
    }

    @Test fun selfCheckSealAndLaunchRetirementPreserveOriginalCleanupIdentity() {
        val original = checkNotNull(sessions.tryReserveSelfCheck())
        sessions.sealSelfCheck(original)
        assertFalse(sessions.selfCheckCurrent(original))
        assertTrue(invoke("A").isError)
        sessions.retire()
        assertNull(sessions.tryReserveSelfCheck())
        assertTrue(invoke("A").isError)
        assertTrue(sessions.releaseSelfCheck(original)) // old epoch still owns the physical fence
        val next = checkNotNull(sessions.tryReserveSelfCheck())
        assertFalse(sessions.releaseSelfCheck(original))
        sessions.sealSelfCheck(original)
        assertTrue(sessions.selfCheckCurrent(next))
        assertTrue(sessions.releaseSelfCheck(next))
    }

    @Test fun unconfirmedRetiringResourceExcludesSelfCheckUntilActualCleanup() {
        assertFalse(invoke(null, tool = PhoneToolCatalog.SCREEN).isError)
        val oldId = legacy.snapshot().id
        cleanup = { throw IllegalStateException("unconfirmed") }
        sessions.retire()
        assertNull(sessions.tryReserveSelfCheck())
        cleanup = { assertEquals(oldId, it) }
        assertTrue(sessions.retryCleanup(oldId))
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.releaseSelfCheck(lease))
    }

    @Test fun scopeCancellationMustFinishBeforeSelfCheckCanReserve() {
        assertFalse(invoke("A").isError)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        cancelScope = { _, _ -> entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val stopping = pool.submit<Boolean> { sessions.stop(task("A"), "stop") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertNull(sessions.tryReserveSelfCheck())
            release.countDown()
            assertTrue(stopping.get(5, TimeUnit.SECONDS))
            val lease = checkNotNull(sessions.tryReserveSelfCheck())
            assertTrue(sessions.releaseSelfCheck(lease))
        } finally { release.countDown() }
    }

    @Test fun appSnapshotStopStillStopsAnIdleProjectedLegacyTask() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        time.addAndGet(legacy.idleMs + 1)
        val idle = legacy.snapshot()
        assertFalse(idle.active)
        assertTrue(legacy.isActive) // Snapshot projection has not called endLocked yet.
        assertTrue(sessions.stop(record, idle, "App stop"))
        assertTrue(legacy.isStopped())
        assertFalse(legacy.isActive)
    }

    @Test fun delayedLegacyFinishReceiptCannotEndTheSuccessorInTheSameRecord() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        val old = legacy.snapshot()
        legacy.endTask()
        assertFalse(invoke(null).isError)
        val next = checkNotNull(legacy.activeOwner())
        assertNotEquals(old.id, next.taskId)
        assertNull(sessions.finish(record, old))
        assertTrue(legacy.isCurrent(next))
        assertTrue(legacy.isActive)
        assertNotNull(sessions.finish(record, legacy.snapshot()))
        assertFalse(legacy.isActive)
    }

    @Test fun oldInactiveNoticeCannotCancelAnAlreadyReservedSuccessorBeforeBegin() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        legacy.endTask()
        val old = legacy.snapshot()
        val admission = admit(null)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        var cancellations = 0
        cancelScope = { _, _ -> cancellations++ }
        beforeTaskClock = {
            if (Thread.currentThread().name == "reserved-successor") {
                entered.countDown()
                assertTrue(release.await(5, TimeUnit.SECONDS))
            }
        }
        val result = java.util.concurrent.atomic.AtomicReference<ToolOutput>()
        val next = Thread({ result.set(sessions.run(admission, PhoneToolCatalog.APPS, emptyMap())) }, "reserved-successor").apply { start() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // begin holds Tasks.lock, but the listener must reject from the registry reservation
            // without waiting for that lock or touching worker/prompt cancellation.
            assertFalse(pool.submit<Boolean> { sessions.onInactive(record, old) }.get(5, TimeUnit.SECONDS))
            assertEquals(0, cancellations)
            beforeTaskClock = {}
            release.countDown(); next.join(5_000)
            assertFalse(next.isAlive)
            assertFalse(checkNotNull(result.get()).isError)
            assertTrue(legacy.isActive)
        } finally { beforeTaskClock = {}; release.countDown(); next.join(5_000) }
    }

    @Test fun staleSelectedOwnerAndInactiveSnapshotCannotStopAResumedScope() {
        assertFalse(invoke("A").isError)
        val record = task("A")
        val oldOwner = checkNotNull(record.tasks.activeOwner())
        assertTrue(sessions.stop(record, oldOwner, "first stop"))
        val stopped = record.tasks.snapshot()
        assertTrue(sessions.resume(record))
        assertFalse(invoke("A").isError)
        val nextOwner = checkNotNull(record.tasks.activeOwner())
        var cancellations = 0
        cancelScope = { _, _ -> cancellations++ }
        assertFalse(sessions.stop(record, oldOwner, "late button"))
        assertFalse(sessions.onInactive(record, stopped))
        assertEquals(0, cancellations)
        assertTrue(record.tasks.isCurrent(nextOwner))
        assertFalse(record.tasks.isStopped())
        assertFalse(invoke("A").isError)
    }

    @Test fun externalScopeCancellationFencesResumeAndLegacyBeginWithoutHoldingRegistryLock() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        cancelScope = { _, _ -> entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val stopping = pool.submit<Boolean> { sessions.stop(record, "stop") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // A lock-held callback would prevent this independent registry read from completing.
            assertTrue(pool.submit<Boolean> { sessions.all().contains(record) }.get(5, TimeUnit.SECONDS))
            time.addAndGet(legacy.stopHoldMs + 1)
            assertFalse(sessions.resume(record))
            assertTrue(invoke(null).isError)
            release.countDown()
            assertTrue(stopping.get(5, TimeUnit.SECONDS))
            assertTrue(sessions.resume(record))
            assertFalse(invoke(null).isError)
        } finally { release.countDown() }
    }

    @Test fun launchRetirementCannotExposeLegacyWhileOldScopeCancellationIsOutstanding() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        cancelScope = { _, _ -> entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val stopping = pool.submit<Boolean> { sessions.stop(record, "old launch") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            sessions.retire()
            time.addAndGet(legacy.stopHoldMs + 1)
            assertTrue(invoke(null).isError)
            release.countDown()
            assertTrue(stopping.get(5, TimeUnit.SECONDS))
            assertFalse(invoke(null).isError)
        } finally { release.countDown() }
    }

    @Test fun safetyGateStopInvalidatesAlreadyAdmittedLegacyCallBeyondTheHold() {
        assertFalse(invoke(null).isError)
        val queued = admit(null)
        val owner = checkNotNull(legacy.activeOwner())
        assertTrue(legacy.stopIfCurrent(owner, "gate stopped"))
        time.addAndGet(legacy.stopHoldMs + 1)
        val calls = actions.get()
        var lookedUp = false
        lookup = { lookedUp = true }
        assertTrue(sessions.run(queued, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertFalse(lookedUp)
        assertEquals(calls, actions.get())
        assertFalse(invoke(null).isError)
    }

    @Test fun approvalPauseInterjectionAndLegacyStateDoNotCrossSessions() {
        assertFalse(invoke("A").isError); assertFalse(invoke("B").isError); assertFalse(invoke(null).isError)
        val a = task("A").tasks; val b = task("B").tasks
        a.approve("example.app"); a.waive(); a.interject("A only"); a.setPaused(true)
        assertFalse(b.isApproved("example.app")); assertFalse(b.isWaived); assertFalse(b.isPaused)
        assertTrue(b.drainInterjections().isEmpty()); assertTrue(legacy.drainInterjections().isEmpty())
        assertFalse(legacy.isWaived); assertNotEquals(a.snapshot().id, b.snapshot().id)
        assertNotEquals(a.snapshot().id, legacy.snapshot().id)
        assertSame(task("A").core.worker, task("B").core.worker)
    }

    @Test fun unknownAndDuplicateEndsFenceLateCallsBeforeAnyBodyRuns() {
        var called = false; lookup = { called = true }
        assertNull(sessions.admitEnd("A", "1"))
        assertNull(sessions.admitEnd("A", "1"))
        assertTrue(invoke("A").isError); assertFalse(called)
        assertFalse(invoke("B").isError); assertTrue(called)
    }

    @Test fun endWhileBodyIsPendingIsRememberedUntilTheBodyDrains() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        lookup = {
            entered.countDown()
            var done = false
            while (!done) try { done = release.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val running = pool.submit<ToolOutput> { invoke("A") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val a = task("A")
        try {
            end("A")
            assertTrue(sessions.isBusy(a)); assertNull(a.finished)
            assertTrue(sessions.run(admit("A"), PhoneToolCatalog.APPS, emptyMap()).isError)
        } finally { release.countDown() }
        running.get(5, TimeUnit.SECONDS)
        assertFalse(sessions.isBusy(a)); assertFalse(a.tasks.isActive)
        val receipt = checkNotNull(a.finished)
        assertNotNull(sessions.completed(receipt.taskId, "1", receipt.lifecycle))
        assertNull(sessions.completed(receipt.taskId, "1", receipt.lifecycle))
        assertNull(sessions.admitEnd("A", "1"))
    }

    @Test fun endBeforeQueuedCallCannotStartItAndLaunchRetirementRejectsOldAdmissions() {
        val old = admit("A")
        end("A")
        assertTrue(sessions.run(old, PhoneToolCatalog.APPS, emptyMap()).isError)
        val beforeRetire = admit("B")
        sessions.retire()
        assertTrue(sessions.run(beforeRetire, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertFalse(invoke("A").isError) // ended fences belong to the retired launch only
    }

    @Test fun userStopSurvivesTimeAndLaterTurnsUntilExplicitResume() {
        invoke("A")
        val a = task("A")
        sessions.stop(a, "user")
        time.addAndGet(10 * 60_000)
        assertTrue(invoke("A", "2").isError)
        end("A")
        assertTrue(invoke("A", "3").isError)
        sessions.resume(a)
        assertFalse(invoke("A", "3").isError)
        assertTrue(invoke("A", "1").isError) // explicit resume does not reopen an ended run
    }

    @Test fun newerAdmissionRevokesOldReturnWithoutFinishingTheNewRun() {
        invoke("A")
        val a = task("A")
        end("A")
        val receipt = checkNotNull(a.finished)
        invoke("A", "2")
        end("A")
        assertTrue(task("A", "2").tasks.isActive)
        assertNull(sessions.completed(receipt.taskId, "1", receipt.lifecycle))
    }
    @Test fun aScreenWaitDoesNotOccupyTheWorkerNeededByItsHolder() {
        assertFalse(invoke("A", tool = PhoneToolCatalog.SCREEN).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.all().any { it.sessionId == "B" && it.waiting == PhoneScreen.MAIN }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        // This call must execute while B waits. Placing lease waits inside SerialWorker deadlocks it.
        val a = pool.submit<ToolOutput> { invoke("A") }
        assertFalse(a.get(5, TimeUnit.SECONDS).isError)
        end("A")
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
    }

    @Test fun anOldRunEndCannotInterruptAnotherSessionsActiveWorker() {
        invoke("A")
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        lookup = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val b = pool.submit<ToolOutput> { invoke("B") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        try { end("A") } finally { release.countDown() }
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        assertTrue(task("B").tasks.isActive)
    }

    @Test fun firstClassificationIsImmutableAndOldCompletedCannotUpgradeAnotherRun() {
        invoke("A")
        end("A")
        assertEquals("unknown", task("A").completion)
        assertNull(sessions.admitEnd("A", "1", "completed"))
        assertEquals("unknown", task("A").completion)
        invoke("A", "2")
        sessions.admitEnd("A", "2", "other")?.let(sessions::settleEnd)
        assertNull(sessions.admitEnd("A", "2", "completed"))
        assertEquals("other", task("A", "2").completion)
        sessions.admitEnd("unknown-first", "1", "other")
        assertNull(sessions.admitEnd("unknown-first", "1", "completed"))
        assertTrue(invoke("unknown-first").isError)
        assertFalse(sessions.all().any { it.sessionId == "unknown-first" })
    }

    @Test fun backgroundCoordinatesWaitOnObservationScreenAndDoNotClaimMain() {
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.SCREEN, mapOf("background" to true)).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.all().any { it.sessionId == "B" && it.waiting == PhoneScreen.BACKGROUND }) waiting.countDown() }
        val coordinate = pool.submit<ToolOutput> {
            sessions.run(admit("B"), PhoneToolCatalog.TAP_XY, mapOf("observation" to "b1", "x" to 1, "y" to 1))
        }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            val main = pool.submit<ToolOutput> { invoke("C", tool = PhoneToolCatalog.SCREEN) }
            assertFalse(main.get(5, TimeUnit.SECONDS).isError)
            assertFalse(invoke("A").isError)
        } finally { end("A") }
        // No fake approval authority was supplied, so the real Core must still refuse the write.
        assertTrue(coordinate.get(5, TimeUnit.SECONDS).isError)
    }

    @Test fun invalidCoordinateObservationDoesNotAcquireAFallbackScreen() {
        assertTrue(sessions.run(admit("bad"), PhoneToolCatalog.TAP_XY, mapOf("screen" to "b1", "x" to 1, "y" to 1)).isError)
        val main = pool.submit<ToolOutput> { invoke("C", tool = PhoneToolCatalog.SCREEN) }
        assertFalse(main.get(5, TimeUnit.SECONDS).isError)
        assertTrue(sessions.run(admit("bad2"), PhoneToolCatalog.TAP_XY, mapOf("observation" to "wrong", "x" to 1, "y" to 1)).isError)
    }

    @Test fun olderCallerAttributionKeepsLegacyLifecycleAndNeverAdoptsAModernTask() {
        invoke("modern")
        val modern = task("modern")
        val b1 = sessions.admit(PhoneCaller("old-runtime", "old:1", "call"))
        assertFalse(sessions.run(b1, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertTrue(legacy.isActive)
        assertFalse(sessions.all().any { it.sessionId == "old-runtime" })
        assertNotEquals(legacy.snapshot().id, modern.tasks.snapshot().id)
        sessions.finish(sessions.all().single { it.sessionId == null })
        assertTrue(modern.tasks.isActive)
    }

    @Test fun timedOutRpcDoesNotPublishFinishedUntilTheAbandonedBodyActuallyExits() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val finished = CountDownLatch(1)
        lookup = {
            entered.countDown()
            var done = false
            while (!done) try { done = release.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val running = pool.submit<ToolOutput> { invoke("A") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val a = task("A")
        changed = { if (a.finished != null) finished.countDown() }
        try {
            time.addAndGet(20_000) // actual Core APPS budget is 15 seconds; no wall-clock sleep
            assertTrue(running.get(5, TimeUnit.SECONDS).isError)
            assertEquals(0, a.pending)
            assertTrue(a.running)
            end("A")
            assertNull(a.finished)
            assertTrue(sessions.isBusy(a))
            val wire = sessions.snapshot().single { it["sessionId"] == "A" }
            assertEquals(true, wire["draining"]); assertEquals(true, wire["finishing"])
        } finally { release.countDown() }
        assertTrue(finished.await(5, TimeUnit.SECONDS))
        assertFalse(sessions.isBusy(a)); assertFalse(a.tasks.isActive)
        lookup = {}
        assertFalse(invoke("B").isError) // shared successor worker remains usable
    }

    @Test fun legacyKeepsItsOldQuietStopHoldRatherThanTheModernStickyFence() {
        invoke(null)
        val old = sessions.all().single { it.sessionId == null }
        sessions.stop(old, "user")
        time.addAndGet(20_000)
        assertTrue(invoke(null).isError) // a retry extends the original PhoneTasks hold
        time.addAndGet(20_000)
        assertTrue(invoke(null).isError)
        time.addAndGet(31_000)
        assertFalse(invoke(null).isError)
    }

    @Test fun actualSafetyGateDoesNotReuseAnotherSessionsAppApproval() {
        val asked = mutableListOf<Long>()
        confirm = { request -> asked += checkNotNull(request.owner).taskId; Decision.ALLOW_APP_FOR_TASK }
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1)).isError)
        assertTrue(task("A").tasks.isApproved("example.app"))
        confirm = { request -> asked += checkNotNull(request.owner).taskId; Decision.DENY }
        assertTrue(sessions.run(admit("B"), PhoneToolCatalog.TAP, mapOf("screen" to "b1", "id" to 1)).isError)
        assertEquals(listOf(task("A").tasks.snapshot().id, task("B").tasks.snapshot().id), asked)
        assertFalse(task("B").tasks.isApproved("example.app")); assertEquals(1L, actions.get())
    }

    @Test fun lateApprovalForStoppedAIsNotAppliedToAOrB() {
        invoke("B")
        confirm = { request ->
            val a = task("A")
            assertEquals(a.tasks.snapshot().id, checkNotNull(request.owner).taskId)
            sessions.stop(a, "stop while confirmation pending")
            Decision.ALLOW_ALL_FOR_TASK
        }
        assertTrue(sessions.run(admit("A"), PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1)).isError)
        assertEquals(0L, actions.get())
        assertFalse(task("A").tasks.isWaived); assertFalse(task("B").tasks.isWaived)
        assertTrue(task("B").tasks.isActive)
    }

    @Test fun unionBudgetRejectsNewRecordsWithoutEvictingEndedFencesOrBlockingExistingEnds() {
        val bounded = PhoneTaskSessions(time::get, ids::incrementAndGet,
            { state, _ -> PhoneCore(env, state, ActionLog(), worker) }, legacy, legacyCore, maxRuns = 2)
        fun input(session: String) = PhoneCaller(session, "1", "call", runLifecycle = 1)
        assertFalse(bounded.run(bounded.admit(input("A")), PhoneToolCatalog.APPS, emptyMap()).isError)
        assertNull(bounded.admitEnd("ended-before-call", "1"))
        assertTrue(bounded.run(bounded.admit(input("new")), PhoneToolCatalog.APPS, emptyMap()).isError)
        assertTrue(bounded.run(bounded.admit(input("ended-before-call")), PhoneToolCatalog.APPS, emptyMap()).isError)
        assertEquals(2, bounded.all().size) // legacy + A; fenced run never allocates a Core
        try { bounded.admitEnd("unknown-full", "1"); fail("must not ACK an unrecorded end") }
        catch (_: PhoneTaskSessions.CapacityExceeded) { }
        bounded.admitEnd("A", "1", "completed")?.let(bounded::settleEnd)
        assertFalse(bounded.all().single { it.sessionId == "A" }.tasks.isActive)
        assertNull(bounded.admitEnd("ended-before-call", "1", "completed"))
        assertTrue(bounded.run(bounded.admit(input("A")), PhoneToolCatalog.APPS, emptyMap()).isError)
        bounded.retire()
        assertFalse(bounded.run(bounded.admit(input("new")), PhoneToolCatalog.APPS, emptyMap()).isError)
    }

    @Test fun physicalCleanupHoldsBothLeasesAndDoesNotHoldRegistryLock() {
        assertFalse(invoke("A", tool = PhoneToolCatalog.SCREEN).isError)
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.SCREEN, mapOf("background" to true)).isError)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val waiting = CountDownLatch(1)
        cleanup = { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val ending = pool.submit { end("A") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertNull(task("A").finished)
            changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
            val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)) // snapshot/admit work while cleanup is blocked
            assertFalse(b.isDone)
            assertFalse(sessions.resume(task("A")))
            release.countDown(); ending.get(5, TimeUnit.SECONDS)
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            assertNotNull(task("A").finished)
        } finally { release.countDown() }
    }

    @Test fun cleanupFailureKeepsPhysicalFenceUntilExplicitRetryAndPreservesTheOriginalReceipt() {
        invoke("A", tool = PhoneToolCatalog.SCREEN)
        cleanup = { throw IllegalStateException("device release not confirmed") }
        end("A")
        val a = task("A")
        assertNull(a.finished); assertTrue(a.cleanupFailed); assertTrue(sessions.isBusy(a))
        assertFalse(sessions.resume(a))
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
        val original = checkNotNull(a.pendingFinish)
        cleanup = {}
        assertTrue(sessions.retryCleanup(a.tasks.snapshot().id))
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        assertSame(original, a.finished)
        assertFalse(a.cleanupFailed)
        assertFalse(sessions.retryCleanup(a.tasks.snapshot().id)) // no second release after success
    }

    @Test fun retirementKeepsOldPhysicalBodyAndCleanupFencesAcrossLaunches() {
        val entered = CountDownLatch(1); val bodyExit = CountDownLatch(1)
        val cleanupEntered = CountDownLatch(1); val cleanupExit = CountDownLatch(1); val waiting = CountDownLatch(1)
        observe = {
            entered.countDown()
            var done = false
            while (!done) try { done = bodyExit.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val oldCall = pool.submit<ToolOutput> { invoke("A", tool = PhoneToolCatalog.SCREEN) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val old = task("A"); val oldId = old.tasks.snapshot().id
            time.addAndGet(60_000)
            assertTrue(oldCall.get(5, TimeUnit.SECONDS).isError)
            assertTrue(old.running)
            cleanup = { id -> assertEquals(oldId, id); cleanupEntered.countDown(); assertTrue(cleanupExit.await(5, TimeUnit.SECONDS)) }
            sessions.retire()
            observe = {}
            changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
            val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
            assertTrue(sessions.snapshot().any { it["retiring"] == true && it["draining"] == true })
            bodyExit.countDown()
            assertTrue(cleanupEntered.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
            cleanupExit.countDown()
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            assertNull(old.finished)
            assertTrue(task("B").tasks.isActive)
        } finally { bodyExit.countDown(); cleanupExit.countDown() }
    }

    @Test fun retiredAdmissionCannotBeginANewScopeOnReusedLegacyTasks() {
        invoke(null, tool = PhoneToolCatalog.SCREEN)
        val old = sessions.all().single { it.sessionId == null }
        val oldId = legacy.snapshot().id
        val oldAdmission = admit(null)
        val capturedEpoch = old.tasks.admissionEpoch()
        sessions.retire()
        assertFalse(invoke(null).isError)
        val newId = legacy.snapshot().id
        assertNotEquals(oldId, newId)
        // Even if retirement happened after the registry live check, begin itself rejects the epoch.
        assertTrue(legacy.begin(capturedEpoch) is PhoneTasks.Begin.Refused)
        assertTrue(sessions.run(oldAdmission, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertEquals(newId, legacy.snapshot().id); assertTrue(legacy.isActive)
    }

    @Test fun explicitResumeAllowsOnlyFutureCallsForTheChosenSession() {
        invoke("A"); invoke("B")
        val a = task("A"); val b = task("B")
        sessions.stop(a, "user A"); sessions.stop(b, "user B")
        end("A")
        time.addAndGet(120_000)
        assertTrue(invoke("A", "next").isError)
        assertTrue(sessions.resume(a))
        assertFalse(invoke("A", "next").isError)
        assertTrue(invoke("A", "1").isError) // exact old run end never reopens
        assertTrue(invoke("B", "next").isError)
    }

    @Test fun lateLegacyBodyCleanupUsesItsOldIdWithoutEndingTheNextLaunchScope() {
        val entered = CountDownLatch(1); val exit = CountDownLatch(1); val cleaned = CountDownLatch(1)
        observe = {
            entered.countDown()
            var done = false
            while (!done) try { done = exit.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val oldCall = pool.submit<ToolOutput> { invoke(null, tool = PhoneToolCatalog.SCREEN) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val oldId = legacy.snapshot().id
            time.addAndGet(60_000)
            assertTrue(oldCall.get(5, TimeUnit.SECONDS).isError)
            cleanup = { id -> assertEquals(oldId, id); cleaned.countDown() }
            sessions.retire()
            observe = {}
            assertFalse(invoke(null).isError) // metadata has no screen lease, and gets a fresh epoch
            val nextId = legacy.snapshot().id
            assertNotEquals(oldId, nextId)
            exit.countDown()
            assertTrue(cleaned.await(5, TimeUnit.SECONDS))
            assertEquals(nextId, legacy.snapshot().id); assertTrue(legacy.isActive)
        } finally { exit.countDown() }
    }

    @Test fun retiredCleanupRetryKeepsItsOldIdentityAndDoesNotResumeTheOldRun() {
        invoke(null, tool = PhoneToolCatalog.SCREEN)
        val oldId = legacy.snapshot().id
        cleanup = { throw IllegalStateException("unconfirmed") }
        sessions.retire()
        assertTrue(sessions.snapshot().any { it["retiring"] == true && it["cleanupFailed"] == true })
        assertFalse(invoke(null).isError)
        val currentId = legacy.snapshot().id
        cleanup = { id -> assertEquals(oldId, id) }
        assertTrue(sessions.retryCleanup(oldId))
        assertEquals(currentId, legacy.snapshot().id); assertTrue(legacy.isActive)
        assertFalse(sessions.snapshot().any { it["retiring"] == true })
    }

    @Test fun scheduledStopCleanupKeepsLeasesAndLegacyFinishWaitsForItsActualResult() {
        invoke(null, tool = PhoneToolCatalog.SCREEN)
        val legacyRecord = sessions.all().single { it.sessionId == null }
        val queued = java.util.concurrent.atomic.AtomicReference<(() -> Unit)?>(null)
        val ready = CountDownLatch(1)
        cleanupDispatch = { action -> queued.set(action); ready.countDown() }
        sessions.stop(legacyRecord, "user")
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        assertTrue(sessions.isBusy(legacyRecord)); assertFalse(legacyRecord.resourcesReleased)
        val finish = pool.submit<PhoneTasks.Owner?> { sessions.finish(legacyRecord) }
        cleanupDispatch = { it() } // background explicit finish uses the synchronous path
        pool.submit { checkNotNull(queued.get())() }.get(5, TimeUnit.SECONDS)
        assertNotNull(finish.get(5, TimeUnit.SECONDS))
        assertTrue(legacyRecord.resourcesReleased); assertFalse(sessions.isBusy(legacyRecord))
    }

}
