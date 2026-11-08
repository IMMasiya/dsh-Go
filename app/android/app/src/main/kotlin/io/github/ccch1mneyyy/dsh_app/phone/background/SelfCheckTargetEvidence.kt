package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.TargetContract

/** Per real tree walk. Raw node text is compared immediately, never retained or returned. */
internal class SelfCheckTargetEvidence(run: String, counter: Int) {
    private val markerId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.MARKER_ID)
    private val counterId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.COUNTER_ID)
    val buttonId = TargetContract.viewId(Proto.APP_PACKAGE, TargetContract.BUTTON_ID)
    private val marker = TargetContract.marker(run)
    private val counter = TargetContract.counter(counter)
    private var markers = 0
    private var counters = 0
    private var buttons = 0
    private var markerMatches = false
    private var counterMatches = false
    private var buttonUsable = false

    fun observe(id: String?, visible: Boolean, text: CharSequence?, description: CharSequence?, enabled: Boolean, clickable: Boolean) {
        when (id) {
            markerId -> { markers++; markerMatches = visible && exact(description, marker) }
            counterId -> { counters++; counterMatches = visible && exact(text, counter) }
            buttonId -> { buttons++; buttonUsable = visible && enabled && clickable }
        }
    }

    val targetMatched: Boolean get() = markers == 1 && markerMatches && counters == 1 && buttons == 1 && buttonUsable
    val counterMatched: Boolean get() = counters == 1 && counterMatches

    private fun exact(value: CharSequence?, expected: String): Boolean =
        value != null && value.length == expected.length && value.toString() == expected
}
