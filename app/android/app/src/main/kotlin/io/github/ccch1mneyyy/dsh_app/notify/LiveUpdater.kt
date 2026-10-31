package io.github.ccch1mneyyy.dsh_app.notify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R

/**
 * Live update (Android 16 实时更新) 的一次回合进度条。
 *
 * Flutter 在回合开始 / 进度变化 / 回合结束时调用 [start] / [update] / [stop]
 * （MethodChannel `dsh/notify` 的 liveStart / liveUpdate / liveStop）。
 *
 * 提升（promotion）只在 API 36+ 且用户在系统设置里开着该 App 的实时更新时生效；
 * 不满足条件时同一份通知退化为普通常驻通知，只在通知栏可见。系统还要求 App 有
 * 前台服务在跑（本 App 是 .runtime.DshService），否则同样不提升。
 *
 * 这里用反射调用 API 36 的接口，好处是同一份代码在更低 targetSdk 上也能编过：
 * 方法不存在时静默跳过，行为等于「不提升」。
 */
class LiveUpdater(private val app: Context) {

    private val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private var sessionId: String? = null
    private var startedAt = 0L
    private var percent: Int? = null
    private var title: String = ""
    private var text: String = ""

    /** 回合开始：起一条常驻的实时更新。 */
    fun start(sessionId: String, title: String, text: String) {
        ensureChannel()
        this.sessionId = sessionId
        this.title = title
        this.text = text
        this.percent = null
        this.startedAt = System.currentTimeMillis()
        post()
    }

    /** 进度或文案变化；同一 session 才更新，别的会话不抢岛。 */
    fun update(sessionId: String?, percent: Int?, text: String?) {
        if (this.sessionId == null) return
        if (sessionId != null && sessionId != this.sessionId) return
        var changed = false
        if (percent != null) {
            val next = percent.coerceIn(0, 100)
            if (next != this.percent) {
                this.percent = next
                changed = true
            }
        }
        if (!text.isNullOrEmpty() && text != this.text) {
            this.text = text
            changed = true
        }
        // 文案变了也要重发：只动进度条不动状态行，看不出回合在干什么。
        if (changed) post()
    }

    /** 回合结束：立刻撤回，不在岛上留失败态。 */
    fun stop() {
        nm.cancel(TAG, ID)
        sessionId = null
        percent = null
    }

    /** 当前能否被系统提升成实时更新（API 36+ 且用户没关这个开关）。 */
    fun canPromote(): Boolean {
        if (Build.VERSION.SDK_INT < 36) return false
        return try {
            val m = nm.javaClass.getMethod("canPostPromotedNotifications")
            m.invoke(nm) as? Boolean ?: false
        } catch (_: Throwable) {
            false
        }
    }

    private fun post() {
        val n = build()
        try {
            nm.notify(TAG, ID, n)
        } catch (_: Throwable) {
            // 权限被拒 / 渠道被关：什么都不发，不影响会话本身。
        }
    }

    private fun build(): Notification {
        val b = Notification.Builder(app, CHANNEL_LIVE)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(title.ifEmpty { DEFAULT_TITLE })
            .setContentText(text)
            .setContentIntent(openIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setWhen(startedAt)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)

        val p = percent
        if (p != null) {
            b.setProgress(100, p, false)
            requestPromoted(b)
            shortText(b, text)
        } else {
            b.setProgress(0, 0, true)
        }
        return b.build()
    }

    /** API 36：申请被提升成实时更新。方法不存在就算了。 */
    private fun requestPromoted(b: Notification.Builder) {
        if (Build.VERSION.SDK_INT < 36) return
        try {
            Notification.Builder::class.java
                .getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType)
                .invoke(b, true)
        } catch (_: Throwable) {
        }
    }

    /** API 36：状态栏胶囊上的短文案，超长会被系统截断。 */
    private fun shortText(b: Notification.Builder, value: String) {
        if (Build.VERSION.SDK_INT < 36 || value.isEmpty()) return
        try {
            Notification.Builder::class.java
                .getMethod("setShortCriticalText", CharSequence::class.java)
                .invoke(b, value.take(16))
        } catch (_: Throwable) {
        }
    }

    private fun openIntent(): PendingIntent {
        val intent = Intent(app, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            sessionId?.let { putExtra(EXTRA_SESSION, it) }
        }
        return PendingIntent.getActivity(
            app,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun ensureChannel() {
        if (nm.getNotificationChannel(CHANNEL_LIVE) != null) return
        val channel = NotificationChannel(
            CHANNEL_LIVE,
            "任务进度",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "回合进行中的进度，可在系统设置里关掉实时更新"
            setShowBadge(false)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
    }

    private companion object {
        const val TAG = "dsh-live"
        const val ID = 0x44534801
        const val CHANNEL_LIVE = "dsh-live-progress"
        const val EXTRA_SESSION = "dsh.notify.session"
        const val DEFAULT_TITLE = "DSH 干活中"
    }
}
