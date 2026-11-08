// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Local changes: blocking, one owner per task (the bridge serialises calls on one worker
// thread); a UiAutomation control-tree read rendered to the screen text format, so text-only
// models can use 不打扰模式 too; IME policy HIDE; JPEG capture with bounded first-frame readiness; display
// sized to the phone's aspect (short side 720). No commands, paths or display ids are accepted
// from callers.
package io.github.ccch1mneyyy.dsh_app.phone.background

import android.accessibilityservice.AccessibilityServiceInfo
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.PendingIntent
import android.app.UiAutomation
import android.content.Context
import android.content.Intent
import io.github.ccch1mneyyy.dsh_app.phone.a11y.ImageGeometry
import io.github.ccch1mneyyy.dsh_app.phone.a11y.ImageObservation
import io.github.ccch1mneyyy.dsh_app.phone.a11y.VisualFrame
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.hardware.input.InputManager
import android.media.ImageReader
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import android.os.SystemClock
import android.os.Trace
import android.text.InputType
import android.util.SparseArray
import android.view.Display
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import io.github.ccch1mneyyy.dsh_app.phone.SensitiveWords
import java.io.ByteArrayOutputStream
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Runs as shell uid (inside the Shizuku UserService, or the adb-launched app_process).
 * Owns at most one trusted virtual display at a time (one per task) and all the
 * privileged primitives against it. Thread-safe via a single lock; every op has its own
 * deadline. Never throws across the call boundary: faults become a stable [Proto.ERROR] code.
 */
class PrivilegedDisplayCore(private val context: Context) {

    // Guarded by lock, one recent frame only; never a permission to drive coordinates.
    private var visualObservation: BackgroundVisualObservation? = null

    private val privileged: Context by lazy {
        if (Process.myUid() == Process.SHELL_UID)
            context.createPackageContext("com.android.shell", Context.CONTEXT_IGNORE_SECURITY)
        else context
    }
    private val displays by lazy { privileged.getSystemService(DisplayManager::class.java) }
    private val activities by lazy { privileged.getSystemService(ActivityManager::class.java) }
    private val keyguard by lazy { privileged.getSystemService(KeyguardManager::class.java) }
    private val taskDisplayIdField by lazy {
        runCatching { ActivityManager.RunningTaskInfo::class.java.getField("displayId") }.getOrNull()
    }

