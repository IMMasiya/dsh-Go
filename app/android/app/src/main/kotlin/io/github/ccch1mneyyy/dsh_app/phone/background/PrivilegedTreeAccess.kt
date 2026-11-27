package io.github.ccch1mneyyy.dsh_app.phone.background

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.os.Binder
import android.os.Trace
import android.os.Build
import android.os.IBinder
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import java.lang.reflect.Proxy

/** One peer-wide short UiAutomation transaction, including every live node and exact close. */
internal class PrivilegedTreeAccess(private val context: Context) {
    class Failure(val code: String) : Exception()
    private val transactions = TreeTransactions<TreeConnection>(
        close = { connection -> tracePhase("dsh.bg.treeClose") { connection.close() } },
        // The first close could not be confirmed; try once more before dropping the identity.
        abandon = { connection -> tracePhase("dsh.bg.treeAbandon") { connection.close() } },
    )
    fun ready(): Boolean = transactions.ready()
    fun closeOwned(scope: Any): Boolean = transactions.closeOwned(scope)
    fun <T> read(scope: Any, display: Display, pkg: String, unavailable: String, body: (UiAutomation) -> T): T = try {
        TreeTrace.log("read begin scope=${System.identityHashCode(scope)} pkg=$pkg")
        transactions.read(scope, { TreeConnection(context, pkg) }) { connection ->
            TreeTrace.log("body c=${connection.traceId()}")
            val automation = try { tracePhase("dsh.bg.treeConnect") { connection.open(display) } }
                catch (_: Throwable) { throw Failure(unavailable) }
            TreeTrace.log("body connected c=${connection.traceId()}")
            try { body(automation) }
            finally { TreeTrace.log("body done c=${connection.traceId()}") }
        }
    } catch (_: TreeTransactions.CleanupPending) { throw Failure("treeCleanupPending") }

    private inline fun <T> tracePhase(name: String, body: () -> T): T {
        Trace.beginSection(name)
        try { return body() } finally { Trace.endSection() }
    }

    private class TreeConnection(private val context: Context, private val target: String) {
        private val clientType = Class.forName("android.accessibilityservice.IAccessibilityServiceClient")
        private val managerType = Class.forName("android.view.accessibility.IAccessibilityManager")
        private val manager = Class.forName("android.view.accessibility.IAccessibilityManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null,
                Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
                    .invoke(null, Context.ACCESSIBILITY_SERVICE))
        private val token = Binder()
        private val registration = TreeRegistration<Any> { original ->
            managerType.getMethod("unregisterUiTestAutomationService", clientType).invoke(manager, original)
        }
        private var automation: UiAutomation? = null

        fun traceId(): Int = System.identityHashCode(this)

        fun open(display: Display): UiAutomation {
            TreeTrace.log("open begin c=${traceId()} pkg=$target")
            if (Build.VERSION.SDK_INT < 34) throw Failure("textConnectionUnavailable")
            val connectionType = Class.forName("android.app.IUiAutomationConnection")
            val connection = Proxy.newProxyInstance(connectionType.classLoader, arrayOf(connectionType)) { proxy, method, args ->
                when (method.name) {
                    "asBinder" -> token
                    // Register must confirm; a swallowed failure leaves a never-registered
                    // phantom (empty tree) that also cannot be unregistered (close deadlock).
                    // Capture the real error for diagnosis instead of hiding it.
                    "connect" -> {
                        TreeTrace.log("proxy connect c=${traceId()}")
                        try { register(args!![0]!!) }
                        catch (e: Throwable) {
                            TreeTrace.log("proxy connect c=${traceId()} register FAILED ${e::class.java.simpleName}: ${e.cause?.message ?: e.message}")
                            android.util.Log.e("DshTree", "registerUiTestAutomationService failed", e)
                        }
                        null
                    }
                    "disconnect" -> { TreeTrace.log("proxy disconnect c=${traceId()}"); registration.unregister(); null }
                    "toString" -> "DshTreeConnection"
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.get(0)
                    else -> throw UnsupportedOperationException("node only")
                }
            }
            val value = UiAutomation::class.java.getConstructor(Context::class.java, connectionType)
                .newInstance(context.createDisplayContext(display), connection) as UiAutomation
            automation = value
            try {
                UiAutomation::class.java.getMethod("connectWithTimeout", Int::class.javaPrimitiveType, Long::class.javaPrimitiveType)
                    .invoke(value, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES, 3000L)
                TreeTrace.log("open connected c=${traceId()}")
            } catch (e: Throwable) {
                TreeTrace.log("open FAILED c=${traceId()} ${e::class.java.simpleName}: ${e.cause?.message ?: e.message}")
                throw e
            }
            return value
        }

        private fun register(value: Any) {
            val info = AccessibilityServiceInfo().apply {
                packageNames = arrayOf(target)
                eventTypes = AccessibilityEvent.TYPES_ALL_MASK
                feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
                flags = AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            }
            AccessibilityServiceInfo::class.java.getMethod("setCapabilities", Int::class.javaPrimitiveType)
                .invoke(info, AccessibilityServiceInfo.CAPABILITY_CAN_RETRIEVE_WINDOW_CONTENT)
            val userId = Class.forName("android.os.UserHandle").getMethod("getUserId", Int::class.javaPrimitiveType)
                .invoke(null, context.applicationInfo.uid)
            val method = managerType.getMethod("registerUiTestAutomationService", IBinder::class.java, clientType,
                AccessibilityServiceInfo::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            registration.register(value) { original ->
                method.invoke(manager, token, original, info, userId, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            }
        }

        fun close(): Boolean {
            TreeTrace.log("close begin c=${traceId()} automation=${automation != null}")
            val complete = registration.close {
                automation?.let { UiAutomation::class.java.getMethod("disconnect").invoke(it) }
            }
            TreeTrace.log("close end c=${traceId()} complete=$complete")
            if (complete) automation = null
            return complete
        }
    }

}
