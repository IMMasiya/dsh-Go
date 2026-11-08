package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Bundle
import android.test.AndroidTestCase
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAppIdentity
import java.util.concurrent.atomic.AtomicInteger

/** Uses real Android Bundles, driver result processing and the original coordinate receipt state. */
@Suppress("DEPRECATION")
class BackgroundPostActionInvalidationTest : AndroidTestCase() {
    private class Fixture {
        val sends = AtomicInteger()
        val peer = object : PrivilegedChannel {
            override fun alive() = true
            override fun close() {}
            override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle {
                beforeSend()
                sends.incrementAndGet()
                return Bundle().apply {
                    putInt(Proto.OWNER_SCOPE_VERSION, 1)
                    putString(Proto.OWNER, request.getString(Proto.OWNER))
                    putBoolean(Proto.OK, true)
                    putInt(Proto.TARGET_IDENTITY_VERSION, 1)
                    putString(Proto.PKG, "example.app"); putInt(Proto.TARGET_UID, 10123)
                    // Action ACK is valid, but no COUNT/SECURE or usable afterVisual exists.
                }
            }
        }
        val driver = BackgroundDisplay(channelProvider = { peer },
            journal = BackgroundResourceJournal({ null }, { true }).apply { load() },
            mayUse = { true }, admitUse = { action -> action(); true })
        fun field(name: String) = BackgroundDisplay::class.java.getDeclaredField(name).apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val io = field("resourceIo").get(driver) as BackgroundDisplayIo<PrivilegedChannel>
        val coordinates = field("coordinateImage").get(driver) as BackgroundCoordinateImage
        val original = BackgroundCoordinateImage.Receipt("old-receipt", 48, 48)
        init {
            field("currentTarget").set(driver, PhoneAppIdentity("example.app", 10123))
            field("targetReady").setBoolean(driver, true)
            field("coordinateSupported").setBoolean(driver, true)
            io.call { io.startResource(peer, { beforeSend -> beforeSend(); Unit }) { true } }
            coordinates.candidate("b-old", original)
            driver.acceptVisualObservation("b-old")
        }
        fun finish() { check(io.release { true }) }
    }

    fun testSuccessfulBackWithNoPostSnapshotRevokesTheOldAcceptedReceipt() {
        val f = Fixture()
        try {
            val result = f.driver.perform(PhoneAction.Key("b-old", PhoneAction.GlobalKey.BACK))
            assertTrue(result.ok)
            assertNull(result.screen)
            assertEquals(1, f.sends.get())
            f.driver.acceptVisualObservation("b-old") // A delayed old acceptance must not revive it.
            assertNull(f.coordinates.take("b-old"))
        } finally { f.finish() }
    }

    fun testPostActionRetiresItsOcrTokenWithoutTouchingAnotherResource() {
        val f = Fixture(); val other = Fixture()
        try {
            f.field("coordinateOcrEpoch").set(f.driver, 7L)
            val result = f.driver.perform(PhoneAction.Key("b-old", PhoneAction.GlobalKey.BACK))
            assertTrue(result.ok)
            assertNull(result.screen)
            assertNull(f.field("coordinateOcrEpoch").get(f.driver))
            assertNull(f.coordinates.take("b-old"))
            assertEquals(other.original, other.coordinates.take("b-old"))
            assertEquals(0, other.sends.get())
        } finally { f.finish(); other.finish() }
    }
}