    private val lock = ReentrantLock()
    private val preview = BackgroundPreviewState()
    // Only created after an explicit preview request; never creates a display or a channel.
    private var previewWorker: ExecutorService? = null
    @Volatile private var owner: String? = null
    @Volatile private var display: VirtualDisplay? = null
    @Volatile private var reader: ImageReader? = null
    private var pendingReader: ImageReader? = null
    private var readerAllocationUncertain = false
    private var width = 0
    private var height = 0
    private val released = AtomicBoolean(false)
    private var strictOwner = false
    private var selfCheckOwner = false
    private var selfCheckWindow: BackgroundInputProbe? = null
    private var releasingDisplayId: Int? = null
    private var displayCreationAttempted = false
    private var displayApiReleased = false
    private var lastReleasedOwner: String? = null
    private var lastReleaseNeverCreated = false
    private val taskManager by lazy { Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null) }
    private val rootTasksMethod by lazy {
        Class.forName("android.app.IActivityTaskManager").getMethod("getAllRootTaskInfosOnDisplay", Int::class.javaPrimitiveType)
    }
    private val rootTaskInfoType by lazy { Class.forName("android.app.ActivityTaskManager\$RootTaskInfo") }

    private fun rootTasksEmpty(displayId: Int): Boolean {
        val result = rootTasksMethod.invoke(taskManager, displayId) as? List<*> ?: throw Fault("releaseQueryFailed")
        if (result.any { !rootTaskInfoType.isInstance(it) }) throw Fault("releaseQueryFailed")
        return result.isEmpty()
    }

    private class Fault(val code: String) : Exception()

    /** The single entry point for both transports. Always returns a response Bundle. */
    fun handle(request: Bundle): Bundle {
        val response = Bundle()
        val op = request.getString(Proto.OP)
        var selfCheckReply = op == Proto.OP_SELF_CHECK_PROBE
        try {
            if (op == Proto.OP_PROBE) {
                response.putBoolean(Proto.OK, true)
                response.putInt(Proto.UID, Process.myUid())
                response.putString("revision", Proto.REVISION)
                response.putInt(Proto.PREVIEW_VERSION, 1)
                response.putInt(Proto.VIEWPORT_VERSION, 1)
                // A real successful full query is required; finding the reflective method is insufficient.
                if (runCatching { rootTasksEmpty(Display.DEFAULT_DISPLAY) }.isSuccess) {
                    response.putInt(Proto.RELEASE_RECEIPT, 1)
                    response.putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
                }
                return response
            }
            if (op == Proto.OP_COLLECT_SYSTEM_IME) {
                // Independent of display ownership, gates, UiAutomation and injection.
                val evidence = io.github.ccch1mneyyy.dsh_app.diagnostics.SystemImeEvidence
                val now = System.currentTimeMillis()
                // An old queued IPC must not begin a new read after its prompt expired.
                val capture = if (evidence.requestFresh(request.getLong(Proto.IME_REQUESTED_AT), now))
                    io.github.ccch1mneyyy.dsh_app.diagnostics.SystemImeLogcat.collect(request.getInt(Proto.IME_PID))
                else io.github.ccch1mneyyy.dsh_app.diagnostics.SystemImeLogcat.Capture("timeout", now)
                response.putBoolean(Proto.OK, capture.code == "ok" || capture.code == "noEvents")
                response.putString(Proto.ERROR, capture.code)
                response.putLong("capturedAt", capture.capturedAt)
                response.putLongArray("imeTimes", capture.events.map { it.timestamp }.toLongArray())
                response.putStringArray("imeEvents", capture.events.map { it.event }.toTypedArray())
                response.putIntArray("imeFromUser", capture.events.map { when (it.fromUser) { true -> 1; false -> 0; null -> -1 } }.toIntArray())
                response.putStringArray("imeReasons", capture.events.map { it.reason }.toTypedArray())
                response.putStringArray("imeOrigins", capture.events.map { it.origin }.toTypedArray())
                return response
            }
            if (op == Proto.OP_PREVIEW) {
                return previewRequest(request)
            }
            if (op == Proto.OP_DESTROY) {
                releaseAll()
                response.putBoolean(Proto.OK, true)
                return response
            }
            if (op == Proto.OP_GATE) {
                lock.withLock { gateProbe(response) }
                if (!response.containsKey(Proto.ERROR)) response.putBoolean(Proto.OK, true)
                return response
            }
            if (op == Proto.OP_GRANT_SECURE_SETTINGS) {
                lock.withLock {
                    if (selfCheckOwner) throw Fault("identityChanged")
                    grantSecureSettings(request.getInt(Proto.USER))
                }
                response.putBoolean(Proto.OK, true)
                return response
            }
            lock.withLock {
                selfCheckReply = selfCheckReply || selfCheckOwner
                try { dispatch(op, request, response) }
                catch (e: Throwable) { visualObservation = null; throw e }
            }
            if (!response.containsKey(Proto.ERROR)) response.putBoolean(Proto.OK, true)
        } catch (e: Throwable) {
            response.putBoolean(Proto.OK, false)
            response.putString(Proto.ERROR, failureCode(e))
            val detail = if (selfCheckReply) (e as? InputProbe.Failure)?.observation?.encode() else failureDetail(e)
            detail?.let { response.putString(Proto.ERROR_DETAIL, it) }
        }
        return response
    }

    private fun failureCode(e: Throwable): String = when (e) {
        is Fault -> e.code
        is InputProbe.Failure -> e.code
        is InterruptedException -> "cancelled"
        is SecurityException -> "systemOperationDenied"
        else -> "deviceUnavailable"
    }

    private fun failureDetail(e: Throwable): String? =
        if (e is InputProbe.Failure) e.observation?.encode()
        else if (e is Fault || e is InterruptedException || e is SecurityException) null
        else e.javaClass.simpleName

    private fun dispatch(op: String?, request: Bundle, response: Bundle) {
        if (op == Proto.OP_SELF_CHECK_PROBE) {
            selfCheckProbe(request, response)
            return
        }
        val ownerId = request.getString(Proto.OWNER).orEmpty()
        if (op == null || ownerId.isEmpty()) throw Fault("invalidArguments")
        if (op == Proto.OP_RELEASE) {
            if (selfCheckOwner && !request.containsKey(Proto.RELEASE_RECEIPT)) throw Fault("releaseReceiptRequired")
            if (request.containsKey(Proto.RELEASE_RECEIPT)) {
                if (request.get(Proto.RELEASE_RECEIPT) !is Int || request.getInt(Proto.RELEASE_RECEIPT) != 1) throw Fault("invalidArguments")
                val neverCreated = releaseStrict(ownerId)
                response.putInt(Proto.RELEASE_RECEIPT, 1)
                response.putString(Proto.OWNER, ownerId)
                if (neverCreated) response.putBoolean("neverCreated", true)
                else { response.putBoolean("released", true); response.putBoolean(Proto.TASK_SCOPE_EMPTY, true) }
            } else {
                if (owner == ownerId) releaseAll()
                response.putBoolean("released", true)
            }
            return
        }
        if (selfCheckOwner) throw Fault("identityChanged")
        if (owner != null && owner != ownerId) throw Fault("identityChanged")
        if ((op == Proto.OP_CREATE || op == Proto.OP_LAUNCH) && request.containsKey(Proto.RELEASE_RECEIPT)) {
            if (request.get(Proto.RELEASE_RECEIPT) !is Int || request.getInt(Proto.RELEASE_RECEIPT) != 1) throw Fault("invalidArguments")
            if (lastReleasedOwner == ownerId) throw Fault("identityChanged")
            if (owner == null) {
                owner = ownerId
                strictOwner = true
                releasingDisplayId = null
                displayCreationAttempted = false
                displayApiReleased = false
            }
        }
        if (strictOwner && displayApiReleased) throw Fault("releasePending")
        if (strictOwner && (readerAllocationUncertain || display == null && (displayCreationAttempted || reader != null || pendingReader != null))) throw Fault("releaseUnconfirmed")
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        val pkg = request.getString(Proto.PKG).orEmpty()
        if (!PACKAGE.matches(pkg)) throw Fault("invalidArguments")

        val localVisual = request.getBoolean(Proto.LOCAL_VISUAL) && when (op) {
            Proto.OP_CREATE, Proto.OP_LAUNCH, Proto.OP_OBSERVE, Proto.OP_TAP, Proto.OP_SCROLL -> true
            else -> false
        }
        val previousVisual = if (localVisual && (op == Proto.OP_TAP || op == Proto.OP_SCROLL)) visualObservation else null
        visualObservation = null // Consume before any dispatch, including failed or non-opt-in operations.
        when (op) {
            Proto.OP_CREATE, Proto.OP_LAUNCH -> {
                owner = ownerId
                if (display == null) createDisplay(request)
                else requestedViewport(request)?.let {
                    if (width != it.width || height != it.height) throw Fault("viewportConflict")
                }
                response.putInt(Proto.DISPLAY_ID, displayId())
                launchPackage(pkg)
                sleepChecked(300)
                observe(pkg, request.getBoolean(Proto.WANT_IMAGE), response, localVisual = localVisual)
            }
            Proto.OP_OBSERVE -> {
                requireDisplay(); requireForeground(pkg)
                observe(pkg, request.getBoolean(Proto.WANT_IMAGE), response, requireTree = true, detail = request.getBoolean(Proto.DETAIL), localVisual = localVisual)
            }
            Proto.OP_TAP -> {
                requireDisplay(); requireForeground(pkg)
                tap(pkg, request)
                sleepChecked(250)
                observe(pkg, false, response, localVisual = localVisual)
                if (localVisual) response.putString(Proto.VISUAL_CHANGE,
                    visualObservation?.changeFrom(previousVisual, SystemClock.uptimeMillis()) ?: "unavailable")
            }
            Proto.OP_SCROLL -> {
                requireDisplay(); requireForeground(pkg)
                scroll(pkg, request)
                sleepChecked(250)
                observe(pkg, false, response, localVisual = localVisual)
                if (localVisual) response.putString(Proto.VISUAL_CHANGE,
                    visualObservation?.changeFrom(previousVisual, SystemClock.uptimeMillis()) ?: "unavailable")
            }
            Proto.OP_KEY -> {
                requireDisplay(); requireForeground(pkg)
                globalKey(request.getString(Proto.DIR))
                sleepChecked(250)
                observe(pkg, false, response)
            }
            Proto.OP_TEXT -> {
                requireDisplay(); requireForeground(pkg)
                typeText(pkg, request, response)
                sleepChecked(200)
                observe(pkg, false, response)
            }
            else -> throw Fault("invalidArguments")
        }
    }

    /** One fixed local run; its original owner must RELEASE even when setup or input fails. */
    private fun selfCheckProbe(request: Bundle, response: Bundle) {
        val ownerId = SelfCheckProbeRequest.owner(request.keySet()) { request.get(it) }
            ?: throw Fault("invalidArguments")
        response.putString(Proto.OWNER, ownerId)
        response.putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
        response.putBoolean(Proto.SELF_CHECK_DISPLAY_READY, false)
        if (owner == ownerId && selfCheckOwner) throw Fault("selfCheckAlreadyStarted")
        if (owner != null || lastReleasedOwner == ownerId) throw Fault("identityChanged")
        if (display != null || reader != null || pendingReader != null || readerAllocationUncertain ||
            selfCheckWindow != null) throw Fault("releaseUnconfirmed")

        // Register the fixed purpose before keyguard checks or ANY reader/VD/UI allocation.
        // This also consumes begin: a failure must be cleaned, never injected a second time.
        owner = ownerId
        strictOwner = true
        selfCheckOwner = true
        releasingDisplayId = null
        displayCreationAttempted = false
        displayApiReleased = false
        visualObservation = null
        if (keyguard?.isKeyguardLocked == true) throw Fault("locked")
        createDisplay(Bundle().apply {
            putInt(Proto.SHORT_SIDE, 360)
            putInt(Proto.ASPECT_W, 9)
            putInt(Proto.ASPECT_H, 20)
        }, probe = true)
        val target = display?.display ?: throw Fault("displayMissing")
        if (target.displayId <= Display.DEFAULT_DISPLAY || !target.isValid) throw Fault("displayUnsupported")
        response.putBoolean(Proto.SELF_CHECK_DISPLAY_READY, true)
        val window = BackgroundInputProbe(privileged, target)
        selfCheckWindow = window // A failing show/verify must not lose the actual cleanup job.
        try {
            window.verify { point, time ->
                // An attempted send is not proof of delivery or proof that no input occurred.
                response.putBoolean(Proto.INJECT_OK, false)
                sendMotion(MotionEvent.ACTION_DOWN, point.x, point.y, time, waitForFinish = false)
                sendMotion(MotionEvent.ACTION_UP, point.x, point.y, time, waitForFinish = false)
            }
            response.putBoolean(Proto.INJECT_OK, true) // Only matching receiver DOWN/UP gets here.
        } catch (e: Throwable) {
            response.putString(Proto.INJECT_ERROR, failureCode(e))
            InputProbeDiagnostics.decode(window.failureDetail)?.let {
                response.putString(Proto.ERROR_DETAIL, it.encode())
            }
            throw e
        }
        // No close here: RELEASE owns the same UI job, VD, readers and ATMS confirmation.
    }

    /** Test a real input receiver, not an empty display. Never launches or touches a user app. */
    private fun gateProbe(response: Bundle) {
        // A settings probe must not replace or release an active task's display.
        if (owner != null || display != null) throw Fault("probeBusy")
        try {
            owner = "__gate__"
            createDisplay(Bundle().apply { putInt(Proto.SHORT_SIDE, 360); putInt(Proto.ASPECT_W, 9); putInt(Proto.ASPECT_H, 20) }, probe = true)
            response.putInt(Proto.DISPLAY_ID, displayId())
            var probeDetail: String? = null
            val injection = runCatching {
                val window = BackgroundInputProbe(privileged, checkNotNull(display).display)
                try {
                    window.verify { target, time ->
                        sendMotion(MotionEvent.ACTION_DOWN, target.x, target.y, time, waitForFinish = false)
                        sendMotion(MotionEvent.ACTION_UP, target.x, target.y, time, waitForFinish = false)
                    }
                } finally {
                    // Cleanup failure must replace a delivery failure, not be hidden by use().
                    try { window.close() } finally { probeDetail = window.failureDetail }
                }
            }
            response.putBoolean(Proto.INJECT_OK, injection.isSuccess)
            injection.exceptionOrNull()?.let {
                response.putString(Proto.INJECT_ERROR, failureCode(it))
                (probeDetail ?: failureDetail(it))?.let { detail -> response.putString(Proto.ERROR_DETAIL, detail) }
            }
        } finally {
            releaseAll()
        }
    }

    // ---- display lifecycle -------------------------------------------------

    private fun displayId(): Int = display?.display?.displayId ?: throw Fault("displayMissing")
    private fun requireDisplay() { if (display == null) throw Fault("displayMissing") }

    private fun requestedViewport(request: Bundle): BackgroundPolicy.Viewport? {
        if (!request.containsKey(Proto.VIEWPORT_PRESET)) return null
        val preset = BackgroundPolicy.Viewport.parse(request.get(Proto.VIEWPORT_PRESET)) ?: throw Fault("invalidArguments")
        if (request.containsKey(Proto.ASPECT_W) || request.containsKey(Proto.ASPECT_H) ||
            request.containsKey(Proto.SHORT_SIDE) && request.get(Proto.SHORT_SIDE) != 720) throw Fault("invalidArguments")
        return preset
    }

    private fun createDisplay(request: Bundle, probe: Boolean = false) {
        val shortSide = request.getInt(Proto.SHORT_SIDE, 720).coerceIn(360, 1080)
        val aspectW = request.getInt(Proto.ASPECT_W, 9).coerceAtLeast(1)
        val aspectH = request.getInt(Proto.ASPECT_H, 20).coerceAtLeast(1)
        val preset = requestedViewport(request)
        val size = if (preset == null) BackgroundPolicy.displaySize(shortSide, aspectW, aspectH)
            else intArrayOf(preset.width, preset.height)
        val w = size[0]; val h = size[1]
        if (reader != null || pendingReader != null || readerAllocationUncertain) throw Fault("releasePending")
        readerAllocationUncertain = true
        val ir = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        pendingReader = ir
        readerAllocationUncertain = false
        try {
            // Every flag must resolve; never silently make a focus-stealing display on an old ROM.
            // SECURE is deliberately not requested, so protected content stays protected.
            val flags = try {
                FLAG_NAMES.fold(0) { bits, name ->
                    bits or DisplayManager::class.java.getDeclaredField("VIRTUAL_DISPLAY_FLAG_$name").getInt(null)
                }
            } catch (_: ReflectiveOperationException) { throw Fault("displayUnsupported") }
            // Presentation requires this flag for the gate's inert receiver. Actual tasks keep
            // their existing display flags; this tests delivery, not every target app's policy.
            displayCreationAttempted = true
            val vd = displays.createVirtualDisplay("dsh-background", w, h, 320, ir.surface,
                flags or if (probe) DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION else 0)
            display = vd; reader = ir; pendingReader = null
            releasingDisplayId = vd.display.displayId
            if (vd.display.displayId <= Display.DEFAULT_DISPLAY) throw Fault("displayUnsupported")
            width = w; height = h
            // Keep the virtual display's keyboard off the main screen: IME policy HIDE.
            runCatching { setImePolicyHide(vd.display.displayId) }
        } catch (e: Throwable) {
            if (!strictOwner) {
                runCatching { display?.release() }
                display = null
                closeReaders(strict = false)
            }
            if (e is Fault) throw e else throw Fault("displayUnsupported")
        }
    }

    private fun launchPackage(pkg: String) {
        val display = this.display ?: throw Fault("displayMissing")
        val intent = privileged.packageManager.getLaunchIntentForPackage(pkg) ?: throw Fault("notLaunchable")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        val options = ActivityOptions.makeBasic().apply { launchDisplayId = display.display.displayId }
        // A shell/UserService is not an ActivityManager-attached app process: a PendingIntent
        // avoids Context.startActivity's caller check (Phase, after Aether).
        var pending: PendingIntent? = null
        try {
            pending = PendingIntent.getActivity(
                privileged.createDisplayContext(display.display), display.display.displayId, intent,
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
            )
            pending.send(privileged, 0, null, null, null, null, options.toBundle())
        } catch (_: SecurityException) { throw Fault("launchDenied") }
        catch (_: PendingIntent.CanceledException) { throw Fault("launchCancelled") }
        finally { pending?.let { runCatching { it.cancel() } } }
        // Poll for the target becoming foreground on the owned display.
        val deadline = SystemClock.uptimeMillis() + 4000
        while (true) {
            if (foregroundPackage() == pkg) break
            if (SystemClock.uptimeMillis() >= deadline) throw Fault("displayTargetChanged")
            sleepChecked(120)
        }
    }

    private fun requireForeground(pkg: String) {
        if (foregroundPackage() != pkg) throw Fault("displayTargetChanged")
    }

    private fun foregroundPackage(): String? {
        val id = display?.display?.displayId ?: return null
        val field = taskDisplayIdField ?: return null
        @Suppress("DEPRECATION")
        val task = activities.getRunningTasks(50).firstOrNull { runCatching { field.getInt(it) }.getOrDefault(-1) == id }
        return task?.topActivity?.packageName
    }

    /** Old callers keep their best-effort contract. Strict owners use releaseStrict instead. */
    private fun releaseAll() = lock.withLock {
        if (strictOwner) throw Fault("releaseReceiptRequired") // Never downgrade a strict owner's cleanup.
        visualObservation = null
        stopPreview()
        preview.invalidate()
        runCatching { display?.release() }
        closeReaders(strict = false)
        display = null; owner = null
        strictOwner = false; releasingDisplayId = null; displayCreationAttempted = false; displayApiReleased = false
        readerAllocationUncertain = false
    }

    /** At most current + pending reader are retained; failures prohibit another allocation. */
    private fun closeReaders(strict: Boolean) {
        var failed = false
        try { reader?.close(); reader = null } catch (_: Throwable) { failed = true; if (!strict) reader = null }
        try { pendingReader?.close(); pendingReader = null } catch (_: Throwable) { failed = true; if (!strict) pendingReader = null }
        if (failed && strict) throw Fault("releaseFailed")
        if (readerAllocationUncertain && strict) throw Fault("releaseUnconfirmed")
    }

    private fun releaseStrict(ownerId: String): Boolean {
        // Only the last completed identity/variant is cached; it never touches a new owner.
        if (lastReleasedOwner == ownerId) return lastReleaseNeverCreated
        if (owner != ownerId || !strictOwner) throw Fault("identityChanged")
        visualObservation = null
        stopPreview()
        preview.invalidate()
        selfCheckWindow?.let { window ->
            window.close() // Timeout/failure keeps this SAME window/job and the original owner.
            selfCheckWindow = null
        }
        val neverCreated = !displayCreationAttempted
        if (neverCreated) {
            if (display != null || releasingDisplayId != null) throw Fault("releaseUnconfirmed")
            closeReaders(strict = true)
        } else {
            val displayId = releasingDisplayId ?: throw Fault("releaseUnconfirmed")
            if (!displayApiReleased) {
                val original = display ?: throw Fault("releaseUnconfirmed")
                original.release() // Failure preserves owner, ID and references for an exact retry.
                displayApiReleased = true
            }
            closeReaders(strict = true)
            val deadline = SystemClock.uptimeMillis() + 1_000
            while (!rootTasksEmpty(displayId)) {
                val remaining = deadline - SystemClock.uptimeMillis()
                if (remaining <= 0) throw Fault("releasePending")
                Thread.sleep(minOf(50L, remaining)) // Poll budget only; the actual empty ATMS result is the proof.
            }
        }
        display = null; owner = null; strictOwner = false; selfCheckOwner = false
        releasingDisplayId = null; displayCreationAttempted = false; displayApiReleased = false
        lastReleasedOwner = ownerId
        lastReleaseNeverCreated = neverCreated
        return neverCreated
    }

    // ---- observation (tree + optional screenshot) --------------------------

    private fun observe(pkg: String, wantImage: Boolean, response: Bundle, requireTree: Boolean = false, detail: Boolean = false, localVisual: Boolean = false) {
        visualObservation = null
        val id = displayId()
        response.putInt(Proto.DISPLAY_ID, id)
        response.putString(Proto.FG_PKG, pkg)
        response.putBoolean(Proto.PORTRAIT, height >= width)
        val captureResult = runCatching { tracePhase("dsh.bg.capture") { capture(localVisual) } }
        val captureFailure = captureResult.exceptionOrNull()
        if (captureFailure is InterruptedException ||
            captureFailure is Fault && captureFailure.code == "cancelled") throw captureFailure
        // Other capture faults retain the existing tree-only observation path.
        val shot = captureResult.getOrNull()
        val label = runCatching { appLabel(pkg) }.getOrNull()
        label?.let { response.putString(Proto.APP_LABEL, if (detail) BackgroundTree.cap(it) else it) }
        val treeResult = runCatching { readTree(id, pkg, scanOtherWindows = wantImage && shot != null, inspectVisual = localVisual && shot?.local != null) }
        val failure = treeResult.exceptionOrNull()
        if (failure is InterruptedException || failure is Fault && failure.code == "cancelled") throw failure
        // Pixels alone never identify FLAG_SECURE. Keep an explicit secure failure authoritative.
        val secure = failure is Fault && failure.code == "secureWindow"
        response.putBoolean(Proto.SECURE, secure)
        if (secure) {
            preview.protect()
            response.putBoolean(Proto.POOR, false); response.putInt(Proto.COUNT, 0); return
        }
        // Local preview never enters ScreenSnapshot / MCP. Publish only after the secure verdict.
        if (shot != null) shot.raw?.let { preview.captured(it) }
        else preview.observationUnavailable(if (captureResult.isSuccess) null else "captureFailed")
        // A read must report its failure; observation after an already-dispatched write
        // must not turn that write into a failed action that a caller might replay.
        val tree = if (requireTree) treeResult.getOrThrow() else treeResult.getOrNull()
        if (captureResult.isSuccess && shot == null) {
            if (requireTree) throw Fault("frameNotReady")
            // The action already happened. Never make the caller replay it for an absent frame.
            response.putBoolean(Proto.FRAME_NOT_READY, true)
            response.putBoolean(Proto.POOR, true)
            response.putInt(Proto.COUNT, 0)
            return
        }
        // The screenshot contains the whole viewport, including nodes beyond the emitted
        // text prefix. Never attach it when secrets were found or the scan was incomplete.
        // The typing unlock changes permission to write, never permission to reveal a secret.
        if (wantImage && shot != null) {
            if (tree != null && tree.complete && !tree.hasSecrets) {
                response.putByteArray("imageBytes", shot.jpeg)
                response.putString("imageMime", "image/jpeg")
            } else {
                response.putBoolean(Proto.IMAGE_OMITTED, true)
            }
        }
        if (localVisual && tree != null) {
            val vd = display
            val currentOwner = owner
            val scope = if (vd != null && currentOwner != null) tree.visualWindow?.let {
                BackgroundVisualObservation.Scope(vd, currentOwner, pkg, it)
            } else null
            visualObservation = BackgroundVisualObservation.create(scope, shot?.local,
                tree.complete && tree.elements.count { it.label.isNotEmpty() } >= 5,
                tree.hasSecrets, tree.hasSensitive, SystemClock.uptimeMillis())
        }
        val elements = tree?.elements.orEmpty()
        if (detail) {
            val models = elements.mapIndexed { index, e ->
                Element(index + 1, e.role, e.label, Region.MIDDLE, indent = e.indent,
                    states = e.states, sensitive = e.flags and Proto.FLAG_SENSITIVE != 0,
                    viewId = e.viewId, bounds = ElementBounds(e.bounds.left, e.bounds.top, e.bounds.right, e.bounds.bottom))
            }
            fun payloadFor(count: Int) = Bundle().apply {
                emitElements(elements, this, count, detail = true)
                putInt(Proto.ELEMENT_OVERFLOW, elements.size - count)
                putBoolean(Proto.TREE_COMPLETE, tree?.complete == true)
            }
            var count = BackgroundTree.detailPrefixCount(models)
            var payload = payloadFor(count)
            // Measure the real Parcel, not UTF-8 estimates (Parcel strings are UTF-16).
            // Bounded binary search is only needed if platform encoding exceeds the reserve.
            if (Bundles.marshal(payload).size > BackgroundTree.DETAIL_PARCEL_BYTES) {
                var low = 0
                var high = count
                while (low < high) {
                    val mid = (low + high + 1) / 2
                    val candidate = payloadFor(mid)
                    if (Bundles.marshal(candidate).size <= BackgroundTree.DETAIL_PARCEL_BYTES) low = mid else high = mid - 1
                }
                count = low
                payload = payloadFor(count)
            }
            response.putAll(payload)
        } else emitElements(elements, response)
    }

    private fun emitElements(elements: List<BgNode>, response: Bundle, count: Int = 120, detail: Boolean = false) {
        val capped = elements.take(count)
        val n = capped.size
        response.putInt(Proto.COUNT, n)
        response.putBoolean(Proto.POOR, elements.count { it.label.isNotEmpty() } < 5)
        val role = arrayOfNulls<String>(n); val label = arrayOfNulls<String>(n)
        val viewIds = arrayOfNulls<String>(n)
        val states = arrayOfNulls<String>(n); val flags = IntArray(n)
        val region = IntArray(n); val indent = IntArray(n)
        val bounds = if (detail) IntArray(n * 4) else null
        for (i in 0 until n) {
            val e = capped[i]
            role[i] = e.role; label[i] = e.label; states[i] = e.states.joinToString("\u0001")
            viewIds[i] = e.viewId
            flags[i] = e.flags; region[i] = e.region; indent[i] = e.indent
            if (bounds != null) {
                bounds[i * 4] = e.bounds.left; bounds[i * 4 + 1] = e.bounds.top
                bounds[i * 4 + 2] = e.bounds.right; bounds[i * 4 + 3] = e.bounds.bottom
            }
        }
        response.putStringArray(Proto.A_ROLE, role)
        response.putStringArray(Proto.A_LABEL, label)
        response.putStringArray(Proto.A_VIEW_ID, viewIds)
        response.putStringArray(Proto.A_STATES, states)
        response.putIntArray(Proto.A_FLAGS, flags)
        response.putIntArray(Proto.A_REGION, region)
        response.putIntArray(Proto.A_INDENT, indent)
        if (bounds != null) response.putIntArray(Proto.A_BOUNDS, bounds)
    }

    private fun appLabel(pkg: String): String? {
        val pm = privileged.packageManager
        return runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() }.getOrNull()
    }

    private class CaptureResult(val jpeg: ByteArray, val raw: BackgroundPreviewState.RawFrame?, val local: ImageObservation?)

    /** Null means only absent/black frames; other capture failures remain distinguishable. */
    private fun capture(localVisual: Boolean = false): CaptureResult? {
        val ir = lock.withLock {
            if (pendingReader != null || readerAllocationUncertain) throw Fault("releasePending")
            val vd = display ?: throw Fault("displayMissing")
            readerAllocationUncertain = true
            val next = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            pendingReader = next
            readerAllocationUncertain = false // Register before setSurface or closing the previous reader can throw.
            preview.readerChanged()
            vd.surface = next.surface
            reader?.close()
            reader = next
            pendingReader = null
            next
        }
        try {
            val deadline = SystemClock.uptimeMillis() + BackgroundFrameReadiness.CAPTURE_TIMEOUT_MS
            for (attempt in 0..1) {
                if (released.get() || Thread.currentThread().isInterrupted) throw Fault("cancelled")
                if (attempt > 0 && SystemClock.uptimeMillis() >= deadline) return null
                var image = ir.acquireLatestImage()
                while (image == null) {
                    val remaining = deadline - SystemClock.uptimeMillis()
                    if (remaining <= 0) return null
                    sleepChecked(minOf(40L, remaining))
                    image = ir.acquireLatestImage()
                }
                val capturedAt = SystemClock.uptimeMillis()
                try {
                    val plane = image.planes.singleOrNull() ?: throw Fault("screenshotFailed")
                    if (plane.pixelStride != 4 || plane.rowStride < width * 4) throw Fault("screenshotFailed")
                    val pixels = ByteBuffer.allocate(width * height * 4)
                    val src = plane.buffer.duplicate()
                    for (row in 0 until height) {
                        val start = row * plane.rowStride
                        src.limit(start + width * 4); src.position(start)
                        pixels.put(src)
                    }
                    pixels.flip()
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.copyPixelsFromBuffer(pixels)
                        val remaining = deadline - SystemClock.uptimeMillis()
                        when (BackgroundFrameReadiness.next(isMostlyBlack(bitmap), attempt, remaining)) {
                            BackgroundFrameReadiness.Next.NOT_READY -> return null
                            BackgroundFrameReadiness.Next.RETRY -> Unit
                            BackgroundFrameReadiness.Next.READY -> {
                                val buffer = ByteArrayOutputStream()
                                tracePhase("dsh.bg.jpeg") {
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 80, buffer)
                                }
                                // Reuse the already-copied RGBA buffer only for an active local preview.
                                // No JPEG decode round-trip: both preview sources compare identical pixels.
                                val raw = if (preview.acceptsCandidate())
                                    BackgroundPreviewState.RawFrame(width, height, pixels.array()) else null
                                // Sampling cannot turn an existing successful capture/action into a failure.
                                val local = if (localVisual) try {
                                    val frame = VisualFrame.capture(width, height) { y, row ->
                                        bitmap.getPixels(row, 0, width, 0, y, width, 1)
                                    }
                                    ImageObservation(ImageGeometry(0, 0, 1f, 1f, width, height), capturedAt, frame)
                                } catch (_: Exception) { null } else null
                                return CaptureResult(buffer.toByteArray(), raw, local)
                            }
                        }
                    } finally { bitmap.recycle() }
                } finally { image.close() }
                // Release the first Image before taking one more from this same reader/surface.
                sleepChecked(BackgroundFrameReadiness.retryWaitMs(deadline - SystemClock.uptimeMillis()))
            }
            return null
        } finally { /* reader kept for next frame; closed on release */ }
    }

    private fun isMostlyBlack(bitmap: Bitmap): Boolean {
        val stepX = (bitmap.width / 24).coerceAtLeast(1)
        val stepY = (bitmap.height / 48).coerceAtLeast(1)
        var dark = 0; var total = 0
        var y = 0
        while (y < bitmap.height) {
            var x = 0
            while (x < bitmap.width) {
                val c = bitmap.getPixel(x, y)
                val luma = ((c shr 16 and 0xff) * 30 + (c shr 8 and 0xff) * 59 + (c and 0xff) * 11) / 100
                if (luma < 12) dark++
                total++
                x += stepX
            }
            y += stepY
        }
        return total > 0 && dark * 100 / total >= 98
    }

    // ---- local, read-only preview ------------------------------------------

    private fun previewRequest(request: Bundle): Bundle {
        if (!request.containsKey(Proto.PREVIEW_ENABLED)) throw Fault("invalidArguments")
        val enabled = request.getBoolean(Proto.PREVIEW_ENABLED)
        var work: Pair<ExecutorService, BackgroundPreviewState.Ticket>? = null
        // Disabling is a cleanup operation, never a cancellable shared-stream request.
        if (enabled) {
            if (!lock.tryLock()) return previewReply(request, busy = true)
        } else lock.lock()
        val reply = try {
            if (selfCheckOwner) throw Fault("identityChanged")
            val requestedOwner = request.getString(Proto.OWNER)
            if (requestedOwner.isNullOrEmpty() || requestedOwner != owner) throw Fault("identityChanged")
            requireDisplay()
            if (!enabled) stopPreview()
            else {
                preview.configure(true)
                if (keyguard?.isKeyguardLocked == true) preview.protect()
                else preview.begin(SystemClock.uptimeMillis())?.let { ticket ->
                    val worker = previewWorker ?: Executors.newSingleThreadExecutor { job ->
                        Thread(job, "dsh-preview").apply { isDaemon = true }
                    }.also { previewWorker = it }
                    work = worker to ticket
                }
            }
            previewReply(request)
        } finally { lock.unlock() }
        work?.let { (worker, ticket) ->
            try { worker.execute { renderPreview(ticket) } }
            catch (_: RejectedExecutionException) { preview.finish(ticket) } // Closed after unlock.
        }
        return reply
    }

    /** The reply is a small immutable cache snapshot; no frame wait, tree read, or JPEG work. */
    private fun previewReply(request: Bundle, busy: Boolean = false): Bundle {
        val value = preview.snapshot()
        return Bundle().apply {
            putBoolean(Proto.OK, true)
            putString(Proto.PREVIEW_STATE, if (busy) "busy" else value.state)
            putLong(Proto.PREVIEW_GENERATION, value.generation)
            putLong(Proto.PREVIEW_SEQUENCE, value.sequence)
            if (!busy) {
                value.reason?.let { putString(Proto.PREVIEW_REASON, it) }
                val frame = value.frame
                if (frame != null && request.getLong(Proto.PREVIEW_AFTER_SEQUENCE, -1) != value.sequence) {
                    putInt(Proto.PREVIEW_WIDTH, frame.width)
                    putInt(Proto.PREVIEW_HEIGHT, frame.height)
                    putByteArray(Proto.PREVIEW_BYTES, frame.jpeg)
                }
            }
        }
    }

    /** Caller owns the display lock. Shutdown never waits for an encoder; its ticket is retired. */
    private fun stopPreview() {
        preview.configure(false)
        previewWorker?.shutdown()
        previewWorker = null
    }

    private fun renderPreview(ticket: BackgroundPreviewState.Ticket) {
        var bitmap: Bitmap? = null
        var thumbnail: Bitmap? = null
        try {
            // Agent dispatch owns this same lock for its complete capture, including the wait.
            // A preview therefore cannot consume an Image from the reader an Agent is awaiting.
            if (!lock.tryLock()) return
            try {
                if (!preview.current(ticket)) return
                if (keyguard?.isKeyguardLocked == true) { preview.protect(); return }
                val image = reader?.acquireLatestImage()
                if (image != null) try {
                    val plane = image.planes.singleOrNull() ?: throw Fault("screenshotFailed")
                    if (plane.pixelStride != 4 || plane.rowStride < width * 4) throw Fault("screenshotFailed")
                    val pixels = ByteBuffer.allocate(width * height * 4)
                    val source = plane.buffer.duplicate()
                    for (row in 0 until height) {
                        val start = row * plane.rowStride
                        source.limit(start + width * 4); source.position(start)
                        pixels.put(source)
                    }
                    pixels.flip()
                    bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    bitmap!!.copyPixelsFromBuffer(pixels)
                } finally { image.close() }
                // All Image/buffer access ends before releaseAll can close its ImageReader.
            } finally { lock.unlock() }
            if (bitmap == null) {
                val raw = ticket.candidate ?: return // A static frame keeps the same cached image.
                bitmap = Bitmap.createBitmap(raw.width, raw.height, Bitmap.Config.ARGB_8888)
                bitmap!!.copyPixelsFromBuffer(ByteBuffer.wrap(raw.pixels))
            }
            preview.consumed(ticket)
            val source = bitmap!!
            if (isMostlyBlack(source)) { preview.unavailable(ticket, "blackFrame"); return }
            val scale = minOf(1f, 360f / minOf(source.width, source.height),
                800f / maxOf(source.width, source.height))
            val w = (source.width * scale).toInt().coerceAtLeast(1)
            val h = (source.height * scale).toInt().coerceAtLeast(1)
            val small = Bitmap.createScaledBitmap(source, w, h, true).also { thumbnail = it }
            val pixels = IntArray(w * h)
            small.getPixels(pixels, 0, w, 0, 0, w, h)
            if (!preview.changed(ticket, pixels, w, h)) return
            val output = ByteArrayOutputStream()
            if (!small.compress(Bitmap.CompressFormat.JPEG, 65, output)) throw Fault("screenshotFailed")
            val bytes = output.toByteArray()
            if (bytes.size > BackgroundPreviewState.MAX_BYTES) {
                preview.unavailable(ticket, "frameTooLarge"); return
            }
            preview.publish(ticket, BackgroundPreviewState.Frame(w, h, pixels, bytes), SystemClock.uptimeMillis())
        } catch (_: Exception) {
            preview.unavailable(ticket, "captureFailed")
        } finally {
            if (thumbnail !== bitmap) thumbnail?.recycle()
            bitmap?.recycle()
            preview.finish(ticket)
        }
    }

    // ---- UiAutomation control-tree read ------------------------------------

    private class TreeRead(val targetId: Int = 0, val inspectVisual: Boolean = false) {
        var visualWindow: BackgroundVisualObservation.Window? = null
        var hasSensitive = false
        val elements = ArrayList<BgNode>()
        var visited = 0
        var complete = true
        var hasSecrets = false
        var target: AccessibilityNodeInfo? = null
    }

    private fun readTree(displayId: Int, pkg: String, scanOtherWindows: Boolean = false, inspectVisual: Boolean = false): TreeRead {
        val vd = display ?: throw Fault("displayMissing")
        val conn = TreeConnection(context, pkg)
        try {
            val automation = try {
                tracePhase("dsh.bg.treeConnect") { conn.open(vd.display) }
            } catch (_: Throwable) { throw Fault("treeUnavailable") }
            return tracePhase("dsh.bg.treeRead") {
                readTree(automation, displayId, pkg, scanOtherWindows = scanOtherWindows, inspectVisual = inspectVisual)
            }
        } finally { tracePhase("dsh.bg.treeClose") { conn.close() } }
    }

    private fun readTree(
        automation: UiAutomation, displayId: Int, pkg: String,
        targetId: Int = 0, scanOtherWindows: Boolean = false, inspectVisual: Boolean = false,
    ): TreeRead {
        runCatching { invoke(automation, "clearCache") }
        @Suppress("UNCHECKED_CAST")
        val all = invoke(automation, "getWindowsOnAllDisplays") as? SparseArray<List<AccessibilityWindowInfo>>
            ?: throw Fault("treeUnavailable")
        val displayWindows = all.get(displayId).orEmpty()
        val windows = displayWindows.filter {
            it.type == AccessibilityWindowInfo.TYPE_APPLICATION
        }
        val roots = ArrayList<AccessibilityNodeInfo?>()
        try {
            for (window in windows) roots.add(window.root)
            val selected = BackgroundTree.selectApplicationWindow(roots.map { it?.packageName?.toString() }, pkg)
                ?: throw Fault(if (roots.firstOrNull() != null) "displayTargetChanged" else "treeUnavailable")
            val tree = TreeRead(targetId, inspectVisual)
            if (inspectVisual && displayWindows.size == 1 && windows.size == 1) {
                val window = windows[selected.index]
                tree.visualWindow = try {
                    val bounds = Rect().also { window.getBoundsInScreen(it) }
                    BackgroundVisualObservation.Window(window.id, bounds.left, bounds.top, bounds.right, bounds.bottom)
                } catch (_: Exception) { null } // Extra metadata failure only disables the local summary.
            }
            if (!scanOtherWindows && roots.size > 1) tree.complete = false
            try {
                walk(roots[selected.index]!!, tree, 0, 600)
                assignRegions(tree.elements)
                if (scanOtherWindows) for (index in selected.scanOrder.drop(1)) {
                    try {
                        // Same privacy walk and total budget, but never expose secondary
                        // elements or let them take ownership of a main-window target id.
                        walk(roots[index], tree, 0, 600, emitElements = false)
                    } catch (e: Exception) {
                        if (e is InterruptedException || e is java.util.concurrent.CancellationException || e is Fault) throw e
                        // A secondary read failure prevents an image, not the already
                        // successful main-window text. Primary errors remain outside this catch.
                        tree.complete = false
                    }
                }
                return tree
            } catch (e: Throwable) {
                tree.target?.recycle()
                throw e
            }
        } finally { roots.forEach { it?.recycle() } }
    }

    private fun walk(node: AccessibilityNodeInfo?, tree: TreeRead, indent: Int, budget: Int, emitElements: Boolean = true) {
        if (node == null) { tree.complete = false; return }
        if (tree.visited >= budget) { tree.complete = false; return }
        tree.visited++
        if (node.isVisibleToUser && isSecret(node)) tree.hasSecrets = true
        val text = if (emitElements || tree.inspectVisual) bestText(node) else ""
        if (tree.inspectVisual && node.isVisibleToUser && !tree.hasSensitive) {
            tree.hasSensitive = try {
                // Check raw text too: bestText may drop an oversized blank value.
                backgroundVisualSensitive(node.text, node.contentDescription, node.hintText, node.viewIdResourceName)
            } catch (_: Exception) { true } // Incomplete additional privacy evidence cannot fail the element action.
        }
        var childIndent = indent
        if (emitElements) {
            val actionable = node.isClickable || node.isLongClickable || node.isEditable || node.isCheckable || node.isScrollable
            val emit = actionable || (text.isNotEmpty() && node.isVisibleToUser)
            if (emit && node.isVisibleToUser) {
                val rect = Rect().also { node.getBoundsInScreen(it) }
                tree.elements.add(toElement(node, text, rect, indent))
                // Retain the exact node assigned this screen id, not whichever editor has focus.
                if (tree.elements.size == tree.targetId) tree.target = AccessibilityNodeInfo.obtain(node)
                if (node.isScrollable) childIndent = indent + 1
            }
        }
        for (i in 0 until node.childCount) {
            if (tree.visited >= budget) { tree.complete = false; break }
            val child = node.getChild(i)
            try { walk(child, tree, childIndent, budget, emitElements) } finally { child?.recycle() }
        }
    }

    private fun toElement(node: AccessibilityNodeInfo, text: String, rect: Rect, indent: Int): BgNode {
        val cls = node.className?.toString().orEmpty()
        val password = node.isPassword || secretInput(node)
        val hint = node.hintText?.toString().orEmpty()
        val description = node.contentDescription?.toString().orEmpty()
        val secret = isSecret(node)
        val role = role(node, cls)
        val filled = !node.isShowingHintText && !node.text.isNullOrBlank()
        val label = BackgroundTree.label(text, description.ifBlank { hint }, filled, password, secret)
        val states = ArrayList<String>()
        // l10n:keep privileged screen protocol
        if (node.isFocused) states.add("已聚焦")
        // l10n:keep privileged screen protocol
        if (node.isSelected) states.add("已选")
        // l10n:keep privileged screen protocol
        if (node.isCheckable) states.add(if (node.isChecked) "已勾选" else "未勾选")
        // l10n:keep privileged screen protocol
        if (!node.isEnabled) states.add("不可用")
        // l10n:keep privileged screen protocol
        if (node.isScrollable) states.add("可滚动")
        // l10n:keep privileged screen protocol
        if (password) states.add("密码·不可代填")
        var flags = 0
        if (node.isPassword) flags = flags or Proto.FLAG_PASSWORD
        if (secret) flags = flags or Proto.FLAG_SECRET
        if (node.isEditable) flags = flags or Proto.FLAG_EDITABLE
        if (node.isClickable) flags = flags or Proto.FLAG_CLICKABLE
        if (node.isLongClickable) flags = flags or Proto.FLAG_LONGCLICK
        if (node.isScrollable) flags = flags or Proto.FLAG_SCROLLABLE
        if (node.isFocused) flags = flags or Proto.FLAG_FOCUSED
        val viewId = node.viewIdResourceName
        if (SensitiveWords.confirmHit(label, viewId) != null) flags = flags or Proto.FLAG_SENSITIVE
        return BgNode(role, label, states, flags, indent, rect, node.packageName?.toString(), viewId)
    }

    private fun role(node: AccessibilityNodeInfo, cls: String): String = when {
        // l10n:keep privileged screen protocol
        node.isEditable -> "输入框"
        // l10n:keep privileged screen protocol
        cls.endsWith("Switch") || cls.contains("Switch") -> "开关"
        // l10n:keep privileged screen protocol
        node.isCheckable -> "勾选框"
        // l10n:keep privileged screen protocol
        cls.contains("Button") || node.isClickable && node.text != null -> "按钮"
        // l10n:keep privileged screen protocol
        cls.contains("ImageView") && node.isClickable -> "图片"
        // l10n:keep privileged screen protocol
        cls.contains("RecyclerView") || cls.contains("ListView") -> "列表"
        // l10n:keep privileged screen protocol
        node.isClickable -> "按钮"
        // l10n:keep privileged screen protocol
        else -> "文本"
    }

    private fun isSecret(node: AccessibilityNodeInfo): Boolean = node.isPassword || secretInput(node) ||
        SensitiveWords.secretHit(
            node.hintText?.toString(), node.contentDescription?.toString(),
            // Resource ids classify inputs: a sendOtp button requests a code, not a secret value.
            // Keep hint/description masking for non-editable secret displays.
            if (node.isEditable) node.viewIdResourceName else null,
        ) != null

    private fun secretInput(node: AccessibilityNodeInfo): Boolean {
        val klass = node.inputType and InputType.TYPE_MASK_CLASS
        val variation = node.inputType and InputType.TYPE_MASK_VARIATION
        return (klass == InputType.TYPE_CLASS_TEXT && variation in setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) ||
            (klass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
    }

    private fun bestText(node: AccessibilityNodeInfo): String {
        node.text?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        node.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        if (node.isEditable) node.hintText?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        return ""
    }

    private fun assignRegions(out: List<BgNode>) {
        if (out.isEmpty()) return
        val top = height / 3; val bottom = height * 2 / 3
        for (e in out) {
            val cy = (e.bounds.top + e.bounds.bottom) / 2
            e.region = when {
                cy < top -> 0
                cy < bottom -> 1
                else -> 2
            }
        }
    }

    // ---- actions -----------------------------------------------------------

    private fun resolveElement(pkg: String, request: Bundle): BgNode {
        val index = request.getInt(Proto.ELEMENT, -1)
        if (index < 1) throw Fault("invalidArguments")
        val elements = readTree(displayId(), pkg).elements
        val e = elements.getOrNull(index - 1) ?: throw Fault("elementMissing")
        val expectRole = request.getString(Proto.EXPECT_ROLE)
        val expectLabel = request.getString(Proto.EXPECT_LABEL)
        val expectViewId = request.getString(Proto.EXPECT_VIEW_ID)
        // The whole label is part of the identity: safety was checked against the observed
        // target, so "Invoice 12 view" turning into "Invoice 12 delete" must not pass.
        if (expectRole != null && expectRole != e.role ||
            expectLabel != null && expectLabel != e.label ||
            expectViewId != null && expectViewId != e.viewId) throw Fault("staleSnapshot")
        return e
    }

    private fun tap(pkg: String, request: Bundle) {
        val e = resolveElement(pkg, request)
        val cx = (e.bounds.left + e.bounds.right) / 2
        val cy = (e.bounds.top + e.bounds.bottom) / 2
        val long = request.getBoolean(Proto.LONG)
        injectTap(cx, cy, long)
    }

    private fun scroll(pkg: String, request: Bundle) {
        val dir = request.getString(Proto.DIR) ?: "down"
        val bounds = if (request.containsKey(Proto.ELEMENT)) {
            val target = resolveElement(pkg, request)
            if (target.flags and Proto.FLAG_SCROLLABLE == 0) throw Fault("inputRejected")
            Rect(target.bounds).also {
                if (!it.intersect(0, 0, width, height)) throw Fault("inputRejected")
            }
        } else null
        val cx = bounds?.centerX() ?: (width / 2)
        val cy = bounds?.centerY() ?: (height / 2)
        val span = if (bounds == null) (if (dir == "left" || dir == "right") width else height) / 3 else
            (if (dir == "left" || dir == "right") bounds.width() else bounds.height()) / 3
        if (bounds != null && span < 1) throw Fault("inputRejected")
        val p = when (dir) {
            "up" -> intArrayOf(cx, cy - span, cx, cy + span)
            "down" -> intArrayOf(cx, cy + span, cx, cy - span)
            "left" -> intArrayOf(cx - span, cy, cx + span, cy)
            "right" -> intArrayOf(cx + span, cy, cx - span, cy)
            else -> throw Fault("invalidArguments")
        }
        val duration = 400
        if (bounds != null) {
            val vd = display ?: throw Fault("displayMissing")
            val displayContext = context.createDisplayContext(vd.display)
            val configured = displayContext.createConfigurationContext(displayContext.resources.configuration)
            val slop = ViewConfiguration.get(configured).scaledTouchSlop
            val steps = SwipeGeometry.steps(duration)
            val lastX = SwipeGeometry.coordinate(p[0], p[2], steps - 1, steps)
            val lastY = SwipeGeometry.coordinate(p[1], p[3], steps - 1, steps)
            if (maxOf(kotlin.math.abs(lastX - p[0]), kotlin.math.abs(lastY - p[1])) <= slop)
                throw Fault("inputRejected")
        }
        injectSwipe(p[0], p[1], p[2], p[3], duration)
    }

    private fun globalKey(key: String?) {
        val code = KEYS[key] ?: throw Fault("invalidArguments")
        val now = SystemClock.uptimeMillis()
        injectKey(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        sleepChecked(4)
        injectKey(KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
    }

    private fun typeText(pkg: String, request: Bundle, response: Bundle) {
        val text = request.getString(Proto.TEXT).orEmpty()
        val index = request.getInt(Proto.ELEMENT, -1)
        if (index < 1 || text.isEmpty() || text.length > 500 || '\u0000' in text) throw Fault("invalidArguments")
        val vd = display ?: throw Fault("displayMissing")
        val conn = TreeConnection(context, pkg)
        try {
            val automation = try { conn.open(vd.display) } catch (_: Throwable) { throw Fault("textConnectionUnavailable") }
            val node = readTree(automation, vd.display.displayId, pkg, index).target ?: throw Fault("elementMissing")
            try {
                if (!node.refresh()) throw Fault("textTargetChanged")
                val current = toElement(node, bestText(node), Rect(), 0)
                val expectRole = request.getString(Proto.EXPECT_ROLE)
                val expectLabel = request.getString(Proto.EXPECT_LABEL)
                val expectViewId = request.getString(Proto.EXPECT_VIEW_ID)
                if (expectRole != null && expectRole != current.role ||
                    expectLabel != null && expectLabel != current.label ||
                    expectViewId != null && expectViewId != current.viewId) throw Fault("staleSnapshot")
                if (isSecret(node) && !request.getBoolean(Proto.ALLOW_SECRET, false)) throw Fault("textRequiresManual")
                if (!node.isEditable || node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT })
                    throw Fault("textUnsupported")
                val submit = request.getBoolean(Proto.SUBMIT)
                if (submit) {
                    if (!node.isFocused && !node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)) throw Fault("textFocusMissing")
                    if (!node.refresh() || !node.isFocused) throw Fault("textTargetChanged")
                }
                // type(id, text) replaces the entire value, regardless of the old selection.
                val accepted = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                })
                response.putBoolean(Proto.ACCEPTED, accepted)
                if (!accepted) throw Fault("inputRejected")
                val deadline = SystemClock.uptimeMillis() + 1500
                while (true) {
                    runCatching { invoke(automation, "clearCache") }
                    if (!node.refresh()) throw Fault("textTargetChanged")
                    val now = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
                    if (now == text) break
                    if (SystemClock.uptimeMillis() >= deadline) throw Fault("textReadbackMismatch")
                    sleepChecked(50)
                }
                response.putString(Proto.READBACK, BackgroundTree.cap(text))
                if (submit) {
                    if (!node.isFocused) throw Fault("textTargetChanged")
                    globalKey("enter")
                }
            } finally { node.recycle() }
        } finally { conn.close() }
    }

    // ---- injection shims (hidden APIs via reflection) ----------------------

    private fun injectTap(x: Int, y: Int, long: Boolean) {
        val down = SystemClock.uptimeMillis()
        sendMotion(MotionEvent.ACTION_DOWN, x, y, down)
        sleepChecked(if (long) 650 else 60)
        sendMotion(MotionEvent.ACTION_UP, x, y, down)
    }

    private fun injectSwipe(sx: Int, sy: Int, ex: Int, ey: Int, duration: Int) {
        val down = SystemClock.uptimeMillis()
        sendMotion(MotionEvent.ACTION_DOWN, sx, sy, down)
        val steps = SwipeGeometry.steps(duration)
        for (step in 1..steps) {
            sleepChecked((duration / steps).toLong())
            val mx = SwipeGeometry.coordinate(sx, ex, step, steps)
            val my = SwipeGeometry.coordinate(sy, ey, step, steps)
            if (step < steps) sendMotion(MotionEvent.ACTION_MOVE, mx, my, down)
        }
        sendMotion(MotionEvent.ACTION_UP, ex, ey, down)
    }

    private fun sendMotion(action: Int, x: Int, y: Int, downTime: Long, waitForFinish: Boolean = true) {
        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x.toFloat(), y.toFloat(), 0)
        event.source = InputDevice.SOURCE_TOUCHSCREEN
        try { inject(event, waitForFinish) } finally { event.recycle() }
    }

    private fun injectKey(src: KeyEvent) {
        val event = KeyEvent(src.downTime, src.eventTime, src.action, src.keyCode, 0, src.metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD, src.scanCode, src.flags, InputDevice.SOURCE_KEYBOARD)
        inject(event)
    }

    // Runs in the shell-uid privileged process (Shizuku UserService or app_process),
    // which the app hidden-API policy that lint models doesn't apply to.
    @SuppressLint("BlockedPrivateApi")
    private fun inject(event: InputEvent, waitForFinish: Boolean = true) {
        val id = display?.display?.displayId ?: throw Fault("displayMissing")
        // WAIT_FOR_FINISH can time out after the event was delivered. A false result is
        // not proof of rejection: never replay the same event with another mode.
        val accepted = try {
            InputEvent::class.java.getDeclaredMethod("setDisplayId", Int::class.javaPrimitiveType)
                .apply { isAccessible = true }.invoke(event, id)
            // Android 17 removed InputManager.getInstance(); the Context service works on every version.
            val manager = privileged.getSystemService(InputManager::class.java)
            InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType)
                .invoke(manager, event, if (waitForFinish) 2 else 0) == true
        } catch (e: InvocationTargetException) {
            throw e.targetException // the system's own answer, e.g. SecurityException
        } catch (_: ReflectiveOperationException) {
            throw Fault("inputApiUnavailable") // the hidden API is missing or blocked here
        }
        // Only the gate uses ASYNC: its window receipt, not this boolean, decides delivery.
        if (waitForFinish && !accepted) throw Fault("inputRejected")
    }

    private fun setImePolicyHide(displayId: Int) {
        val sm = Class.forName("android.os.ServiceManager")
        val binder = sm.getMethod("getService", String::class.java).invoke(null, "window") as IBinder
        val wm = Class.forName("android.view.IWindowManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        // DISPLAY_IME_POLICY_HIDE == 2
        wm.javaClass.getMethod("setDisplayImePolicy", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            .invoke(wm, displayId, 2)
    }

    /**
     * `pm grant` of WRITE_SECURE_SETTINGS to this app, through the binder `pm` itself uses:
     * IPackageManager up to Android 10, IPermissionManager from 11 (Android 15 added a device id
     * before the user). Fixed permission, fixed package.
     */
    @SuppressLint("PrivateApi")
    private fun grantSecureSettings(userId: Int) {
        val (service, type) = if (Build.VERSION.SDK_INT >= 30) "permissionmgr" to "android.permission.IPermissionManager"
            else "package" to "android.content.pm.IPackageManager"
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, service) as IBinder
        val manager = Class.forName("$type\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        val grant = manager.javaClass.methods.first { it.name == "grantRuntimePermission" }
        val permission = SecureSettingsGrant.PERMISSION
        val args = when {
            grant.parameterTypes.size == 3 -> arrayOf<Any>(Proto.APP_PACKAGE, permission, userId)
            // VirtualDeviceManager.PERSISTENT_DEVICE_ID_DEFAULT, or Context.DEVICE_ID_DEFAULT.
            grant.parameterTypes[2] == String::class.java -> arrayOf<Any>(Proto.APP_PACKAGE, permission, "default:0", userId)
            else -> arrayOf<Any>(Proto.APP_PACKAGE, permission, 0, userId)
        }
        try {
            grant.invoke(manager, *args)
        } catch (e: InvocationTargetException) {
            throw e.targetException
        }
    }

    /** Fixed phase labels only: never pass screen content, app names, or task identifiers. */
    private inline fun <T> tracePhase(name: String, block: () -> T): T {
        Trace.beginSection(name)
        try { return block() } finally { Trace.endSection() }
    }

    private fun invoke(target: Any, method: String): Any? =
        UiAutomation::class.java.getMethod(method).invoke(target)

    private fun sleepChecked(ms: Long) {
        if (ms <= 0) return
        if (released.get()) throw Fault("cancelled")
        try { Thread.sleep(ms) } catch (_: InterruptedException) { throw Fault("cancelled") }
    }

    /**
     * A short-lived, node-only UiAutomation bound to the owned display (after Phase's
     * DisplayTextConnection): FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES, so it does not evict the
     * user's other services; a hand-rolled IUiAutomationConnection so disconnect never restores
     * the main screen's rotation; only the node connection is exposed (no shell/input/permission).
     */
    private class TreeConnection(private val context: Context, private val target: String) {
        private val clientType = Class.forName("android.accessibilityservice.IAccessibilityServiceClient")
        private val managerType = Class.forName("android.view.accessibility.IAccessibilityManager")
        private val manager = Class.forName("android.view.accessibility.IAccessibilityManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null,
                Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
                    .invoke(null, Context.ACCESSIBILITY_SERVICE))
        private val token = Binder()
        private var client: Any? = null
        private var automation: UiAutomation? = null

        fun open(display: Display): UiAutomation {
            if (Build.VERSION.SDK_INT < 34) throw Fault("textConnectionUnavailable")
            val connectionType = Class.forName("android.app.IUiAutomationConnection")
            val connection = Proxy.newProxyInstance(connectionType.classLoader, arrayOf(connectionType)) { proxy, method, args ->
                when (method.name) {
                    "asBinder" -> token
                    "connect" -> { runCatching { register(args!![0]!!) }; null }
                    "disconnect" -> { unregister(); null }
                    "toString" -> "DshTreeConnection"
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.get(0)
                    else -> throw UnsupportedOperationException("node only")
                }
            }
            val value = UiAutomation::class.java.getConstructor(Context::class.java, connectionType)
                .newInstance(context.createDisplayContext(display), connection) as UiAutomation
            automation = value
            UiAutomation::class.java.getMethod("connectWithTimeout", Int::class.javaPrimitiveType, Long::class.javaPrimitiveType)
                .invoke(value, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES, 3000L)
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
            managerType.getMethod("registerUiTestAutomationService", IBinder::class.java, clientType,
                AccessibilityServiceInfo::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
                .invoke(manager, token, value, info, userId, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            client = value
        }

        private fun unregister() {
            val value = client ?: return
            runCatching { managerType.getMethod("unregisterUiTestAutomationService", clientType).invoke(manager, value) }
            client = null
        }

        fun close() {
            runCatching { automation?.let { UiAutomation::class.java.getMethod("disconnect").invoke(it) } }
            automation = null
            unregister()
        }
    }

    companion object {
        private val PACKAGE = Regex("[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+")
        private val FLAG_NAMES = listOf(
            "PUBLIC", "OWN_CONTENT_ONLY", "SUPPORTS_TOUCH", "DESTROY_CONTENT_ON_REMOVAL",
            "TRUSTED", "OWN_FOCUS", "STEAL_TOP_FOCUS_DISABLED")
        private val KEYS = mapOf(
            "back" to KeyEvent.KEYCODE_BACK, "home" to KeyEvent.KEYCODE_HOME,
            "enter" to KeyEvent.KEYCODE_ENTER, "delete" to KeyEvent.KEYCODE_DEL,
            "tab" to KeyEvent.KEYCODE_TAB, "escape" to KeyEvent.KEYCODE_ESCAPE,
            "up" to KeyEvent.KEYCODE_DPAD_UP, "down" to KeyEvent.KEYCODE_DPAD_DOWN,
            "left" to KeyEvent.KEYCODE_DPAD_LEFT, "right" to KeyEvent.KEYCODE_DPAD_RIGHT)
    }
}

/** Live-tree node captured during a read; carries what the driver needs to build a TargetInfo. */
class BgNode(
    val role: String,
    val label: String,
    val states: List<String>,
    val flags: Int,
    val indent: Int,
    val bounds: android.graphics.Rect,
    val packageName: String?,
    val viewId: String? = null,
) {
    var region: Int = 1
}
