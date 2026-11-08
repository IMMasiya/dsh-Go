package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.phone.a11y.MainScreenDriver
import org.junit.Assert.*
import org.junit.Test

class PhoneTaskObservationsTest {
    private class Driver : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        var actions = 0
        var scrollSourceGate: ((Set<String>) -> Boolean)? = null
        var duringScroll: () -> Unit = {}
        var capturedAdmission: ((() -> Boolean) -> Boolean)? = null
        var capturedAllowed: (() -> Boolean)? = null
        var scope: VisualScope? = null
        val imageCommits = mutableListOf<String>()
        override fun acceptVisualObservation(screenId: String) { imageCommits += screenId }
        val opens = mutableListOf<PhoneAppIdentity>()
        var duringOpen: () -> Unit = {}
        var collectBatchGate: ((Set<String>) -> Boolean)? = null
        var collectGate: (() -> Boolean)? = null
        var collectSourceGate: ((String?) -> Boolean)? = null
        var duringCollect: () -> Unit = {}
        var collected = CollectResult(emptyList(), 0, "done", null)
        override fun visualScope(screenId: String): VisualScope? = scope.takeIf { screenId == "s1" }
        override fun availability() = Availability(true)
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s1", "screen", "App", "app")
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "button", "send", "app", "App", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions++; return ActionResult(true, "done") }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult {
            capturedAdmission = coordinateAdmission
            capturedAllowed = allowed
            return if (allowed()) perform(action) else ActionResult(false, "stopped")
        }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?,
                             actionSourcesAllowed: (Set<String>) -> Boolean): ActionResult {
            scrollSourceGate = actionSourcesAllowed
            if (action is PhoneAction.Scroll) duringScroll()
            return perform(action, allowed, coordinateAdmission)
        }
        override fun open(target: PhoneAppIdentity): ActionResult {
            opens += target
            duringOpen()
            return ActionResult(true, "opened", ScreenSnapshot("sOpen", "opened screen", "App", target.packageName))
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = collected
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult {
            collectGate = allowed
            duringCollect()
            return collected
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                             allowed: () -> Boolean, canRead: (String?) -> Boolean): CollectResult {
            collectSourceGate = canRead
            return collect(screenId, listElementId, maxPages, until, allowed)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?,
                             allowed: () -> Boolean, canRead: (String?) -> Boolean,
                             scrollSourcesAllowed: (Set<String>) -> Boolean): CollectResult {
            collectBatchGate = scrollSourcesAllowed
            return collect(screenId, listElementId, maxPages, until, allowed, canRead)
        }
        override fun foregroundPackage() = "app"
    }
    private fun owner(tasks: PhoneTasks) = (tasks.begin() as PhoneTasks.Begin.Go).owner

    @Test fun boundOpenPassesTheOriginalNativeIdentityAndRecordsOnlyItsReturnedScreen() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        val identity = PhoneAppIdentity("example.app", 1010123)
        val result = bound.open(identity)
        assertTrue(result.ok)
        assertSame(identity, physical.opens.single())
        assertNotNull(bound.target("sOpen", 1))
    }

    @Test fun staleBoundOpenCannotDispatchOrPublishIntoTheReplacementScope() {
        val tasks = PhoneTasks(); val physical = Driver(); val ledger = PhoneTaskObservations(tasks)
        val bound = ledger.bind(physical, owner(tasks))
        val identity = PhoneAppIdentity("example.app", 10123)
        physical.duringOpen = { tasks.stop("replaced"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.open(identity) }
        assertEquals(1, physical.opens.size)
        val replacement = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(replacement.target("sOpen", 1))
        assertThrows(InterruptedException::class.java) { bound.open(identity) }
        assertEquals(1, physical.opens.size) // Rejected before calling the physical driver again.
    }

    @Test fun collectionPassesItsOwnLivePauseGateInsteadOfTheDisplayedTasksState() {
        val a = PhoneTasks(); val b = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(a).bind(physical, owner(a))
        owner(b); b.setPaused(true)
        bound.observe(false, false)
        bound.collect("s1", 1, 3, null)
        val allowed = checkNotNull(physical.collectGate)
        assertTrue(allowed()) // Pausing another task must not stop this collection.
        a.setPaused(true); assertFalse(allowed())
        b.setPaused(false); assertFalse(allowed())
        a.setPaused(false); assertTrue(allowed())
        a.stop("user"); a.clearStop(); a.begin()
        assertFalse(allowed()) // Resume/new scope cannot revive the old loop's permission.
    }

    @Test fun collectionFinishingAfterItsScopeWasReplacedCannotPublishAnObservation() {
        val tasks = PhoneTasks(); val ledger = PhoneTaskObservations(tasks); val physical = Driver()
        val bound = ledger.bind(physical, owner(tasks))
        bound.observe(false, false)
        physical.collected = CollectResult(listOf("synthetic"), 1, "done", ScreenSnapshot("sLate", "screen", "App", "app"))
        physical.duringCollect = { tasks.stop("user"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.collect("s1", 1, 3, null) }
        val fresh = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(fresh.target("sLate", 1))
        assertFalse(checkNotNull(physical.collectGate)())
    }

    @Test fun anotherSessionCannotUseAnIdItNeverObservedEvenOnTheSamePhysicalDriver() {
        val physical = Driver()
        val a = PhoneTasks(); val b = PhoneTasks()
        val first = PhoneTaskObservations(a).bind(physical, owner(a))
        val second = PhoneTaskObservations(b).bind(physical, owner(b))
        first.observe(false, false)
        assertNull(second.target("s1", 1))
        assertFalse(second.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(0, physical.actions)
        assertTrue(first.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(1, physical.actions)
    }

    @Test fun replacementDriverWithTheSameCounterDoesNotInheritAnOldObservation() {
        val tasks = PhoneTasks(); val ledger = PhoneTaskObservations(tasks); val owner = owner(tasks)
        ledger.bind(Driver(), owner).observe(false, false)
        val replacement = Driver(); val bound = ledger.bind(replacement, owner)
        assertNull(bound.target("s1", 1))
        assertFalse(bound.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(0, replacement.actions)
        bound.observe(false, false)
        assertTrue(bound.perform(PhoneAction.Tap("s1", 1)).ok)
    }

    @Test fun stopAndExplicitResumeCannotReviveTheOldBoundDriver() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        tasks.stop("user"); tasks.clearStop(); tasks.begin()
        try { bound.perform(PhoneAction.Tap("s1", 1)); fail("old lifetime dispatched") } catch (_: InterruptedException) { }
        assertEquals(0, physical.actions)
    }
    @Test fun visualCommitRequiresThisOwnerAndTheSameObservedDriver() {
        val a = PhoneTasks(); val b = PhoneTasks(); val physical = Driver()
        val ledger = PhoneTaskObservations(a)
        val bound = ledger.bind(physical, owner(a))
        bound.observe(false, true)
        PhoneTaskObservations(b).bind(physical, owner(b)).acceptVisualObservation("s1")
        assertTrue(physical.imageCommits.isEmpty())
        val replacement = Driver()
        ledger.bind(replacement, checkNotNull(a.activeOwner())).acceptVisualObservation("s1")
        assertTrue(replacement.imageCommits.isEmpty())
        bound.acceptVisualObservation("s1")
        assertEquals(listOf("s1"), physical.imageCommits)
        a.stop("stop"); a.clearStop(); a.begin()
        assertThrows(InterruptedException::class.java) { bound.acceptVisualObservation("s1") }
        assertEquals(1, physical.imageCommits.size)
    }

    @Test fun actualWrapperCoordinateClaimCannotUseARetiredOrPausedOwner() {
        val tasks = PhoneTasks(); val physical = Driver()
        val owner = owner(tasks); val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        bound.observe(false, false); bound.perform(PhoneAction.TapXY("s1", 1, 1))
        val admission = checkNotNull(physical.capturedAdmission)
        var claims = 0
        assertTrue(admission { claims++; true })
        tasks.setPaused(true)
        assertFalse(admission { claims++; true })
        tasks.setPaused(false); tasks.stop("stop"); tasks.clearStop(); tasks.begin()
        assertFalse(admission { claims++; true }); assertEquals(1, claims)
    }
    @Test fun pauseWhileTheMainDriverResolvesATargetRefusesItsPhysicalDispatch() {
        val tasks = PhoneTasks(); val physical = Driver(); val owner = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        bound.observe(false, false); bound.perform(PhoneAction.Tap("s1", 1))
        val allowed = checkNotNull(physical.capturedAllowed)
        assertNull(MainScreenDriver.refuseHalted(allowed)) // Admitted before resolve() captures.
        assertTrue(tasks.setPausedIfCurrent(owner, true)) // The person pauses during that capture.
        val refused = checkNotNull(MainScreenDriver.refuseHalted(allowed))
        assertFalse(refused.ok); assertNull(refused.screen)
        assertTrue(tasks.setPausedIfCurrent(owner, false)); assertNull(MainScreenDriver.refuseHalted(allowed))
        tasks.stop("user"); tasks.clearStop(); tasks.begin()
        assertNotNull(MainScreenDriver.refuseHalted(allowed)) // A new lifetime cannot admit the old dispatch.
    }

    @Test fun actualLedgerRevokesScopeOnTextOnlyObservationBeforeAComesBack() {
        val tasks = PhoneTasks(); val physical = Driver(); val owner = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        val a = VisualScope.Main(Any(), Any(), 1, "app")
        physical.scope = a; bound.observe(false, false)
        assertTrue(tasks.confirmVisualIfCurrent(owner, a))
        physical.scope = null; bound.observe(false, false)
        assertFalse(tasks.confirmVisualIfCurrent(owner, a))
        physical.scope = a; bound.observe(false, false)
        assertFalse(tasks.hasVisualGrant(owner, a))
    }

    @Test fun additionalPolicyGateCannotBypassTheOriginalObservationOwner() {
        val physical = Driver(); val firstTasks = PhoneTasks(); val otherTasks = PhoneTasks()
        val first = PhoneTaskObservations(firstTasks).bind(physical, owner(firstTasks))
        val other = PhoneTaskObservations(otherTasks).bind(physical, owner(otherTasks))
        first.observe(false, false)
        assertFalse(other.perform(PhoneAction.Tap("s1", 1)) { true }.ok)
        assertEquals(0, physical.actions)
        var permitted = true
        assertTrue(first.perform(PhoneAction.Tap("s1", 1)) { permitted }.ok)
        val allowed = checkNotNull(physical.capturedAllowed)
        val claim = checkNotNull(physical.capturedAdmission)
        permitted = false
        assertFalse(allowed())
        var claimed = 0
        assertFalse(claim { claimed++; true }); assertEquals(0, claimed)
        permitted = true; firstTasks.setPaused(true)
        assertFalse(allowed()); assertFalse(claim { claimed++; true })
        assertEquals(1, physical.actions)
    }

    @Test fun fiveArgumentCollectionForwardsLiveCallerPermissionTogetherWithTaskPermission() {
        val tasks = PhoneTasks(); val physical = Driver()
        val original = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, original)
        bound.observe(false, false)
        var callerAllowed = true
        var entered = 0
        physical.duringCollect = {
            entered++
            val allowed = checkNotNull(physical.collectGate)
            assertTrue(allowed())
            callerAllowed = false
            assertFalse(allowed()) // Must remain live inside the real physical call.
        }
        bound.collect("s1", 1, 3, null) { callerAllowed }
        assertEquals(1, entered)
        val allowed = checkNotNull(physical.collectGate)
        assertFalse(allowed())
        callerAllowed = true
        assertTrue(allowed())
        tasks.setPaused(true); assertFalse(allowed())
        tasks.setPaused(false); assertTrue(allowed())
        tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(allowed())
        assertFalse(tasks.isCurrent(original))
    }
    @Test fun sixArgumentCollectionCarriesLiveSourceChecksAndTheOriginalTaskGate() {
        val tasks = PhoneTasks(); val physical = Driver()
        val original = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, original)
        bound.observe(false, false)
        var denied: String? = null
        val checked = mutableListOf<String?>()
        var entered = 0
        physical.collected = CollectResult(listOf("public"), 1, "partial", null,
            readPackages = setOf("app", "other.app"))
        physical.duringCollect = {
            entered++
            val source = checkNotNull(physical.collectSourceGate)
            assertTrue(checkNotNull(physical.collectGate)())
            assertTrue(source("other.app"))
            denied = "other.app"
            assertFalse(source("other.app"))
            assertTrue(source("app"))
        }
        val result = bound.collect("s1", 1, 3, null, { true }) { pkg ->
            checked += pkg
            pkg != denied
        }
        assertEquals(1, entered)
        assertEquals(listOf("other.app", "other.app", "app"), checked)
        assertEquals(setOf("app", "other.app"), result.readPackages)
        assertEquals(result.readPackages, result.copy(stopReason = "copied").readPackages)
        val allowed = checkNotNull(physical.collectGate)
        val source = checkNotNull(physical.collectSourceGate)
        val beforeBlocked = checked.size
        tasks.setPaused(true); assertFalse(allowed()); assertFalse(source("app"))
        assertEquals(beforeBlocked, checked.size)
        tasks.setPaused(false); assertTrue(allowed())
        tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(allowed()); assertFalse(source("app"))
        assertEquals(beforeBlocked, checked.size)
        assertThrows(InterruptedException::class.java) {
            bound.collect("s1", 1, 3, null, { true }) { true }
        }
        assertEquals(1, entered)
    }

    @Test fun fourArgumentScrollSourcesKeepTheActualOwnerGateAndCoordinateClaim() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        val checked = mutableListOf<Set<String>>()
        var denied = false
        physical.duringScroll = {
            val source = checkNotNull(physical.scrollSourceGate)
            assertTrue(source(setOf("other.app")))
            denied = true
            assertFalse(source(setOf("other.app")))
            assertTrue(source(setOf("app")))
        }
        val result = bound.perform(PhoneAction.Scroll("s1", null, PhoneAction.Direction.DOWN), { true }, null) { sources ->
            checked += sources
            !denied || "other.app" !in sources
        }
        assertTrue(result.ok)
        assertEquals(listOf(setOf("other.app"), setOf("other.app"), setOf("app")), checked)
        val source = checkNotNull(physical.scrollSourceGate)
        val claim = checkNotNull(physical.capturedAdmission)
        var claims = 0
        assertTrue(claim { claims++; true })
        val calls = checked.size
        tasks.setPaused(true)
        assertFalse(source(setOf("app")))
        assertFalse(claim { claims++; true })
        assertEquals(calls, checked.size)
        tasks.setPaused(false); tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(source(setOf("app")))
        assertFalse(claim { claims++; true })
        assertEquals(calls, checked.size)
        assertEquals(1, claims)
        val actions = physical.actions
        assertThrows(InterruptedException::class.java) {
            bound.perform(PhoneAction.Scroll("s1", null, PhoneAction.Direction.DOWN), { true }, null) { true }
        }
        assertEquals(actions, physical.actions)
    }

    @Test fun sevenArgumentCollectBatchKeepsOwnerPauseAndObservationPublication() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        val checked = mutableListOf<Set<String>>()
        var denied = false
        var entered = 0
        physical.collected = CollectResult(listOf("public"), 1, "partial",
            ScreenSnapshot("sBatch", "public screen", "App", "app"))
        physical.duringCollect = {
            entered++
            assertTrue(checkNotNull(physical.collectGate)())
            assertTrue(checkNotNull(physical.collectSourceGate)("other.app"))
            val batch = checkNotNull(physical.collectBatchGate)
            assertTrue(batch(linkedSetOf("other.app", "cover.app")))
            denied = true
            assertFalse(batch(linkedSetOf("other.app", "cover.app")))
        }
        val result = bound.collect("s1", 1, 3, null, { true }, { true }) { sources ->
            checked += sources
            !denied
        }
        assertEquals(1, entered)
        assertEquals(listOf(setOf("other.app", "cover.app"), setOf("other.app", "cover.app")), checked)
        assertSame(physical.collected, result)
        assertNotNull(bound.target("sBatch", 1))
        val batch = checkNotNull(physical.collectBatchGate)
        val calls = checked.size
        tasks.setPaused(true)
        assertFalse(batch(setOf("app"))); assertEquals(calls, checked.size)
        tasks.setPaused(false); tasks.stop("replacement"); tasks.clearStop(); tasks.begin()
        assertFalse(batch(setOf("app"))); assertEquals(calls, checked.size)
        assertThrows(InterruptedException::class.java) {
            bound.collect("sBatch", 1, 3, null, { true }, { true }) { true }
        }
        assertEquals(1, entered)
    }
}
