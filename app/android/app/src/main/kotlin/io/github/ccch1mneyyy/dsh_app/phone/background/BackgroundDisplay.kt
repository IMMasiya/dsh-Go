package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Build
import android.os.Bundle
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

/**
 * BACKGROUND [PhoneDriver] (screen ids `b<n>`): reads and drives the trusted virtual display
 * through whichever privileged channel is live (Shizuku or self-ADB). Registered in
 * [io.github.ccch1mneyyy.dsh_app.phone.PhoneRegistry].backgroundDriver only while a task uses it.
 * All calls are serialised by the bridge; this class never retries a dispatched action.
 */
class BackgroundDisplay(
    private val channelProvider: () -> PrivilegedChannel?,
    private val viewport: BackgroundPolicy.Viewport = BackgroundPolicy.Viewport.PORTRAIT,
    private val onResourceReady: (PrivilegedChannel) -> Unit = {},
) : PhoneDriver {

    private val resourceIo = BackgroundDisplayIo<PrivilegedChannel>()
    internal val ownerToken: String get() = resourceIo.owner
    internal fun seal() = resourceIo.seal()
    internal fun previewAvailable(peer: PrivilegedChannel): Boolean = resourceIo.previewAvailable(peer)
    internal fun previewClosed(): Boolean = resourceIo.previewClosed()
    internal fun tryPreview(request: Bundle): Bundle? = resourceIo.tryPreview { it.tryExecute(request) }

    override val screen: PhoneScreen = PhoneScreen.BACKGROUND

    @Volatile private var currentTarget: PhoneAppIdentity? = null
    private var targetReady = false
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
            currentTarget = target // Retain the attempted identity, never old elements after unknown launch.
            val active = channel()
            if (resourceIo.peer() == null) {
                val probe = active.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                check(probe.get(Proto.OK) == true && probe.get(Proto.RELEASE_RECEIPT) is Int && probe.getInt(Proto.RELEASE_RECEIPT) == 1) {
                    "所选后台服务不支持安全收尾，请更新并重新连接该通道。" // l10n:keep agent resource result
                }
                check(TargetIdentity.supported(probe.get(Proto.TARGET_IDENTITY_VERSION))) {
                    Reasons.of("targetIdentityUnsupported")
                }
                check(BackgroundPolicy.supportsViewport(viewport, probe.get(Proto.VIEWPORT_VERSION))) {
                    Reasons.of("viewportUnsupported")
                }
                // A stop during probe seals this short admission check before CREATE can be sent.
                resourceIo.pin(active)
            }
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
            val response = active.execute(request)
            // Publish only after the first resource request has actually returned on its pinned peer.
            onResourceReady(active)
            val result = toResult(response, "已在后台屏打开") // l10n:keep agent screen protocol
            targetReady = result.ok
            result
        }
    } catch (error: Throwable) {
        clearSnapshot()
        targetReady = false
        if (resourceIo.peer() == null) resourceIo.seal() // Failed preflight must not leave an idle I/O worker.
        throw error
    }

    override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
        val target = currentTarget ?: return idleSnapshot()
        check(targetReady) { Reasons.of("targetIdentityUnavailable") }
        val request = Bundle().apply {
            putString(Proto.OP, Proto.OP_OBSERVE)
            putString(Proto.OWNER, ownerToken)
            putTarget(this, target)
            putBoolean(Proto.DETAIL, detail)
            putBoolean(Proto.WANT_IMAGE, image)
            putBoolean(Proto.LOCAL_VISUAL, true)
        }
        val response = try {
            resourceIo.call { channel().execute(request) }
        } catch (e: Exception) {
            clearSnapshot()
            throw e
        }
        requireObservation(response.getBoolean(Proto.OK), response.getString(Proto.ERROR), response.getString(Proto.ERROR_DETAIL))
        requireIdentity(response)
        return snapshot(response, markNew = false)
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
            val snap = observe(detail = false, image = false)
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
        val request = Bundle().apply {
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
            // l10n:keep agent screen protocol
            is PhoneAction.TapXY -> return ActionResult(false, "后台屏按元素编号操作，不用坐标")
        }
        // l10n:keep agent screen protocol
        val response = try {
            resourceIo.call {
                if (!allowed()) return@call null
                channel().execute(request)
            }
        } catch (error: Exception) { clearSnapshot(); throw error }
            ?: return ActionResult(false, PhoneTasks.STOPPED_MESSAGE)
        return toResult(response, "已在后台屏执行", textAction = action is PhoneAction.Type)
    }

    override fun foregroundPackage(): String? = currentTarget?.packageName

    fun release(): Boolean {
        val acknowledged = try {
            resourceIo.release { pinned ->
                val response = pinned.execute(Bundle().apply {
                    putString(Proto.OP, Proto.OP_RELEASE); putString(Proto.OWNER, ownerToken)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                })
                BackgroundReleaseReceipt.accepts(ownerToken, response.get(Proto.RELEASE_RECEIPT),
                    response.get(Proto.OWNER), response.get(Proto.OK), response.get("released"), response.get(Proto.TASK_SCOPE_EMPTY),
                    response.get("neverCreated"))
            }
        } catch (_: Exception) { false }
        if (!acknowledged) return false
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
        lastScreenId = null
        lastElements = emptyList()
        previousLabels = emptySet()
    }

    private fun toResult(response: Bundle, okMessage: String, textAction: Boolean = false): ActionResult {
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
        val snap = if (response.containsKey(Proto.COUNT) || response.getBoolean(Proto.SECURE))
            snapshot(response, markNew = true) else null
        return ActionResult(ok, message, snap)
    }

    private fun snapshot(response: Bundle, markNew: Boolean): ScreenSnapshot {
        val id = "b${++counter}"
        val pkg = currentTarget?.packageName
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
        return ScreenSnapshot(id, text, appLabel, pkg, secure = false, poorTree = poor,
            image = image, imageMime = if (image == null) null else response.getString("imageMime"))
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
        val id = "b${++counter}"
        lastScreenId = id; lastElements = emptyList()
        // l10n:keep agent screen protocol
        return ScreenSnapshot(id, "屏幕 $id · 后台屏 · 空闲，用 open 打开应用", null, null)
    }
}
