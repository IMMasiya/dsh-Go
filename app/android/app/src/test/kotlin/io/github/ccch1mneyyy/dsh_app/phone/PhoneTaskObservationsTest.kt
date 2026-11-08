package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneTaskObservationsTest {
    private class Driver : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        var actions = 0
        var collectGate: (() -> Boolean)? = null
        var duringCollect: () -> Unit = {}
        var collected = CollectResult(emptyList(), 0, "done", null)
        override fun availability() = Availability(true)
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s1", "screen", "App", "app")
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "button", "send", "app", "App", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions++; return ActionResult(true, "done") }
        override fun open(packageName: String) = ActionResult(true, "opened")
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = collected
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult {
            collectGate = allowed
            duringCollect()
            return collected
        }
        override fun foregroundPackage() = "app"
    }
    private fun owner(tasks: PhoneTasks) = (tasks.begin() as PhoneTasks.Begin.Go).owner

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
}
