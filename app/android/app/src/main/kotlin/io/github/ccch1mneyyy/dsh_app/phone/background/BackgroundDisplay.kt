package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import io.github.ccch1mneyyy.dsh_app.phone.ActionResult
import io.github.ccch1mneyyy.dsh_app.phone.Availability
import io.github.ccch1mneyyy.dsh_app.phone.CollectResult
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAppIdentity
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import io.github.ccch1mneyyy.dsh_app.phone.PhoneDriver
import io.github.ccch1mneyyy.dsh_app.phone.PhoneRegistry
import io.github.ccch1mneyyy.dsh_app.phone.PhoneScreen
import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import io.github.ccch1mneyyy.dsh_app.phone.ScreenSnapshot
import io.github.ccch1mneyyy.dsh_app.phone.TargetInfo
import io.github.ccch1mneyyy.dsh_app.phone.VisualScope
import io.github.ccch1mneyyy.dsh_app.phone.VisualBounds
import io.github.ccch1mneyyy.dsh_app.phone.a11y.ImageGeometry
import io.github.ccch1mneyyy.dsh_app.phone.a11y.LocalOcrBoundary
import io.github.ccch1mneyyy.dsh_app.phone.a11y.LocalOcrResult
import io.github.ccch1mneyyy.dsh_app.phone.a11y.LocalOcrVisual
import io.github.ccch1mneyyy.dsh_app.phone.a11y.MlKitLocalOcr
import io.github.ccch1mneyyy.dsh_app.phone.VisualTarget

/**
 * BACKGROUND [PhoneDriver] (screen ids `b<n>`): reads and drives the trusted virtual display
 * through its original privileged channel. [BackgroundControl] retains the task's resource
 * until strict cleanup succeeds; UI selection never routes this driver's operations.
 * All calls are serialised by the bridge; this class never retries a dispatched action.
 */
