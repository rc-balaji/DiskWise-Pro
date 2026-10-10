package com.diskwise.mobile

import java.io.File
import java.io.FileInputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/** Platform-independent, offline storage analyzer. No Android libraries required. */
internal data class Entry(val path: String, val size: Long, val modified: Long) {
    val name: String get() = File(path).name
    fun asMap(): Map<String, Any> = mapOf("path" to path, "name" to name, "size" to size, "modified" to modified)
}

internal data class DuplicateGroup(val signature: String, val items: List<Entry>) {
    val reclaimable: Long get() = (items.size - 1).toLong() * items[0].size
    fun asMap(): Map<String, Any> = mapOf(
        "id" to signature,
        "size" to items[0].size,
        "reclaimable" to reclaimable,
        "items" to items.map { it.asMap() }
    )
}

internal data class FolderRecord(var bytes: Long = 0, var oldBytes: Long = 0, var fileCount: Int = 0, var oldCount: Int = 0)
internal data class ScanSnapshot(
    val root: String,
    val filesChecked: Int,
    val totalBytes: Long,
    val inaccessible: Int,
    val truncated: Boolean,
    val duplicateGroups: List<DuplicateGroup>,
    val unused: List<Entry>,
    val large: List<Entry>,
    val tiny: List<Entry>,
    val folders: List<Map<String, Any>>,
    val finishedAt: Long
) {
    val duplicateBytes: Long get() = duplicateGroups.sumOf { it.reclaimable }
    fun summary(): Map<String, Any> = mapOf(
        "root" to root, "filesChecked" to filesChecked, "totalBytes" to totalBytes,
        "inaccessible" to inaccessible, "truncated" to truncated,
        "duplicateGroups" to duplicateGroups.size,
        "duplicateBytes" to duplicateBytes, "unusedFiles" to unused.size,
        "unusedBytes" to unused.sumOf { it.size }, "largeFiles" to large.size,
        "tinyFiles" to tiny.size, "finishedAt" to finishedAt
    )
}

internal object ScanCore {
    private const val LIMIT_FILES = 250_000
    private const val RESULT_LIMIT = 2_000
    private const val HASH_SAMPLE = 64 * 1024
    private const val HASH_BUFFER = 128 * 1024
    private const val MILLIS_DAY = 24L * 60 * 60 * 1000
    private val blockedNames = setOf("android", "system volume information", "recovery", "$" + "recycle.bin")

    /** No symlinks or reparse-like cycles; never recurse into Android's application storage. */
    fun scan(
        root: File,
        unusedDays: Int,
        minLargeMB: Int,
        cancel: AtomicBoolean,
        onProgress: (Int, String) -> Unit = { _, _ -> }
    ): ScanSnapshot = scanRoots(listOf(root), unusedDays, minLargeMB, cancel, onProgress)

    fun scanRoots(
        roots: List<File>,
        unusedDays: Int,
        minLargeMB: Int,
        cancel: AtomicBoolean,
        onProgress: (Int, String) -> Unit = { _, _ -> }
    ): ScanSnapshot {
        require(roots.isNotEmpty()) { "No storage roots available" }
        val safeRoots = roots.map { it.canonicalFile }.distinctBy { it.path }
        require(safeRoots.all { it.isDirectory && it.path != "/" }) { "Invalid storage root" }
        val cutoff = System.currentTimeMillis() - (unusedDays.coerceIn(1, 3650) * MILLIS_DAY)
        val largeLimit = minLargeMB.coerceIn(1, 100_000).toLong() * 1024L * 1024
        val folders = hashMapOf<String, FolderRecord>()
        val allFiles = ArrayList<Entry>(12_000)
        val old = ArrayList<Entry>()
        val big = ArrayList<Entry>()
        val tiny = ArrayList<Entry>()
        val pending = ArrayDeque<File>()
        val allowedPrefixes = safeRoots.map { it.path.trimEnd('/') + "/" }
        var bytes = 0L
        var count = 0
        var inaccessible = 0
        var truncated = false
        safeRoots.forEach { pending.add(it) }
        while (pending.isNotEmpty() && !cancel.get()) {
            val dir = pending.removeLast()
            val dirChildren = try { dir.listFiles() } catch (_: SecurityException) { null }
            if (dirChildren == null) { inaccessible++; continue }
            for (child in dirChildren) {
                if (cancel.get()) break
                // Avoid expensive canonicalPath() on every file; reject symlinks with lstat.
                // listFiles() only enumerates descendants of previously validated directories.
                val childPath = child.absolutePath
                if (allowedPrefixes.none { childPath.startsWith(it) }) continue
                if (try { Files.isSymbolicLink(child.toPath()) } catch (_: Exception) { true }) continue
                val directory = try { child.isDirectory } catch (_: SecurityException) { false }
                if (directory) {
                    if (child.name.lowercase(Locale.ROOT) !in blockedNames && child.name != "." && child.name != "..") pending.add(child)
                    continue
                }
                if (!child.isFile || !child.canRead()) { inaccessible++; continue }
                val entry = Entry(childPath, max(0, child.length()), child.lastModified())
                allFiles.add(entry)
                count++
                bytes += entry.size
                val isOld = entry.modified in 1 until cutoff
                val folderKey = child.parentFile?.absolutePath ?: safeRoots.first().absolutePath
                if (isOld) old.add(entry)
                // Roll up folder sizes to each parent within the scanned volume.
                var folder = File(folderKey)
                while (allowedPrefixes.any { (folder.path + "/").startsWith(it) }) {
                    val agg = folders.getOrPut(folder.path) { FolderRecord() }
                    agg.fileCount++
                    agg.bytes += entry.size
                    if (isOld) { agg.oldBytes += entry.size; agg.oldCount++ }
                    folder = folder.parentFile ?: break
                }
                if (entry.size >= largeLimit) big.add(entry)
                if (entry.size in 0..1023L) tiny.add(entry)
                if (count % 450 == 0) onProgress(count, "Indexing ${child.parentFile?.name ?: "storage"}")
                if (count >= LIMIT_FILES) { truncated = true; break }
            }
            if (truncated) break
        }
        if (cancel.get()) throw InterruptedException("Scan cancelled")
        onProgress(count, "Checking likely duplicates")
        val groups = detectDuplicates(allFiles, cancel) { complete, total ->
            if (total > 0 && complete % 30 == 0) onProgress(count, "Verifying duplicates $complete/$total")
        }
        if (cancel.get()) throw InterruptedException("Scan cancelled")
        val folderRows = folders.entries.asSequence().filter { it.value.oldCount > 0 }
            .sortedByDescending { it.value.oldBytes }.take(700).map { (path, v) ->
                mapOf("path" to path, "bytes" to v.bytes, "unusedBytes" to v.oldBytes,
                    "fileCount" to v.fileCount, "unusedCount" to v.oldCount)
            }.toList()
        return ScanSnapshot(safeRoots.joinToString(", ") { it.path }, count, bytes, inaccessible, truncated,
            groups.sortedByDescending { it.reclaimable }.take(700),
            old.sortedByDescending { it.size }.take(RESULT_LIMIT),
            big.sortedByDescending { it.size }.take(RESULT_LIMIT),
            tiny.sortedBy { it.size }.take(RESULT_LIMIT), folderRows, System.currentTimeMillis())
    }

