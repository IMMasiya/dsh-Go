package io.github.ccch1mneyyy.dsh_app.phone

/** Only ids actually returned to this task lifetime may be used by its model. No image is retained. */
class PhoneTaskObservations(private val tasks: PhoneTasks) {
    private data class Seen(val driver: PhoneDriver, val id: String, val owner: PhoneTasks.Owner)
    private val seen = mutableMapOf<PhoneScreen, Seen>()

    fun bind(driver: PhoneDriver, owner: PhoneTasks.Owner): PhoneDriver = object : PhoneDriver by driver {
        private fun current() {
            if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted) throw InterruptedException()
        }
        private fun allowed(): Boolean {
            var accepted = false
            tasks.runIfCurrent(owner) { accepted = !tasks.isPaused }
            return accepted
        }
        private fun owns(id: String): Boolean {
            var matched = false
            tasks.runIfCurrent(owner) {
                synchronized(seen) {
                    val value = seen[driver.screen]
                    matched = value != null && value.driver === driver && value.id == id &&
                        value.owner.taskId == owner.taskId && value.owner.lifecycle == owner.lifecycle
                }
            }
            return matched
        }
        private fun remember(snapshot: ScreenSnapshot): ScreenSnapshot {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            // Same order as reads: Tasks -> observation ledger, with owner check and write together.
            if (!tasks.runIfCurrent(owner) {
                synchronized(seen) { seen[driver.screen] = Seen(driver, snapshot.id, owner) }
            }) throw InterruptedException()
            return snapshot
        }
        private fun result(result: ActionResult): ActionResult {
            current()
            result.screen?.let(::remember)
            return result
        }
        override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
            current()
            return remember(driver.observe(detail, image))
        }
        override fun target(screenId: String, elementId: Int): TargetInfo? {
            current()
            return if (owns(screenId)) driver.target(screenId, elementId) else null
        }
        override fun perform(action: PhoneAction): ActionResult {
            current()
            if (action !is PhoneAction.Key && !owns(action.screenId)) {
                // l10n:keep agent observation ownership result
                return ActionResult(false, "这个屏幕编号不属于本任务的当前观察。请本任务重新 screen，不要使用另一对话的编号。")
            }
            return result(driver.perform(action, ::allowed))
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult {
            current()
            if (!owns(screenId)) return CollectResult(emptyList(), 0, "屏幕编号不属于本任务，请重新 screen", null) // l10n:keep agent observation ownership result
            val result = driver.collect(screenId, listElementId, maxPages, until, ::allowed)
            current()
            result.screen?.let(::remember)
            return result
        }
        override fun open(target: PhoneAppIdentity): ActionResult { current(); return result(driver.open(target)) }
        override fun foregroundPackage(): String? { current(); return driver.foregroundPackage() }
    }
}
