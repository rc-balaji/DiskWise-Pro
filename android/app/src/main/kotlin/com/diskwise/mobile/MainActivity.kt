package com.diskwise.mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Native engine isolates large I/O work on a single worker, UI only receives bounded pages. */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)
    @Volatile private var running = false
    @Volatile private var snapshot: ScanSnapshot? = null
    private var events: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "diskwise/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "diskwise/engine")
            .setMethodCallHandler { call, result -> when (call.method) {
                "permissionStatus" -> result.success(Environment.isExternalStorageManager())
                "requestPermission" -> { launchPermissionSettings(); result.success(true) }
                "listRoots" -> result.success(rootsInfo())
                "scan" -> beginScan(call, result)
                "cancelScan" -> { cancelled.set(true); result.success(true) }
                "getPage" -> page(call, result)
                "deleteSelected" -> beginDelete(call, result)
                else -> result.notImplemented()
            } }
    }

    private fun launchPermissionSettings() {
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    private fun roots(): List<File> {
        val storage = getSystemService(STORAGE_SERVICE) as StorageManager
        val paths = mutableListOf<File>()
        storage.storageVolumes.forEach { volume ->
            // Android 11+: storageVolume.directory (no reflection or hardcoded SD card paths).
            volume.directory?.let { if (it.isDirectory && it.canRead()) paths.add(it) }
        }
        if (paths.isEmpty()) paths.add(Environment.getExternalStorageDirectory())
        return paths.mapNotNull { try { it.canonicalFile } catch (_: Exception) { null } }
            .filter { it.isDirectory && it.path != "/" }.distinctBy { it.path }
    }

    private fun rootsInfo(): List<Map<String, Any>> = roots().mapIndexed { index, root ->
        val stat = StatFs(root.path)
        val total = try { stat.totalBytes } catch (_: Exception) { 0L }
        val free = try { stat.availableBytes } catch (_: Exception) { 0L }
        mapOf("id" to root.path, "label" to if (index == 0) "Internal storage" else "External storage ${index}",
            "path" to root.path, "total" to total, "free" to free)
    }

    private fun beginScan(call: MethodCall, result: MethodChannel.Result) {
        if (!Environment.isExternalStorageManager()) {
            result.error("PERMISSION", "Grant All files access in Android settings first", null); return
        }
        if (running) { result.error("BUSY", "A scan or deletion is already running", null); return }
        val requested = call.argument<String>("root") ?: "all"
        val available = roots()
        val selected = if (requested == "all") available else available.filter { it.path == requested }
        if (selected.isEmpty()) { result.error("ROOT", "Select an available storage volume", null); return }
        val days = (call.argument<Int>("days") ?: 180).coerceIn(1, 3650)
        val largeMB = (call.argument<Int>("largeMB") ?: 100).coerceIn(1, 100_000)
        running = true
        cancelled.set(false)
        snapshot = null
        result.success(true)
        worker.execute {
            try {
                val scanned = ScanCore.scanRoots(selected, days, largeMB, cancelled) { count, phase ->
                    emit(mapOf("event" to "progress", "count" to count, "phase" to phase))
                }
                snapshot = scanned
                emit(mapOf("event" to "complete", "summary" to scanned.summary()))
            } catch (_: InterruptedException) {
                emit(mapOf("event" to "cancelled"))
            } catch (error: Throwable) {
                emit(mapOf("event" to "error", "message" to (error.message ?: "Unable to scan storage")))
            } finally { running = false }
        }
    }

    private fun page(call: MethodCall, result: MethodChannel.Result) {
        val data = snapshot
        if (data == null) { result.error("EMPTY", "Run scan first", null); return }
        val kind = call.argument<String>("kind") ?: "duplicates"
        val offset = (call.argument<Int>("offset") ?: 0).coerceAtLeast(0)
        val limit = (call.argument<Int>("limit") ?: 40).coerceIn(1, 100)
        val entries: List<Map<String, Any>> = when (kind) {
            "duplicates" -> data.duplicateGroups.map { it.asMap() }
            "unused" -> data.unused.map { it.asMap() }
            "large" -> data.large.map { it.asMap() }
            "tiny" -> data.tiny.map { it.asMap() }
            "folders" -> data.folders
            else -> { result.error("KIND", "Unknown result kind", null); return }
        }
        result.success(mapOf("count" to entries.size, "items" to entries.drop(offset).take(limit)))
    }

    /** File.delete is permanent on Android. UI explicitly warns and requires manual confirmation. */
    private fun beginDelete(call: MethodCall, result: MethodChannel.Result) {
        if (!Environment.isExternalStorageManager()) { result.error("PERMISSION", "No storage access", null); return }
        if (running) { result.error("BUSY", "Please wait for the current operation", null); return }
        val scanned = snapshot
        if (scanned == null) { result.error("EMPTY", "Scan before deleting", null); return }
        val providedPaths = call.argument<List<String>>("paths").orEmpty().distinct().take(100)
        val validPaths = scanned.duplicateGroups.flatMap { it.items }.map { it.path }.toSet()
        if (providedPaths.isEmpty() || providedPaths.any { it !in validPaths }) {
            result.error("SELECTION", "Only individually selected, verified duplicates can be deleted", null); return
        }
        running = true
        result.success(true)
        worker.execute {
            var deleted = 0
            var freed = 0L
            val failures = arrayListOf<String>()
            val allRoots = roots().map { it.canonicalPath.trimEnd('/') + "/" }
            try {
                for (path in providedPaths) {
                    val group = scanned.duplicateGroups.find { group -> group.items.any { it.path == path } }
                    val file = File(path)
                    if (group == null || !file.isFile || !file.canWrite()) { failures.add(path); continue }
                    val canonical = try { file.canonicalPath } catch (_: Exception) { failures.add(path); continue }
                    if (path != canonical || allRoots.none { canonical.startsWith(it) } ||
                        canonical.contains("/Android/data/") || canonical.contains("/Android/obb/")) {
                        failures.add(path); continue
                    }
                    val recorded = group.items.first { it.path == path }
                    if (file.length() != recorded.size || file.lastModified() != recorded.modified) {
                        failures.add(path); continue
                    }
                    // Ensure a non-selected keeper still exists and is byte-identical *now*.
                    val keepers = group.items.filter { it.path !in providedPaths && it.path != path }
                    val hasVerifiedKeeper = keepers.any { candidate ->
                        val f = File(candidate.path)
                        try { f.isFile && f.length() == recorded.size && ScanCore.fullDigest(f) == group.signature }
                        catch (_: Exception) { false }
                    }
                    if (!hasVerifiedKeeper) { failures.add(path); continue }
                    try {
                        if (ScanCore.fullDigest(file) != group.signature) { failures.add(path); continue }
                        if (file.delete()) { deleted++; freed += recorded.size } else failures.add(path)
                    } catch (_: Exception) { failures.add(path) }
                }
                snapshot = null // stale scan cannot be used again for deletion.
                emit(mapOf("event" to "deleted", "count" to deleted, "bytes" to freed,
                    "failed" to failures.size, "message" to "Rescan before another deletion"))
            } catch (e: Exception) {
                emit(mapOf("event" to "error", "message" to (e.message ?: "Deletion error")))
            } finally { running = false }
        }
    }

    private fun emit(message: Map<String, Any>) { ui.post { events?.success(message) } }

    override fun onDestroy() { cancelled.set(true); worker.shutdownNow(); super.onDestroy() }
}
