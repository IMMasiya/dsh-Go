package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class TreeTransactionsTest {
    @Test fun secondConnectionCannotStartBeforeLastLiveNodeAndClose() {
        val first = Any(); val second = Any(); val live = CountDownLatch(1); val finish = CountDownLatch(1)
        val attempted = CountDownLatch(1); val madeSecond = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        val gate = TreeTransactions<Any> { order += if (it === first) "close A" else "close B"; true }
        val pool = Executors.newFixedThreadPool(2)
        try {
            val a = pool.submit { gate.read(first, { first }) {
                live.countDown(); assertTrue(finish.await(5, TimeUnit.SECONDS)); order += "recycle A"
            } }
            assertTrue(live.await(5, TimeUnit.SECONDS))
            val b = pool.submit { attempted.countDown(); gate.read(second, {
                order += "open B"; madeSecond.countDown(); second
            }) { order += "node B" } }
            assertTrue(attempted.await(5, TimeUnit.SECONDS)); assertEquals(1L, madeSecond.count)
            finish.countDown(); a.get(5, TimeUnit.SECONDS); b.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("recycle A", "close A", "open B", "node B", "close B"), order)
        } finally { finish.countDown(); pool.shutdownNow() }
    }

    @Test fun unconfirmedCloseDropsTheIdentityAndFreesTheGate() {
        val owner = Any(); val client = Any()
        val attempted = mutableListOf<Any>()
        val stuck = TreeRegistration<Any> { attempted += it; check(false) }
        val gate = TreeTransactions<TreeRegistration<Any>>(
            close = { it.close { it.unregister() } },
            abandon = { it.close { it.unregister() } },
        )
        // The read body succeeds, but the platform cannot confirm the close. The
        // transaction retries once via abandon, drops the identity, and frees the gate
        // instead of deadlocking every later read.
        assertEquals("accepted input", gate.read(owner, { stuck }) { it.register(client) {}; "accepted input" })
        assertTrue(gate.ready())
        // Both close attempts stay recorded: the read's own close, then the abandon retry.
        assertEquals(listOf(client, client), attempted)
        // A fresh connection can now be opened by the same owner.
        assertEquals("read again", gate.read(owner, { TreeRegistration<Any> { } }) { "read again" })
    }

}