    /** Size -> fast partial SHA256 -> full SHA256, with a metadata check around reads. */
    fun detectDuplicates(entries: List<Entry>, cancel: AtomicBoolean, progress: (Int, Int) -> Unit = { _, _ -> }): List<DuplicateGroup> {
        // Empty files are already reported in Tiny Files. They reclaim no space and can
        // form pathological groups with tens of thousands of entries.
        val candidates = entries.filter { it.size > 0 }.groupBy { it.size }.values.filter { it.size > 1 }.flatten()
        if (candidates.isEmpty()) return emptyList()
        val sampled = HashMap<String, MutableList<Entry>>()
        candidates.forEachIndexed { index, item ->
            if (cancel.get()) return emptyList()
            val file = File(item.path)
            if (file.length() != item.size || file.lastModified() != item.modified) return@forEachIndexed
            val fingerprint = try { "${item.size}:${partialDigest(file, item.size)}" } catch (_: Exception) { null }
            if (fingerprint != null) sampled.getOrPut(fingerprint) { arrayListOf() }.add(item)
            progress(index + 1, candidates.size)
        }
        val verified = ArrayList<DuplicateGroup>()
        sampled.values.filter { it.size > 1 }.forEach { partialGroup ->
            if (cancel.get()) return emptyList()
            val full = HashMap<String, MutableList<Entry>>()
            for (entry in partialGroup) {
                val file = File(entry.path)
                if (file.length() != entry.size || file.lastModified() != entry.modified) continue
                val digest = try { fullDigest(file, cancel) } catch (_: Exception) { continue }
                if (file.length() != entry.size || file.lastModified() != entry.modified) continue
                full.getOrPut(digest) { arrayListOf() }.add(entry)
            }
            for ((hash, matched) in full) if (matched.size > 1) {
                verified.add(DuplicateGroup(hash, matched.sortedWith(compareBy<Entry> { it.modified }.thenBy { it.path })))
            }
        }
        return verified
    }

    fun fullDigest(file: File, cancel: AtomicBoolean? = null): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { stream ->
            val buffer = ByteArray(HASH_BUFFER)
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                if (cancel?.get() == true) throw InterruptedException("Cancelled while hashing")
                md.update(buffer, 0, n)
            }
        }
        return md.digest().toHex()
    }

    private fun partialDigest(file: File, fileSize: Long): String {
        val md = MessageDigest.getInstance("SHA-256")
        java.io.RandomAccessFile(file, "r").use { raf ->
            val firstSize = minOf(HASH_SAMPLE.toLong(), fileSize).toInt()
            val first = ByteArray(firstSize)
            raf.readFully(first)
            md.update(first)
            if (fileSize > HASH_SAMPLE) {
                raf.seek(max(0L, fileSize - HASH_SAMPLE))
                val tail = ByteArray(minOf(HASH_SAMPLE.toLong(), fileSize).toInt())
                raf.readFully(tail)
                md.update(tail)
            }
        }
        return md.digest().toHex()
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
