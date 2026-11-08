package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.TargetContract

/** Only the three fixed C1 operations. No app, text, coordinate, or display parameter. */
internal data class SelfCheckTargetRequest(val step: Step, val owner: String, val run: String, val nonce: String) {
    enum class Step(val op: String) {
        CREATE(Proto.OP_SELF_CHECK_TARGET_CREATE), READ(Proto.OP_SELF_CHECK_TARGET_READ), TAP(Proto.OP_SELF_CHECK_TARGET_TAP),
    }

    companion object {
        fun parse(keys: Set<String>, value: (String) -> Any?): SelfCheckTargetRequest? {
            val op = value(Proto.OP)
            val step = Step.entries.firstOrNull { it.op == op } ?: return null
            val expected = setOf(Proto.OP, Proto.OWNER, Proto.SELF_CHECK_TARGET_VERSION, Proto.TARGET_RUN, Proto.STEP_NONCE) +
                if (step == Step.CREATE) setOf(Proto.RELEASE_RECEIPT) else emptySet()
            if (keys != expected || value(Proto.SELF_CHECK_TARGET_VERSION) !is Int || value(Proto.SELF_CHECK_TARGET_VERSION) != 1) return null
            if (step == Step.CREATE && (value(Proto.RELEASE_RECEIPT) !is Int || value(Proto.RELEASE_RECEIPT) != 1)) return null
            val owner = value(Proto.OWNER) as? String ?: return null
            val run = value(Proto.TARGET_RUN) as? String ?: return null
            val nonce = value(Proto.STEP_NONCE) as? String ?: return null
            if (!TargetContract.validRun(owner) || !TargetContract.validRun(run) || !TargetContract.validRun(nonce)) return null
            return SelfCheckTargetRequest(step, owner, run, nonce)
        }
    }
}

/** Core's lock serializes admission and completion; a failed admitted step is never replayed. */
internal class SelfCheckTargetSequence(val owner: String, val run: String) {
    private val nonces = ArrayList<String>(3)
    private var completed = 0

    fun enter(request: SelfCheckTargetRequest): String? {
        if (request.owner != owner || request.run != run) return "identityChanged"
        if (request.nonce in nonces || request.step.ordinal < nonces.size) return "alreadyAttempted"
        if (request.step.ordinal != nonces.size || completed != nonces.size) return "outOfOrder"
        nonces.add(request.nonce) // Consume before allocation, tree connection, or input.
        return null
    }

    fun complete(step: SelfCheckTargetRequest.Step) {
        check(step.ordinal == completed && nonces.size == completed + 1)
        completed++
    }
}
