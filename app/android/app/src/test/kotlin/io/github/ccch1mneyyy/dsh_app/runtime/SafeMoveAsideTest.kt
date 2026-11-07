package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test

class SafeMoveAsideTest {
    private fun fixture(block: (File) -> Unit) {
        val root = Files.createTempDirectory("safe-move-").toFile()
        try { block(root) } finally {
            File(root, "root/.dsh").setWritable(true)
            File(root, "root").setWritable(true)
            root.deleteRecursively()
        }
    }

    private fun put(root: File, path: String): File = SafeMode.guestFile(root, path).apply {
        parentFile!!.mkdirs()
        writeText(path)
    }

    private fun lock(dir: File) {
        assertTrue(dir.setWritable(false, false))
        assumeFalse("directory write permissions are not enforced", dir.canWrite())
    }

    @Test fun successfulMovesKeepCollisionAndSelectionRules() = fixture { root ->
        val path = SafeMode.MOVABLE.first()
        val source = put(root, path)
        val existing = File(source.parentFile, "${source.name}.off-test").apply { writeText("keep") }
        val foreign = put(root, "/root/not-selected")
        val result = SafeMode.moveAside(root, listOf(path, path, "/root/not-selected", SafeMode.MOVABLE[1]), "test")
        assertNull(result.failure)
        assertEquals(listOf(path to "$path.off-test-1"), result.moved)
        assertFalse(source.exists())
        assertEquals(path, SafeMode.guestFile(root, result.moved.single().second).readText())
        assertEquals("keep", existing.readText())
        assertTrue(foreign.isFile)
    }

    @Test fun firstRenameFailureIsNotAnEmptySuccess() = fixture { root ->
        val path = SafeMode.MOVABLE.first()
        val source = put(root, path)
        lock(source.parentFile!!)
        val result = SafeMode.moveAside(root, listOf(path), "test")
        assertTrue(result.moved.isEmpty())
        assertNotNull(result.failure)
        assertTrue(result.failure!!.message!!.contains(path))
        assertTrue(result.failure!!.message!!.contains("0 file(s) already moved"))
        assertEquals(path, source.readText())
        assertFalse(File(source.parentFile, "${source.name}.off-test").exists())
    }

    @Test fun partialFailurePreservesMovesAndCanRetryRemainingFiles() = fixture { root ->
        val first = SafeMode.MOVABLE[2] // /root/.env: writable parent
        val blocked = SafeMode.MOVABLE[0] // /root/.dsh: locked parent
        val remaining = SafeMode.MOVABLE[1]
        val firstFile = put(root, first)
        val blockedFile = put(root, blocked)
        val remainingFile = put(root, remaining)
        lock(blockedFile.parentFile!!)
        val result = SafeMode.moveAside(root, listOf(first, blocked, remaining), "test")
        assertNotNull(result.failure)
        assertEquals(listOf(first to "$first.off-test"), result.moved)
        assertTrue(result.failure!!.message!!.contains("1 file(s) already moved"))
        assertFalse(firstFile.exists())
        assertEquals(first, SafeMode.guestFile(root, result.moved.single().second).readText())
        assertEquals(blocked, blockedFile.readText())
        assertEquals(remaining, remainingFile.readText())
        assertTrue(blockedFile.parentFile!!.setWritable(true, false))
        val retry = SafeMode.moveAside(root, listOf(first, blocked, remaining), "retry")
        assertNull(retry.failure)
        assertEquals(listOf(blocked to "$blocked.off-retry", remaining to "$remaining.off-retry"), retry.moved)
        assertEquals(first, SafeMode.guestFile(root, result.moved.single().second).readText())
    }
}
