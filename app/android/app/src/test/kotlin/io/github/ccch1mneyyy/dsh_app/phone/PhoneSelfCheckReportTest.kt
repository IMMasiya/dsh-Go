package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Reason
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Stage
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.State
import org.junit.Assert.*
import org.junit.Test

/** The production report consumes these exact fields from the real Bundle reply. No Android stubs. */
class PhoneSelfCheckReportTest {
    private fun row(report: PhoneSelfCheckReport, stage: Stage) =
        report.toMaps().single { it["stage"] == stage.wire }

    @Test fun newReportNeverInventsActivityTextOcrOrMainResults() {
        val report = PhoneSelfCheckReport()
        assertEquals(16, report.toMaps().size)
        for (step in report.toMaps()) {
            assertEquals("not_run", step["state"])
            assertEquals(false, step["observed"])
        }
    }

    @Test fun actualDeliveryRemainsPassedWhenCleanupIsUnconfirmed() {
        val report = PhoneSelfCheckReport()
        assertTrue(report.acceptProbe("resource", "resource", 1, true, true, true, null, null, 42))
        report.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.CLEANUP_FAILED)
        report.finishPending(cancelled = true)
        assertEquals("pass", row(report, Stage.INPUT_PROBE)["state"])
        assertEquals(true, row(report, Stage.INPUT_PROBE)["observed"])
        assertEquals("unknown", row(report, Stage.CLEANUP)["state"])
        for (stage in listOf(Stage.LAUNCH, Stage.TREE, Stage.TEXT_ASCII, Stage.TEXT_ZH,
                Stage.CAPTURE, Stage.CONTINUITY, Stage.MAIN, Stage.OCR)) {
            assertEquals("not_run", row(report, stage)["state"])
        }
    }

    @Test fun successWithAnErrorIsContradictoryAndNeverGreen() {
        for ((error, injectionError) in listOf(
                "private contact and message" to null, null to "inputUnconfirmed", "" to null)) {
            val report = PhoneSelfCheckReport()
            assertFalse(report.acceptProbe("resource", "resource", 1, true, true, true,
                error, injectionError, 10))
            for (stage in listOf(Stage.DISPLAY, Stage.INPUT_PROBE)) {
                assertEquals("unknown", row(report, stage)["state"])
                assertEquals("invalidResponse", row(report, stage)["reason"])
            }
            assertFalse(report.toMaps().toString().contains("private contact"))
        }
    }

    @Test fun replyIdentityVersionTypesAndTruthTableMustAllMatch() {
        val invalid = listOf(
            listOf("other", 1, true, true, true),
            listOf(42, 1, true, true, true),
            listOf("resource", 1L, true, true, true),
            listOf("resource", 1, "true", true, true),
            listOf("resource", 1, true, 1, true),
            listOf("resource", 1, true, true, "true"),
            listOf("resource", 1, true, true, false),
            listOf("resource", 1, false, true, true),
            listOf("resource", 1, false, false, false),
        )
        for (fields in invalid) {
            val report = PhoneSelfCheckReport()
            assertFalse(report.acceptProbe("resource", fields[0], fields[1], fields[2],
                fields[3], fields[4], null, null, 0))
            assertTrue(report.toMaps().none { it["state"] == "pass" })
        }
    }

    @Test fun attemptedInputWithoutReceiptMeansUnknownNotNoInput() {
        val report = PhoneSelfCheckReport()
        assertTrue(report.acceptProbe("resource", "resource", 1, false, true, false,
            "inputUnconfirmed", "inputUnconfirmed", 55))
        assertEquals("pass", row(report, Stage.DISPLAY)["state"])
        assertEquals("unknown", row(report, Stage.INPUT_PROBE)["state"])
        assertEquals(true, row(report, Stage.INPUT_PROBE)["observed"])
        assertEquals("inputUnconfirmed", row(report, Stage.INPUT_PROBE)["reason"])
    }

    @Test fun windowPreparationFailureDoesNotClaimInputWasSent() {
        val report = PhoneSelfCheckReport()
        assertTrue(report.acceptProbe("resource", "resource", 1, false, true, null,
            "inputWindowNotReady", "inputWindowNotReady", 50))
        assertEquals("fail", row(report, Stage.INPUT_PROBE)["state"])
        assertEquals("inputWindowNotReady", row(report, Stage.INPUT_PROBE)["reason"])
        val beforeWindow = PhoneSelfCheckReport()
        beforeWindow.update(Stage.INPUT_PROBE, State.RUNNING, false)
        assertTrue(beforeWindow.acceptProbe("resource", "resource", 1, false, false, null,
            "locked", null, 2))
        assertEquals("not_run", row(beforeWindow, Stage.INPUT_PROBE)["state"])
        assertEquals(false, row(beforeWindow, Stage.INPUT_PROBE)["observed"])
    }

    @Test fun cancelledPendingStepsCannotRemainRunningInAFinalReport() {
        val report = PhoneSelfCheckReport()
        report.update(Stage.CHANNEL, State.PASS, true)
        report.update(Stage.DISPLAY, State.RUNNING, false)
        report.update(Stage.INPUT_PROBE, State.RUNNING, false)
        report.finishPending(cancelled = true)
        assertEquals("pass", row(report, Stage.CHANNEL)["state"])
        assertEquals("cancelled", row(report, Stage.DISPLAY)["state"])
        assertEquals("cancelled", row(report, Stage.INPUT_PROBE)["state"])
    }

    @Test fun unknownFaultsAndUnboundedDurationAreNotExported() {
        val report = PhoneSelfCheckReport()
        val raw = "phone=13800000000 secret-message"
        assertTrue(report.acceptProbe("resource", "resource", 1, false, false, null,
            raw, null, Long.MAX_VALUE))
        assertEquals("other", row(report, Stage.DISPLAY)["reason"])
        assertEquals(Int.MAX_VALUE.toLong(), row(report, Stage.DISPLAY)["durationMs"])
        report.update(Stage.CLEANUP, State.UNKNOWN, false, Reason.CLEANUP_FAILED, -1)
        assertEquals(0L, row(report, Stage.CLEANUP)["durationMs"])
        assertFalse(report.toMaps().toString().contains(raw))
        assertTrue(report.toMaps().all { "owner" !in it && "runHandle" !in it && "detail" !in it })
    }
}
