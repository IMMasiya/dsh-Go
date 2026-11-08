package io.github.ccch1mneyyy.dsh_app.phone

/** The actual local report: fixed values only, no owner, input, tree, image or exception text. */
internal class PhoneSelfCheckReport(val profile: Profile = Profile.PROBE_B) {
    enum class Profile(val wire: String) {
        PROBE_B("probe_b"), TARGET_C1("target_c1");

        companion object {
            fun parse(value: Any?): Profile? = entries.firstOrNull { it.wire == value }
        }
    }
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
        TARGET_UNAVAILABLE("targetUnavailable"), TARGET_CHANGED("targetChanged"),
        TARGET_CLEANUP_PENDING("targetCleanupPending"), TARGET_WRONG_MAIN("targetWrongMain"),
        TARGET_READBACK_MISMATCH("targetReadbackMismatch"), TREE_CLEANUP_PENDING("treeCleanupPending"),
        TARGET_LAUNCH_DENIED("targetLaunchDenied"),
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
        val covered = when (profile) {
            Profile.PROBE_B -> stage in setOf(Stage.DEVICE, Stage.CHANNEL, Stage.DISPLAY, Stage.INPUT_PROBE, Stage.CLEANUP)
            Profile.TARGET_C1 -> stage in setOf(Stage.DEVICE, Stage.CHANNEL, Stage.DISPLAY,
                Stage.LAUNCH, Stage.TREE, Stage.TAP, Stage.CLEANUP)
        }
        // C1 can observe an actual wrong-MAIN target; it has no evidence of MAIN success.
        if (!covered && !(profile == Profile.TARGET_C1 && stage == Stage.MAIN &&
                state == State.FAIL && observed && reason == Reason.TARGET_WRONG_MAIN)) return
        steps[stage] = Step(state, observed, reason, durationMs?.coerceIn(0, Int.MAX_VALUE.toLong()))
    }

    /** Exact echoes are checked before any fixed-target reply becomes a local fact. */
    private fun targetReply(
        expectedOwner: String, expectedRun: String, expectedNonce: String,
        owner: Any?, run: Any?, nonce: Any?, version: Any?, ok: Any?, error: Any?,
    ): Boolean = profile == Profile.TARGET_C1 && owner is String && owner == expectedOwner &&
        run is String && run == expectedRun && nonce is String && nonce == expectedNonce &&
        version is Int && version == 1 && ok is Boolean &&
        !(ok && error != null)

    /** A returned ID is permission for the coordinator's fixed local launch, never a caller's ID. */
    fun acceptTargetCreate(
        expectedOwner: String, expectedRun: String, expectedNonce: String,
        owner: Any?, run: Any?, nonce: Any?, version: Any?, ok: Any?, error: Any?,
        displayReady: Any?, displayId: Any?, durationMs: Long,
    ): Int? {
        if (!targetReply(expectedOwner, expectedRun, expectedNonce, owner, run, nonce, version, ok, error) ||
            displayReady !is Boolean || displayReady && (displayId !is Int || displayId <= 0) ||
            !displayReady && displayId != null || ok != displayReady) {
            update(Stage.DISPLAY, State.UNKNOWN, false, Reason.INVALID_RESPONSE, durationMs)
            return null
        }
        update(Stage.DISPLAY, if (displayReady) State.PASS else State.FAIL, true,
            if (displayReady) null else Reason.fromWire(error), durationMs)
        return if (ok == true) displayId as Int else null
    }

    /** Lifecycle callbacks do not enter here: all three values come from the real target read. */
    fun acceptTargetRead(
        expectedOwner: String, expectedRun: String, expectedNonce: String,
        owner: Any?, run: Any?, nonce: Any?, version: Any?, ok: Any?, error: Any?,
        matched: Any?, complete: Any?, initialCounter: Any?, durationMs: Long,
    ): Boolean {
        if (!targetReply(expectedOwner, expectedRun, expectedNonce, owner, run, nonce, version, ok, error) ||
            matched !is Boolean || complete !is Boolean || initialCounter !is Boolean ||
            ok != (matched && complete && initialCounter)) {
            unknownTargetRead(Reason.INVALID_RESPONSE, durationMs)
            return false
        }
        if (matched && complete && initialCounter) {
            update(Stage.LAUNCH, State.PASS, true, durationMs = durationMs)
            update(Stage.TREE, State.PASS, true, durationMs = durationMs)
        } else unknownTargetRead(Reason.fromWire(error), durationMs)
        return ok == true
    }

    fun unknownTargetRead(reason: Reason, durationMs: Long) {
        update(Stage.LAUNCH, State.UNKNOWN, false, reason, durationMs)
        update(Stage.TREE, State.UNKNOWN, false, reason, durationMs)
    }

    /** attempted is independent of a post-read verdict: unknown after send never means no input. */
    fun acceptTargetTap(
        expectedOwner: String, expectedRun: String, expectedNonce: String,
        owner: Any?, run: Any?, nonce: Any?, version: Any?, ok: Any?, error: Any?,
        attempted: Any?, matched: Any?, complete: Any?, counter: Any?, durationMs: Long,
    ): Boolean {
        if (!targetReply(expectedOwner, expectedRun, expectedNonce, owner, run, nonce, version, ok, error) ||
            attempted !is Boolean || matched != null && matched !is Boolean ||
            complete != null && complete !is Boolean || counter != null && counter !is Boolean ||
            !attempted && (matched != null || complete != null || counter != null) ||
            (matched == null) != (complete == null) || counter != null && complete != true ||
            ok != (attempted && matched == true && complete == true && counter == true)) {
            update(Stage.TAP, State.UNKNOWN, false, Reason.INVALID_RESPONSE, durationMs)
            return false
        }
        if (attempted && matched == true && complete == true && counter == true) {
            update(Stage.TAP, State.PASS, true, durationMs = durationMs)
        } else {
            val reason = Reason.fromWire(error)
            update(Stage.TAP, if (!attempted || matched == true && complete == true && counter == false)
                State.FAIL else State.UNKNOWN, attempted, reason, durationMs)
        }
        return ok == true
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
