package io.github.ccch1mneyyy.dsh_app.phone

/** The actual local report: fixed values only, no owner, input, tree, image or exception text. */
internal class PhoneSelfCheckReport {
    enum class Stage(val wire: String) {
        DEVICE("device"), CHANNEL("channel"), DISPLAY("display"), INPUT_PROBE("input_probe"),
        LAUNCH("launch"), TREE("tree"), TAP("tap"), SCROLL("scroll"), BACK("back"),
        TEXT_ASCII("text_ascii"), TEXT_ZH("text_zh"), CAPTURE("capture"),
        CONTINUITY("continuity"), MAIN("main"), OCR("ocr"), CLEANUP("cleanup"),
    }
    enum class State(val wire: String) {
        NOT_RUN("not_run"), RUNNING("running"), PASS("pass"), FAIL("fail"),
        SKIPPED("skipped"), UNKNOWN("unknown"), CANCELLED("cancelled"),
    }
    enum class Reason(val wire: String) {
        BUSY("busy"), UNAVAILABLE("unavailable"), UNSUPPORTED("unsupported"),
        CANCELLED("cancelled"), RETIRED("retired"), PHONE_DISABLED("phoneDisabled"), LOCKED("locked"),
        CHANNEL_UNAVAILABLE("channelUnavailable"), UNSUPPORTED_PEER("unsupportedPeer"),
        INVALID_RESPONSE("invalidResponse"), CLEANUP_FAILED("cleanupFailed"),
        INVALID_ARGUMENTS("invalidArguments"), IDENTITY_CHANGED("identityChanged"),
        ALREADY_STARTED("selfCheckAlreadyStarted"), DISPLAY_UNSUPPORTED("displayUnsupported"),
        DISPLAY_MISSING("displayMissing"), RELEASE_PENDING("releasePending"),
        RELEASE_UNCONFIRMED("releaseUnconfirmed"), RELEASE_FAILED("releaseFailed"),
        RELEASE_QUERY_FAILED("releaseQueryFailed"), RELEASE_REQUIRED("releaseReceiptRequired"),
        WINDOW_NOT_READY("inputWindowNotReady"), INPUT_UNCONFIRMED("inputUnconfirmed"),
        INPUT_REJECTED("inputRejected"), INPUT_API_UNAVAILABLE("inputApiUnavailable"),
        PROBE_CLEANUP_FAILED("inputProbeCleanupFailed"), DENIED("systemOperationDenied"),
        DEVICE_UNAVAILABLE("deviceUnavailable"), TIMEOUT("timeout"), OTHER("other");

        companion object {
            fun fromWire(value: Any?): Reason = entries.firstOrNull { it.wire == value } ?: OTHER
        }
    }
    private data class Step(
        val state: State = State.NOT_RUN,
        val observed: Boolean = false,
        val reason: Reason? = null,
        val durationMs: Long? = null,
    )
    // The coordinator's short lock owns this model, including serialization.
    private val steps = Stage.entries.associateWith { Step() }.toMutableMap()

    fun update(stage: Stage, state: State, observed: Boolean, reason: Reason? = null, durationMs: Long? = null) {
        steps[stage] = Step(state, observed, reason, durationMs?.coerceIn(0, Int.MAX_VALUE.toLong()))
    }

    /** Validate the actual fixed begin reply before accepting any display or delivery PASS. */
    fun acceptProbe(
        expectedOwner: String, owner: Any?, version: Any?, ok: Any?, displayReady: Any?,
        injectOk: Any?, error: Any?, injectError: Any?, durationMs: Long,
    ): Boolean {
        if (owner !is String || owner != expectedOwner || version !is Int || version != 1 || ok !is Boolean ||
            displayReady !is Boolean || injectOk != null && injectOk !is Boolean ||
            ok != (displayReady && injectOk == true) || !displayReady && injectOk != null ||
            ok && (error != null || injectError != null)) {
            unknownProbe(Reason.INVALID_RESPONSE, durationMs)
            return false
        }
        update(Stage.DISPLAY, if (displayReady) State.PASS else State.FAIL, true,
            if (displayReady) null else Reason.fromWire(error), durationMs)
        when (injectOk) {
            true -> update(Stage.INPUT_PROBE, State.PASS, true, durationMs = durationMs)
            false -> update(Stage.INPUT_PROBE, State.UNKNOWN, true,
                Reason.fromWire(injectError ?: error), durationMs)
            else -> if (injectError != null) update(Stage.INPUT_PROBE, State.FAIL, true,
                Reason.fromWire(injectError), durationMs)
            else update(Stage.INPUT_PROBE, State.NOT_RUN, false, Reason.fromWire(error))
        }
        return true
    }

    fun unknownProbe(reason: Reason, durationMs: Long) {
        update(Stage.DISPLAY, State.UNKNOWN, false, reason, durationMs)
        update(Stage.INPUT_PROBE, State.UNKNOWN, false, reason, durationMs)
    }

    fun finishPending(cancelled: Boolean) {
        for ((stage, step) in steps.toMap()) {
            if (step.state == State.RUNNING) update(stage,
                if (cancelled) State.CANCELLED else State.UNKNOWN, false,
                if (cancelled) Reason.CANCELLED else Reason.DEVICE_UNAVAILABLE)
        }
    }

    fun toMaps(): List<Map<String, Any?>> = Stage.entries.map { stage ->
        val step = checkNotNull(steps[stage])
        linkedMapOf<String, Any?>(
            "stage" to stage.wire, "state" to step.state.wire, "observed" to step.observed,
        ).apply {
            step.reason?.let { put("reason", it.wire) }
            step.durationMs?.let { put("durationMs", it) }
        }
    }
}