class BackgroundDisplay internal constructor(
    private val channelProvider: () -> PrivilegedChannel?,
    journal: BackgroundResourceJournal,
    private val mayUse: () -> Boolean,
    private val admitUse: ((() -> Unit) -> Boolean),
    private val viewport: BackgroundPolicy.Viewport = BackgroundPolicy.Viewport.PORTRAIT,
    private val onResourceReady: (PrivilegedChannel) -> Unit = {},
    private val localOcr: MlKitLocalOcr? = null,
    private val localOcrAllowed: (PhoneAppIdentity) -> Boolean = { false },
) : PhoneDriver {

    private val resourceIo = BackgroundDisplayIo<PrivilegedChannel>()
    private val resourceScope = BackgroundResourceScope(resourceIo, journal, "task", viewport.preset)
    internal val ownerToken: String get() = resourceIo.owner
    internal val physicalComplete: Boolean get() = resourceScope.physicalComplete
    internal val originalPeerLost: Boolean get() = resourceIo.peer()?.alive() == false
    /** Never a RELEASE on another peer: only that peer's exact absence receipt completes this drained scope. */
    internal fun recoverLostPeer(verify: (BackgroundResourceJournal.Record) -> Boolean): Boolean =
        try { resourceScope.recover({ !it.alive() }, verify) } catch (_: Exception) { false }
    internal fun seal() { coordinateImage.invalidateScope(); resourceIo.seal() }
    internal fun previewAvailable(peer: PrivilegedChannel): Boolean =
        resourceScope.allocationReady && resourceIo.previewAvailable(peer)
    internal fun previewClosed(): Boolean = resourceIo.previewClosed()
    internal fun tryPreview(request: Bundle): Bundle? = resourceIo.tryPreview { peer ->
        if (!resourceScope.allocationReady) return@tryPreview null
        if (request.get(Proto.OP) == Proto.OP_PROBE) peer.tryExecute(request)
        else peer.tryExecute(OwnerScopeProtocol.request(request))?.let { OwnerScopeProtocol.response(ownerToken, it) }
    }

    override val screen: PhoneScreen = PhoneScreen.BACKGROUND

    @Volatile private var currentTarget: PhoneAppIdentity? = null
    private var targetReady = false
    private var coordinateSupported = false
    private var afterVisualSupported = false
    private val coordinateImage = BackgroundCoordinateImage()
    private var coordinateOcrEpoch: Long? = null
    private var counter = 0
    private var lastScreenId: String? = null
    private var lastElements: List<Element> = emptyList()
    private var previousLabels: Set<String> = emptySet()

    override fun availability(): Availability {
        if (Build.VERSION.SDK_INT < BackgroundPolicy.MIN_SDK)
            // l10n:keep agent screen protocol
            return Availability(false, "不打扰模式需要 Android 14 或更高版本")
        val channel = resourceIo.peer() ?: channelProvider()
        if (channel == null || !channel.alive())
            // l10n:keep agent screen protocol
            return Availability(false, "不打扰模式的特权通道未就绪")
        return Availability(true)
    }

    private fun channel(): PrivilegedChannel =
        // l10n:keep agent screen protocol
        resourceIo.peer() ?: channelProvider() ?: throw IllegalStateException("背景屏通道未就绪")

    override fun open(target: PhoneAppIdentity): ActionResult = try {
        resourceIo.call {
            clearSnapshot()
            targetReady = false
            currentTarget = target
            check(mayUse()) { Reasons.of("deviceUnavailable") }
            val active = channel()
            if (resourceIo.peer() == null) {
                val probe = active.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                check(probe.get(Proto.OK) == true && probe.get(Proto.RELEASE_RECEIPT) is Int && probe.getInt(Proto.RELEASE_RECEIPT) == 1) {
                    "所选后台服务不支持安全收尾，请更新并重新连接该通道。" // l10n:keep agent resource result
                }
                check(OwnerScopeProtocol.supported(probe)) { Reasons.of("scopeUnsupported") }
                check(TargetIdentity.supported(probe.get(Proto.TARGET_IDENTITY_VERSION))) {
                    Reasons.of("targetIdentityUnsupported")
                }
                check(BackgroundPolicy.supportsViewport(viewport, probe.get(Proto.VIEWPORT_VERSION))) {
                    Reasons.of("viewportUnsupported")
                }
                val birth = BackgroundRecoveryProtocol.birth(probe::get)
                    ?: error("所选后台服务不支持资源恢复，请更新并重新连接该通道。") // l10n:keep agent resource result
                coordinateSupported = probe.get(Proto.BACKGROUND_COORDINATES) is Int &&
                    probe.getInt(Proto.BACKGROUND_COORDINATES) == 1
                afterVisualSupported = BackgroundAfterVisual.supported(probe.get(Proto.AFTER_LOCAL_VISUAL))
                check(mayUse() && !resourceIo.previewClosed()) { Reasons.of("deviceUnavailable") }
                check(resourceScope.begin(birth)) { BackgroundResourceJournal.REFUSAL }
                val allocated = OwnerScopeProtocol.first(resourceIo, active,
                    BackgroundRecoveryProtocol.allocate(ownerToken, "task", viewport.preset), admitUse)
                val actualId = BackgroundRecoveryProtocol.allocationId(allocated::get)
                    ?: error("后台屏分配未确认，本次启动未执行；请先清理原后台资源。") // l10n:keep agent resource result
                check(resourceScope.allocated(actualId) { mayUse() && !resourceIo.previewClosed() }) {
                    "后台屏分配记录尚未确认，本次启动未执行；请先清理原后台资源。" // l10n:keep agent resource result
                }
            }
            // A pin after a failed/late ID commit can never skip the durable barrier.
            check(resourceScope.allocationReady) { BackgroundResourceJournal.REFUSAL }
            val request = Bundle().apply {
                putString(Proto.OP, Proto.OP_LAUNCH)
                putInt(Proto.RELEASE_RECEIPT, 1)
                putString(Proto.OWNER, ownerToken)
                putTarget(this, target)
                putInt(Proto.SHORT_SIDE, 720)
                putString(Proto.VIEWPORT_PRESET, viewport.preset)
                putBoolean(Proto.LOCAL_VISUAL, true)
                putInt(Proto.WANT_IMAGE, 0)
            }
            val response = OwnerScopeProtocol.execute(active, ownerToken, request) {
                check(admitUse {
                    check(resourceScope.allocationReady)
                    resourceIo.checkDispatch()
                }) { Reasons.of("deviceUnavailable") }
            }
            // Empty allocation never publishes the preview or lends MAIN back.
            onResourceReady(active)
            val result = toResult(response, "已在后台屏打开") // l10n:keep agent screen protocol
            targetReady = result.ok
            result.copy(backgroundOpenConfirmed = result.ok && TargetIdentity.backgroundOpenConfirmed(target,
                response.get(Proto.OK), response.get(Proto.BACKGROUND_OPEN_EVIDENCE), response.get(Proto.DISPLAY_ID),
                response.get(Proto.TARGET_IDENTITY_VERSION), response.get(Proto.PKG), response.get(Proto.TARGET_UID)))
        }
    } catch (error: Throwable) {
        clearSnapshot()
        targetReady = false
        if (resourceIo.peer() == null) resourceIo.seal()
        throw error
    }

    override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot = observeFrame(detail, image, true)

    override fun observe(detail: Boolean, image: Boolean, automaticImage: Boolean): ScreenSnapshot =
        observeFrame(detail, image, true, automaticImage)

    private fun observeFrame(detail: Boolean, image: Boolean, requestLocalText: Boolean, automaticImage: Boolean = false): ScreenSnapshot {
        coordinateImage.clear()
        val started = SystemClock.uptimeMillis()
        val ocrEpoch = if (requestLocalText) localOcr?.enabledEpoch() else null
        val target = currentTarget ?: return idleSnapshot()
        val pixels = image || automaticImage || (ocrEpoch != null && coordinateSupported && localReadAllowed(target))
        check(targetReady) { Reasons.of("targetIdentityUnavailable") }
        val request = Bundle().apply {
            putString(Proto.OP, Proto.OP_OBSERVE)
            putString(Proto.OWNER, ownerToken)
            putTarget(this, target)
            putBoolean(Proto.DETAIL, detail)
            putBoolean(Proto.WANT_IMAGE, pixels)
            if (pixels && coordinateSupported) putInt(Proto.BACKGROUND_COORDINATES, 1)
            putBoolean(Proto.LOCAL_VISUAL, true)
        }
        val response = try {
            resourceIo.call { OwnerScopeProtocol.execute(channel(), ownerToken, request) }
        } catch (e: Exception) {
            clearSnapshot()
            throw e
        }
        requireObservation(response.getBoolean(Proto.OK), response.getString(Proto.ERROR), response.getString(Proto.ERROR_DETAIL))
        requireIdentity(response)
        val local = if (requestLocalText) readLocalText(response, target, ocrEpoch, started) else null
        return ocrSnapshot(response, false, image || (automaticImage && response.get(Proto.POOR) == true), local, ocrEpoch)
    }

    private fun ocrSnapshot(response: Bundle, markNew: Boolean, image: Boolean,
                            result: LocalOcrVisual.Output?, ocrEpoch: Long?): ScreenSnapshot {
        var local = result
        val epochCurrent = ocrEpoch == null || localOcr?.enabledEpoch() == ocrEpoch
        if (!epochCurrent && local != null) local = LocalOcrVisual.Output(
            LocalOcrBoundary.message(LocalOcrResult.Unavailable(
                if (localOcr?.enabled == false) LocalOcrResult.Reason.DISABLED else LocalOcrResult.Reason.CANCELLED)),
            local.sensitiveText, false)
        val snap = snapshot(response, markNew = markNew, publishImage = image && local?.sensitiveText != true,
            localText = local, coordinatesAllowed = local?.sensitiveText != true && (image || (epochCurrent && local?.hasPoints == true)))
        // Public-image credentials retain their original meaning; only OCR-only credentials
        // depend on the recognition setting epoch, including the final Core acceptance boundary.
        if (!image && epochCurrent && local?.hasPoints == true && !local.sensitiveText) coordinateOcrEpoch = ocrEpoch
        return snap
    }

    private fun localReadAllowed(target: PhoneAppIdentity): Boolean = !Thread.currentThread().isInterrupted &&
        targetReady && currentTarget == target && mayUse() && !resourceIo.previewClosed() && localOcrAllowed(target)

    /** The receipt is input evidence, never a claim that every pixel has no sensitive content. */
    private fun readLocalText(response: Bundle, target: PhoneAppIdentity, expectedEpoch: Long?,
                              started: Long): LocalOcrVisual.Output? {
        if (response.get(Proto.POOR) != true) return null
        fun diagnostic(reason: LocalOcrResult.Reason) = LocalOcrVisual.Output(
            LocalOcrBoundary.message(LocalOcrResult.Unavailable(reason)), false, false)
        if (!localReadAllowed(target)) return diagnostic(LocalOcrResult.Reason.PRIVACY_UNVERIFIED)
        val host = localOcr ?: return diagnostic(LocalOcrResult.Reason.NOT_INSTALLED)
        if (expectedEpoch == null || host.enabledEpoch() != expectedEpoch)
            return diagnostic(if (!host.enabled) LocalOcrResult.Reason.DISABLED else LocalOcrResult.Reason.CANCELLED)
        val receipt = if (coordinateSupported && response.get(Proto.OK) == true &&
            response.get(Proto.SECURE) == false && response.get(Proto.FRAME_NOT_READY) != true &&
            response.get(Proto.IMAGE_OMITTED) != true && response.get(Proto.COORDINATE_SCOPE_VERSION) is Int &&
            response.getInt(Proto.COORDINATE_SCOPE_VERSION) == 1 && response.get(Proto.COORDINATE_SCOPE_KNOWN) == true &&
            (response.get(Proto.DISPLAY_ID) as? Int)?.let { it >= 0 } == true &&
            TargetIdentity.receipt(target, response.get(Proto.TARGET_IDENTITY_VERSION), response.get(Proto.PKG), response.get(Proto.TARGET_UID))) {
            BackgroundCoordinateImage.Receipt.parse(response.get(Proto.BACKGROUND_COORDINATES),
                response.get(Proto.COORDINATE_OBSERVATION), response.get(Proto.COORDINATE_WIDTH), response.get(Proto.COORDINATE_HEIGHT))
        } else null
        val jpeg = response.getByteArray("imageBytes")
        if (receipt == null || jpeg == null || jpeg.isEmpty() || response.getString("imageMime") != "image/jpeg")
            return diagnostic(LocalOcrResult.Reason.PRIVACY_UNVERIFIED)
        val deadline = minOf(started + 4_800L, SystemClock.uptimeMillis() + 2_500L)
        val cancelled = { !localReadAllowed(target) || host.enabledEpoch() != expectedEpoch }
        val result = try { BackgroundLocalOcr.read(jpeg, receipt, host, deadline, cancelled) }
        catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return diagnostic(LocalOcrResult.Reason.CANCELLED)
        } catch (_: Exception) { LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE) }
        // An already returned result can contain a same-frame privacy fact. Preserve that
        // fact even if OFF/deadline now suppresses its text and points; no further SDK work.
        val output = LocalOcrVisual.format(result, receipt.width, receipt.height,
            VisualBounds(0, 0, receipt.width, receipt.height), ImageGeometry(0, 0, 1f, 1f, receipt.width, receipt.height))
        if (cancelled()) return diagnostic(if (!host.enabled) LocalOcrResult.Reason.DISABLED else LocalOcrResult.Reason.CANCELLED)
            .copy(sensitiveText = output.sensitiveText)
        if (SystemClock.uptimeMillis() >= deadline) return diagnostic(LocalOcrResult.Reason.DEADLINE)
            .copy(sensitiveText = output.sensitiveText)
        return output
    }

    private fun coordinateEpochCurrent(): Boolean {
        val token = coordinateOcrEpoch ?: return true
        if (localOcr?.enabledEpoch() == token) return true
        coordinateImage.clear()
        return false
    }

    override fun acceptVisualObservation(screenId: String) {
        if (coordinateEpochCurrent()) coordinateImage.accept(screenId)
    }
    override fun visualScope(screenId: String): VisualScope? = coordinateImage.scope(screenId)
    override fun coordinateTarget(action: PhoneAction.TapXY): VisualTarget? {
        if (!coordinateEpochCurrent() || action.gesture != PhoneAction.CoordinateGesture.TAP) return null
        val index = coordinateImage.targetAt(action.screenId, action.x, action.y) ?: return null
        val scope = coordinateImage.scope(action.screenId) ?: return null
        val target = target(action.screenId, index) ?: return null
        return VisualTarget(scope, target)
    }

    /** A failed read is not an empty snapshot; old element numbers are no longer actionable. */
    internal fun requireObservation(ok: Boolean, code: String?, detail: String?) {
        if (ok) return
        clearSnapshot()
        if (code == "targetIdentityChanged" || code == "targetIdentityUnavailable") targetReady = false
        throw IllegalStateException(Reasons.of(code, detail))
    }

    override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult =
        collect(screenId, listElementId, maxPages, until) { true }

    override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult {
        if (!allowed()) return CollectResult(emptyList(), 0, PhoneTasks.STOPPED_MESSAGE, null)
        check(screenId == lastScreenId) { Reasons.of("staleSnapshot") }
        if (maxPages.coerceIn(1, 30) == 1) {
            val selected = lastElements.getOrNull(listElementId - 1)
                ?: throw IllegalStateException(Reasons.of("elementMissing"))
            check(selected.isScrollable) { Reasons.of("inputRejected") }
            val labels = lastElements.drop(listElementId)
                .takeWhile { it.indent > selected.indent }
                .map { it.label }.filter { it.isNotEmpty() }.distinct()
            val stop = if (until != null && labels.any { it.contains(until) }) "untilMatched" else "pageLimit"
            return CollectResult(labels, 1, stop, null)
        }
        val seen = LinkedHashSet<String>()
        var pages = 0
        var stop = "listEnd"
        var last: ScreenSnapshot? = null
        while (pages < maxPages.coerceIn(1, 30)) {
            if (!allowed()) { stop = PhoneTasks.STOPPED_MESSAGE; break }
            val snap = observeFrame(detail = false, image = false, requestLocalText = false)
            last = snap
            val before = seen.size
            for (e in lastElements) if (e.label.isNotEmpty()) seen.add(e.label)
            pages++
            if (until != null && seen.any { it.contains(until) }) { stop = "untilMatched"; break }
            if (seen.size == before) { stop = "listEnd"; break }
            if (pages >= maxPages) { stop = "pageLimit"; break }
            // Preserve the legacy whole-page collect path; explicit list tracking is separate.
            val result = perform(PhoneAction.Scroll(snap.id, null, PhoneAction.Direction.DOWN), allowed)
            if (!result.ok) { stop = result.message; break }
        }
        return CollectResult(seen.toList(), pages, stop, last)
    }

    override fun target(screenId: String, elementId: Int): TargetInfo? {
        if (screenId != lastScreenId) return null
        val e = lastElements.getOrNull(elementId - 1) ?: return null
        return TargetInfo(
            screenId = screenId,
            elementId = elementId,
            role = e.role,
            label = e.label,
            packageName = e.packageName,
            appLabel = null,
            isPassword = e.isPassword,
            isSecretField = e.isSecretField,
            isEditable = e.isEditable,
            viewId = e.viewId,
        )
    }

    override fun perform(action: PhoneAction): ActionResult = perform(action) { true }

    override fun perform(action: PhoneAction, allowed: () -> Boolean): ActionResult {
        val started = if (afterVisualSupported) SystemClock.uptimeMillis() else 0L
        val epoch = localOcr?.enabledEpoch()
        // l10n:keep agent screen protocol
        val target = currentTarget ?: return ActionResult(false, "后台屏还没有打开应用")
        if (!targetReady) return ActionResult(false, Reasons.of("targetIdentityUnavailable"))
        if (action is PhoneAction.Key && action.key != PhoneAction.GlobalKey.BACK) {
            // l10n:keep agent screen protocol
            return ActionResult(false, "后台屏不支持该系统键，未执行；请用返回或打开指定应用")
        }
        // Explicit element ids are checked by PhoneCore before perform; collect owns its internal scrolls.
        if (action is PhoneAction.Scroll && action.elementId == null && action.screenId != lastScreenId) {
            return ActionResult(false, Reasons.of("staleSnapshot"), staleSnapshot = true)
        }
        val after = AfterRead(started, epoch, target, afterVisualSupported && epoch != null && localReadAllowed(target))
        val request = Bundle().apply {
            if (after.requested) putInt(Proto.AFTER_LOCAL_VISUAL, 1)
            putString(Proto.OWNER, ownerToken)
            putTarget(this, target)
        }
        when (action) {
            is PhoneAction.Tap -> {
                request.putString(Proto.OP, Proto.OP_TAP)
                request.putBoolean(Proto.LOCAL_VISUAL, true)
                request.putInt(Proto.ELEMENT, action.elementId)
                request.putBoolean(Proto.LONG, action.long)
                fingerprint(action.elementId, request)
            }
            is PhoneAction.Type -> {
                request.putString(Proto.OP, Proto.OP_TEXT)
                request.putInt(Proto.ELEMENT, action.elementId)
                fingerprint(action.elementId, request)
                request.putString(Proto.TEXT, action.text)
                request.putBoolean(Proto.SUBMIT, action.submit)
                // 解除限制 › 密码和验证码: the privileged side refuses such inputs unless told so.
                request.putBoolean(Proto.ALLOW_SECRET, PhoneRegistry.unlocks().secretFields)
            }
            is PhoneAction.Scroll -> {
                request.putString(Proto.OP, Proto.OP_SCROLL)
                request.putBoolean(Proto.LOCAL_VISUAL, true)
                request.putString(Proto.DIR, action.direction.name.lowercase())
                action.elementId?.let { id ->
                    request.putInt(Proto.ELEMENT, id)
                    fingerprint(id, request)
                }
            }
            is PhoneAction.Key -> {
                request.putString(Proto.OP, Proto.OP_KEY)
                request.putString(Proto.DIR, "back")
            }
            is PhoneAction.TapXY -> return performCoordinates(action, target, allowed, after)
        }
        // l10n:keep agent screen protocol
        val response = try {
            dispatch(allowed) { OwnerScopeProtocol.execute(channel(), ownerToken, request, it) }
        } catch (error: Exception) { clearSnapshot(); throw error }
            ?: return ActionResult(false, PhoneTasks.STOPPED_MESSAGE)
        return toResult(response, "已在后台屏执行", textAction = action is PhoneAction.Type, after = after)
    }

    /**
     * Input commits at its actual channel admission (client gate -> resource IO lock, as in [open]):
     * a pause, stop or seal while it waits for capacity sends nothing. Null means not allowed.
     */
    internal fun <T> dispatch(allowed: () -> Boolean, send: (beforeSend: () -> Unit) -> T): T? = try {
        resourceIo.call<T?> {
            if (!allowed()) return@call null
            send {
                if (!allowed()) throw NotAdmitted()
                resourceIo.checkDispatch()
            }
        }
    } catch (_: NotAdmitted) { null }

    private class NotAdmitted : RuntimeException()

    private fun performCoordinates(action: PhoneAction.TapXY, target: PhoneAppIdentity, allowed: () -> Boolean, after: AfterRead): ActionResult {
        // l10n:keep agent coordinate protocol
        if (!coordinateSupported) return ActionResult(false, "当前后台通道不支持截图坐标，请更新并重新连接；未执行，也不会转到主屏。")
        if (!allowed()) return ActionResult(false, PhoneTasks.STOPPED_MESSAGE)
        if (!coordinateEpochCurrent()) return ActionResult(false, Reasons.of("staleSnapshot"), staleSnapshot = true)
        val image = coordinateImage.take(action.screenId)
            // l10n:keep agent coordinate protocol
            ?: return ActionResult(false, "没有本任务最近一次已返回图片的后台坐标凭据。请显式 screen(image:true, background:true) 后核对；仍无凭据请用元素操作或交给用户，不要盲点。")
        val gesture = action.gesture.name.lowercase()
        val points = BackgroundCoordinateRequest(image.nonce, gesture, action.x, action.y, action.x2, action.y2, action.durationMs.toInt())
        // l10n:keep agent coordinate protocol
        if (!points.fits(image.width, image.height)) return ActionResult(false, "坐标超出原截图范围；未执行，请重新读屏。")
        val request = Bundle().apply {
            if (after.requested) putInt(Proto.AFTER_LOCAL_VISUAL, 1)
            putString(Proto.OP, Proto.OP_COORDINATE)
            putString(Proto.OWNER, ownerToken)
            putTarget(this, target)
            putInt(Proto.BACKGROUND_COORDINATES, 1)
            putString(Proto.COORDINATE_OBSERVATION, image.nonce)
            putString(Proto.GESTURE, gesture)
            putInt(Proto.X, action.x); putInt(Proto.Y, action.y)
            if (action.gesture == PhoneAction.CoordinateGesture.SWIPE) {
                putInt(Proto.X2, checkNotNull(action.x2)); putInt(Proto.Y2, checkNotNull(action.y2))
                putInt(Proto.DURATION_MS, action.durationMs.toInt())
            }
        }
        val response = try {
            dispatch({ allowed() && coordinateEpochCurrent() }) { OwnerScopeProtocol.execute(channel(), ownerToken, request, it) }
        } catch (_: Exception) {
            clearSnapshot()
            // The original lane never replays a request after a missing/throwing reply.
            return ActionResult(false, COORDINATE_UNKNOWN)
        } ?: return ActionResult(false, PhoneTasks.STOPPED_MESSAGE)
        val result = BackgroundCoordinateImage.Result.parse(image, target) { response.get(it) }
        if (result == null) { clearSnapshot(); return ActionResult(false, COORDINATE_UNKNOWN) }
        if (!result.ok) {
            clearSnapshot()
            // l10n:keep agent coordinate protocol
            val message = if (result.attempted) "后台坐标手势可能已经产生作用，但后续结果未确认。请重新读屏，不要直接重试。" else
                "后台坐标动作在注入前被拒绝；原观察不再可用，请重新读屏核对。"
            return ActionResult(false, message)
        }
        val snap = try {
            afterSnapshot(response, after)
        } catch (_: Exception) { clearSnapshot(); null } // The gesture acknowledgement already exists.
        if (snap == null) coordinateImage.invalidateScope()
        // l10n:keep agent coordinate protocol
        return ActionResult(true, "后台坐标手势已结束（不表示业务成功）" + backgroundVisualNote(result.change), snap)
    }

    override fun foregroundPackage(): String? = currentTarget?.packageName

    fun release(): Boolean {
        val acknowledged = try {
            resourceScope.cleanup { pinned ->
                val response = OwnerScopeProtocol.execute(pinned, ownerToken, Bundle().apply {
                    putString(Proto.OP, Proto.OP_RELEASE); putString(Proto.OWNER, ownerToken)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                })
                BackgroundReleaseReceipt.accepts(ownerToken, response.get(Proto.RELEASE_RECEIPT),
                    response.get(Proto.OWNER), response.get(Proto.OK), response.get("released"), response.get(Proto.TASK_SCOPE_EMPTY),
                    response.get("neverCreated"))
            }
        } catch (_: Exception) { false }
        coordinateImage.invalidateScope()
        if (!acknowledged) return false
        coordinateImage.clear()
        currentTarget = null
        targetReady = false
        lastScreenId = null
        lastElements = emptyList()
        previousLabels = emptySet()
        return true
    }

    private fun fingerprint(elementId: Int, request: Bundle) {
        val e = lastElements.getOrNull(elementId - 1) ?: return
        request.putString(Proto.EXPECT_ROLE, e.role)
        request.putString(Proto.EXPECT_LABEL, e.label)
        e.viewId?.let { request.putString(Proto.EXPECT_VIEW_ID, it) }
    }

    private fun putTarget(request: Bundle, target: PhoneAppIdentity) {
        request.putString(Proto.PKG, target.packageName)
        request.putInt(Proto.TARGET_IDENTITY_VERSION, 1)
        request.putInt(Proto.TARGET_UID, target.uid)
    }

    private fun requireIdentity(response: Bundle) {
        val expected = currentTarget
        if (expected == null || !TargetIdentity.receipt(expected, response.get(Proto.TARGET_IDENTITY_VERSION),
                response.get(Proto.PKG), response.get(Proto.TARGET_UID))) {
            clearSnapshot()
            targetReady = false
            throw IllegalStateException(Reasons.of("targetIdentityUnavailable"))
        }
    }

    private fun clearSnapshot() {
        coordinateOcrEpoch = null
        coordinateImage.invalidateScope()
        coordinateImage.clear()
        lastScreenId = null
        lastElements = emptyList()
        previousLabels = emptySet()
    }

    private data class AfterRead(val started: Long, val epoch: Long?, val target: PhoneAppIdentity, val requested: Boolean)

    /** Never combine the old action receipt with a partial new observation. */
    private fun afterSnapshot(response: Bundle, read: AfterRead): ScreenSnapshot? {
        // A completed action consumes the old observation even when its postread is absent.
        coordinateImage.clear()
        coordinateOcrEpoch = null
        val after = if (read.requested && BackgroundAfterVisual.supported(response.get(Proto.AFTER_LOCAL_VISUAL)))
            response.get(Proto.AFTER_VISUAL) as? Bundle else null
        val valid = after != null && after.get(Proto.OK) == true && currentTarget == read.target &&
            TargetIdentity.receipt(read.target, after.get(Proto.TARGET_IDENTITY_VERSION),
                after.get(Proto.PKG), after.get(Proto.TARGET_UID))
        if (valid) {
            val observed = checkNotNull(after)
            val local = readLocalText(observed, read.target, read.epoch, read.started)
            return ocrSnapshot(observed, true, false, local, read.epoch)
        }
        // Legacy text remains readable; missing/unknown attachment never grants new coordinates.
        val reason = if (localOcr?.enabled == false) LocalOcrResult.Reason.DISABLED
            else LocalOcrResult.Reason.PRIVACY_UNVERIFIED
        val diagnostic = LocalOcrVisual.Output(LocalOcrBoundary.message(LocalOcrResult.Unavailable(reason)), false, false)
        return if (response.containsKey(Proto.COUNT) || response.getBoolean(Proto.SECURE))
            snapshot(response, true, publishImage = false, localText = diagnostic, coordinatesAllowed = false) else null
    }

    private fun toResult(response: Bundle, okMessage: String, textAction: Boolean = false, after: AfterRead? = null): ActionResult {
        val ok = response.getBoolean(Proto.OK)
        val message = if (ok) okMessage + backgroundVisualNote(response.get(Proto.VISUAL_CHANGE)) else Reasons.of(
            response.getString(Proto.ERROR), response.getString(Proto.ERROR_DETAIL),
            // ACTION_SET_TEXT may have returned true before a later refresh/submit failed.
            // This acknowledgement is not text readback or business-success evidence.
            textAccepted = textAction && response.get(Proto.ACCEPTED) == true,
        )
        if (!ok && response.getString(Proto.ERROR) == "staleSnapshot") {
            // Invalidate before any optional snapshot decoding or subsequent refresh can fail.
            clearSnapshot()
            return ActionResult(false, message, staleSnapshot = true)
        }
        val identityMatches = currentTarget?.let {
            TargetIdentity.receipt(it, response.get(Proto.TARGET_IDENTITY_VERSION), response.get(Proto.PKG), response.get(Proto.TARGET_UID))
        } == true
        if (!identityMatches) {
            clearSnapshot()
            if (ok) {
                targetReady = false
                return ActionResult(false, Reasons.of("targetIdentityUnavailable", null,
                    textAccepted = textAction && response.get(Proto.ACCEPTED) == true))
            }
            if (response.getString(Proto.ERROR) in setOf("targetIdentityChanged", "targetIdentityUnavailable")) targetReady = false
            return ActionResult(false, message)
        }
        val snap = try {
            if (after != null) afterSnapshot(response, after)
            else if (response.containsKey(Proto.COUNT) || response.getBoolean(Proto.SECURE)) snapshot(response, markNew = true) else null
        } catch (_: Exception) { clearSnapshot(); null } // Optional postread cannot rewrite the action ACK.
        if (snap == null) coordinateImage.invalidateScope()
        return ActionResult(ok, message, snap)
    }

    private fun snapshot(response: Bundle, markNew: Boolean, publishImage: Boolean = true,
                         localText: LocalOcrVisual.Output? = null, coordinatesAllowed: Boolean = true): ScreenSnapshot {
        coordinateOcrEpoch = null
        coordinateImage.clear()
        val id = "b${++counter}"
        val target = currentTarget
        val knownScope = response.get(Proto.COORDINATE_SCOPE_VERSION) == 1 &&
            response.get(Proto.COORDINATE_SCOPE_VERSION) is Int && response.get(Proto.COORDINATE_SCOPE_KNOWN) == true &&
            response.get(Proto.OK) == true && target != null && TargetIdentity.receipt(target,
                response.get(Proto.TARGET_IDENTITY_VERSION), response.get(Proto.PKG), response.get(Proto.TARGET_UID))
        coordinateImage.publishScope(id, knownScope, ownerToken, target)
        val pkg = target?.packageName
        val appLabel = response.getString(Proto.APP_LABEL)
        if (response.getBoolean(Proto.SECURE)) {
            lastScreenId = id; lastElements = emptyList(); previousLabels = emptySet()
            // l10n:keep agent screen protocol
            val text = "屏幕 $id · 后台屏 · 受保护页面（支付或密码），已交还用户"
            return ScreenSnapshot(id, text, appLabel, pkg, secure = true)
        }
        if (response.getBoolean(Proto.FRAME_NOT_READY)) {
            lastScreenId = id; lastElements = emptyList(); previousLabels = emptySet()
            // l10n:keep agent screen protocol
            val text = "屏幕 $id · 后台屏\n" + Reasons.of("frameNotReady")
            return ScreenSnapshot(id, text, appLabel, pkg, secure = false, poorTree = true)
        }
        val elements = buildElements(response, markNew)
        lastElements = elements
        lastScreenId = id
        val poor = response.getBoolean(Proto.POOR)
        val portrait = response.getBoolean(Proto.PORTRAIT, true)
        val keyboardUp = response.getBoolean(Proto.KEYBOARD_UP, false)
        val detailed = response.containsKey(Proto.A_BOUNDS)
        var text = BackgroundTree.render(id, appLabel, portrait, keyboardUp, elements, background = true, poorTree = poor,
            overflow = if (detailed) response.getInt(Proto.ELEMENT_OVERFLOW, 0) else 0,
            detailed = detailed,
            treeComplete = if (response.containsKey(Proto.TREE_COMPLETE)) response.getBoolean(Proto.TREE_COMPLETE) else null)
        if (response.getBoolean(Proto.IMAGE_OMITTED)) {
            // l10n:keep agent screen protocol
            text += "\n（本页含敏感输入或控件树未完整读取，已省略截图；可继续使用已脱敏的文字信息）"
        }
        previousLabels = elements.map { it.label }.filter { it.isNotEmpty() }.toSet()
        val image = if (response.getBoolean(Proto.IMAGE_OMITTED)) null else response.getByteArray("imageBytes")
        val coordinate = if (coordinatesAllowed && image != null && coordinateSupported) BackgroundCoordinateImage.Receipt.parse(
            response.get(Proto.BACKGROUND_COORDINATES), response.get(Proto.COORDINATE_OBSERVATION),
            response.get(Proto.COORDINATE_WIDTH), response.get(Proto.COORDINATE_HEIGHT)) else null
        val eligible = if (coordinate == null) emptyMap() else BackgroundCoordinateImage.targets(
            response.get(Proto.COORDINATE_TARGETS_VERSION), response.get(Proto.COORDINATE_TARGET_INDICES),
            response.get(Proto.COORDINATE_TARGET_BOUNDS), elements.size, coordinate.width, coordinate.height)
        coordinateImage.candidate(id, coordinate, eligible)
        if (coordinate != null) {
            // l10n:keep agent coordinate protocol
            text += "\n截图坐标范围：${coordinate.width}×${coordinate.height}像素；30秒内可单次使用；只有明确普通目标可使用独立的本任务视觉许可，未知目标及长按/滑动仍逐次确认。未证明画布没有敏感内容或目标像素未变。"
        } else if (image != null && coordinateSupported) {
            // l10n:keep agent coordinate protocol
            text += "\n本次截图没有可用坐标凭据（窗口、隐私、几何或帧条件未满足）。请用元素操作或交给用户。"
        }
        if (localText != null) text += "\n" + localText.text
        val shownImage = image.takeIf { publishImage }
        return ScreenSnapshot(id, text, appLabel, pkg, secure = false, poorTree = poor,
            image = shownImage, imageMime = if (shownImage == null) null else response.getString("imageMime"))
    }

    private fun buildElements(response: Bundle, markNew: Boolean): List<Element> {
        val n = response.getInt(Proto.COUNT, 0)
        val role = response.getStringArray(Proto.A_ROLE) ?: return emptyList()
        val label = response.getStringArray(Proto.A_LABEL) ?: return emptyList()
        val viewIds = response.getStringArray(Proto.A_VIEW_ID)
        val states = response.getStringArray(Proto.A_STATES) ?: arrayOfNulls(n)
        val flags = response.getIntArray(Proto.A_FLAGS) ?: IntArray(n)
        val region = response.getIntArray(Proto.A_REGION) ?: IntArray(n)
        val indent = response.getIntArray(Proto.A_INDENT) ?: IntArray(n)
        val bounds = response.getIntArray(Proto.A_BOUNDS)?.takeIf { it.size == n * 4 }
        val out = ArrayList<Element>(n)
        for (i in 0 until n) {
            val lbl = label[i].orEmpty()
            val f = flags.getOrElse(i) { 0 }
            out.add(
                Element(
                    id = i + 1,
                    role = role[i].orEmpty(),
                    label = lbl,
                    region = regionOf(region.getOrElse(i) { 1 }),
                    indent = indent.getOrElse(i) { 0 },
                    states = states[i]?.split('\u0001')?.filter { it.isNotEmpty() } ?: emptyList(),
                    sensitive = f and Proto.FLAG_SENSITIVE != 0,
                    isNew = markNew && lbl.isNotEmpty() && lbl !in previousLabels,
                    isPassword = f and Proto.FLAG_PASSWORD != 0,
                    isSecretField = f and Proto.FLAG_SECRET != 0,
                    isEditable = f and Proto.FLAG_EDITABLE != 0,
                    viewId = viewIds?.getOrNull(i),
                    isScrollable = f and Proto.FLAG_SCROLLABLE != 0,
                    bounds = bounds?.let { ElementBounds(it[i * 4], it[i * 4 + 1], it[i * 4 + 2], it[i * 4 + 3]) },
                ),
            )
        }
        return out
    }

    private fun regionOf(code: Int): Region = when (code) {
        0 -> Region.TOP
        2 -> Region.BOTTOM
        else -> Region.MIDDLE
    }

    private fun idleSnapshot(): ScreenSnapshot {
        coordinateImage.invalidateScope()
        coordinateImage.clear()
        val id = "b${++counter}"
        lastScreenId = id; lastElements = emptyList()
        // l10n:keep agent screen protocol
        return ScreenSnapshot(id, "屏幕 $id · 后台屏 · 空闲，用 open 打开应用", null, null)
    }
    companion object {
        // l10n:keep agent coordinate protocol
        private const val COORDINATE_UNKNOWN = "后台坐标请求未获得可信回执，可能已产生作用。请重新读屏，不要直接重试。"
    }
}
