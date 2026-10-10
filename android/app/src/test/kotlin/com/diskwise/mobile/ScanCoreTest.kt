package com.diskwise.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean

class ScanCoreTest {
    @Test fun identicalContentDifferentNames() {
        val directory = Files.createTempDirectory("diskwise-dup").toFile()
        try {
            val sameBytes = ByteArray(150_000) { (it % 199).toByte() }
            File(directory, "old-photo.jpg").writeBytes(sameBytes)
            File(directory, "renamed.bin").writeBytes(sameBytes)
            File(directory, "different.bin").writeBytes(ByteArray(150_000) { (it % 197).toByte() })
            val result = ScanCore.scan(directory, 365, 100, AtomicBoolean(false))
            assertEquals(3, result.filesChecked)
            assertEquals(1, result.duplicateGroups.size)
            assertEquals(150_000L, result.duplicateBytes)
        } finally { directory.deleteRecursively() }
    }

    @Test fun emptyOldFilesAreCandidatesButNotDuplicateReclaim() {
        val directory = Files.createTempDirectory("diskwise-tiny").toFile()
        try {
            val file = File(directory, "empty-file").apply {
                writeBytes(byteArrayOf())
                setLastModified(System.currentTimeMillis() - 400L * 24L * 60L * 60L * 1000L)
            }
            val result = ScanCore.scan(directory, 365, 100, AtomicBoolean(false))
            assertEquals(1, result.filesChecked)
            assertEquals(0, result.duplicateGroups.size)
            assertEquals(file.absolutePath, result.tiny.first().path)
            assertTrue(result.unused.any { it.path == file.absolutePath })
            assertTrue(result.folders.any { it["path"] == directory.canonicalPath })
        } finally { directory.deleteRecursively() }
    }

    @Test fun cancelledScanTerminates() {
        val directory = Files.createTempDirectory("diskwise-cancel").toFile()
        try {
            File(directory, "file.txt").writeText("hello")
            var cancelled = false
            try { ScanCore.scan(directory, 1, 1, AtomicBoolean(true)) }
            catch (_: InterruptedException) { cancelled = true }
            assertTrue(cancelled)
        } finally { directory.deleteRecursively() }
    }
}
