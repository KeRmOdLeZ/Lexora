package com.lexora.app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.GZIPInputStream

object DictExtractor : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private const val METHOD_CHANNEL_NAME = "com.lexora.app/dict_extractor"
    private const val PROGRESS_CHANNEL_NAME = "com.lexora.app/dict_extractor_progress"
    private const val DB_FILE_NAME = "vocab_dict.db"
    private const val ASSET_GZ_PATH = "assets/vocab_dict.db.gz"
    private const val ASSET_META_PATH = "assets/vocab_dict.meta.json"
    private const val MIN_EXPECTED_SIZE = 1024L
    private const val MAX_EXPECTED_SIZE = 1_500_000_000L
    private const val MAX_META_BYTES = 65_536
    private const val BUFFER_SIZE = 65_536
    private const val EXTRA_STORAGE_MARGIN_BYTES = 50L * 1024L * 1024L

    private val SQLITE_MAGIC = "SQLite format 3\u0000".toByteArray(Charsets.US_ASCII)
    private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val isExtracting = AtomicBoolean(false)
    private val pendingLock = Any()
    private val pendingResults = mutableListOf<MethodChannel.Result>()

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var lastProgress: Double = 0.0

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    fun register(appContext: Context, binaryMessenger: BinaryMessenger) {
        this.appContext = appContext.applicationContext
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)

        methodChannel = MethodChannel(binaryMessenger, METHOD_CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binaryMessenger, PROGRESS_CHANNEL_NAME).also {
            it.setStreamHandler(this)
        }
    }

    fun unregister() {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val cached = lastProgress
        if (events != null && (isExtracting.get() || cached > 0.0)) {
            mainHandler.post {
                eventSink?.success(cached)
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("NO_CONTEXT", "Application context is unavailable.", null)
            return
        }

        when (call.method) {
            "extractDict" -> handleExtractDict(ctx, result)
            "getDictDbPath" -> {
                val target = ctx.getDatabasePath(DB_FILE_NAME)
                result.success(target.absolutePath)
            }
            "openTtsSettings" -> {
                openTtsSettings(ctx)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun openTtsSettings(ctx: Context) {
        try {
            val ttsIntent = Intent("com.android.settings.TTS_SETTINGS").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (ttsIntent.resolveActivity(ctx.packageManager) != null) {
                ctx.startActivity(ttsIntent)
                return
            }
            val fallbackIntent = Intent(Settings.ACTION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (fallbackIntent.resolveActivity(ctx.packageManager) != null) {
                ctx.startActivity(fallbackIntent)
            }
        } catch (_: Throwable) {
            // Silently ignore if settings cannot be opened on restricted devices.
        }
    }

    private fun handleExtractDict(ctx: Context, result: MethodChannel.Result) {
        val shouldStart: Boolean
        synchronized(pendingLock) {
            pendingResults.add(result)
            shouldStart = isExtracting.compareAndSet(false, true)
        }
        if (!shouldStart) {
            // Second caller joins the in-flight extraction without error.
            return
        }

        // Resolve Flutter asset lookup keys strictly on the Main Thread.
        val loader = FlutterInjector.instance().flutterLoader()
        val gzKey = loader.getLookupKeyForAsset(ASSET_GZ_PATH)
        val metaKey = loader.getLookupKeyForAsset(ASSET_META_PATH)

        lastProgress = 0.0
        emitProgress(0.0)

        executor.execute {
            runExtraction(ctx.applicationContext, gzKey, metaKey)
        }
    }

    private fun runExtraction(ctx: Context, gzKey: String, metaKey: String) {
        var tmpFile: File? = null
        try {
            // 1) Read and validate assets/vocab_dict.meta.json (< 64 KB)
            val metaBytes = ctx.assets.open(metaKey).use { input ->
                val buffer = ByteArray(MAX_META_BYTES + 1)
                var offset = 0
                while (offset < buffer.size) {
                    val read = input.read(buffer, offset, buffer.size - offset)
                    if (read == -1) break
                    offset += read
                }
                if (offset > MAX_META_BYTES) {
                    throw IOException("Metadata file exceeds 64 KB safety limit.")
                }
                buffer.copyOf(offset)
            }

            val metaJson = JSONObject(String(metaBytes, Charsets.UTF_8))
            val expectedSize = metaJson.optLong("uncompressed_size", -1L)
            val expectedSha256 = metaJson.optString("uncompressed_sha256", "")

            if (expectedSize !in MIN_EXPECTED_SIZE..MAX_EXPECTED_SIZE) {
                throw IOException("Invalid expected uncompressed_size: $expectedSize")
            }
            if (!SHA256_REGEX.matches(expectedSha256)) {
                throw IOException("Invalid expected uncompressed_sha256 format.")
            }

            // 2) Prepare target database directory and verify canonical path confinement
            val target = ctx.getDatabasePath(DB_FILE_NAME)
            val dbDir = target.parentFile ?: throw IOException("Database directory unavailable.")
            if (!dbDir.exists() && !dbDir.mkdirs()) {
                throw IOException("Failed to create database directory.")
            }

            val canonicalDir = dbDir.canonicalPath
            val canonicalTarget = target.canonicalPath
            if (!canonicalTarget.startsWith(canonicalDir + File.separator)) {
                throw SecurityException("Target database path escapes database directory.")
            }

            // 3) Check available disk space: >= (expectedSize * 1.2) + 50 MB
            val statFs = StatFs(dbDir.path)
            val requiredBytes = (expectedSize * 1.2).toLong() + EXTRA_STORAGE_MARGIN_BYTES
            if (statFs.availableBytes < requiredBytes) {
                throw IOException(
                    "INSUFFICIENT_STORAGE: Need $requiredBytes bytes, available ${statFs.availableBytes} bytes."
                )
            }

            // 4) Clean stale temp/journal files and existing read-only dictionary DB
            val tempTarget = File(dbDir, "$DB_FILE_NAME.tmp")
            tmpFile = tempTarget
            val staleFiles = listOf(
                tempTarget,
                File(dbDir, "$DB_FILE_NAME-wal"),
                File(dbDir, "$DB_FILE_NAME-shm"),
                File(dbDir, "$DB_FILE_NAME-journal"),
                target
            )
            for (f in staleFiles) {
                if (f.exists()) {
                    f.setWritable(true)
                    if (!f.delete()) {
                        throw IOException("Failed to remove stale file: ${f.name}")
                    }
                }
            }

            // 5) Stream gzip decompression with SHA-256 verification and SQLite magic check
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(BUFFER_SIZE)
            val headerBytes = ByteArray(16)
            var headerFilled = 0
            var totalWritten = 0L
            var lastReportedPct = 0.0
            var lastReportTimeMs = System.currentTimeMillis()

            ctx.assets.open(gzKey).use { rawAsset ->
                BufferedInputStream(rawAsset, BUFFER_SIZE).use { buffered ->
                    GZIPInputStream(buffered, BUFFER_SIZE).use { gzipIn ->
                        FileOutputStream(tempTarget).use { fos ->
                            while (true) {
                                val count = gzipIn.read(buffer)
                                if (count <= 0) break

                                totalWritten += count
                                if (totalWritten > MAX_EXPECTED_SIZE) {
                                    throw IOException("Decompressed output exceeds maximum safety cap.")
                                }

                                if (headerFilled < 16) {
                                    val toCopy = minOf(16 - headerFilled, count)
                                    System.arraycopy(buffer, 0, headerBytes, headerFilled, toCopy)
                                    headerFilled += toCopy
                                    if (headerFilled == 16 && !headerBytes.contentEquals(SQLITE_MAGIC)) {
                                        throw IOException("Extracted payload is not a valid SQLite 3 database.")
                                    }
                                }

                                digest.update(buffer, 0, count)
                                fos.write(buffer, 0, count)

                                val progress = (totalWritten.toDouble() / expectedSize.toDouble())
                                    .coerceIn(0.0, 0.99)
                                val now = System.currentTimeMillis()
                                if (progress - lastReportedPct >= 0.01 || now - lastReportTimeMs >= 100L) {
                                    lastReportedPct = progress
                                    lastReportTimeMs = now
                                    lastProgress = progress
                                    emitProgress(progress)
                                }
                            }
                            fos.flush()
                            fos.fd.sync()
                        }
                    }
                }
            }

            if (headerFilled < 16 || !headerBytes.contentEquals(SQLITE_MAGIC)) {
                throw IOException("SQLite 3 header verification failed.")
            }
            if (totalWritten != expectedSize) {
                throw IOException("Size mismatch: wrote $totalWritten bytes, expected $expectedSize bytes.")
            }

            val actualSha256 = digest.digest().joinToString("") { "%02x".format(it) }
            if (actualSha256 != expectedSha256) {
                throw IOException("SHA-256 checksum mismatch after extraction.")
            }

            // 6) Atomic rename & verify return value, then lock file read-only (0444)
            if (!tempTarget.renameTo(target)) {
                tempTarget.delete()
                throw IOException("Atomic rename from .tmp to $DB_FILE_NAME failed.")
            }
            target.setReadOnly()

            lastProgress = 1.0
            emitProgress(1.0)
            finishAllSuccess(target.absolutePath)
        } catch (t: Throwable) {
            try {
                tmpFile?.let {
                    if (it.exists()) {
                        it.setWritable(true)
                        it.delete()
                    }
                }
            } catch (_: Throwable) {
                // Best-effort cleanup
            }
            val code = if (t.message?.startsWith("INSUFFICIENT_STORAGE") == true) {
                "INSUFFICIENT_STORAGE"
            } else {
                "EXTRACTION_FAILED"
            }
            finishAllError(code, t.message ?: "Dictionary extraction failed.")
        }
    }

    private fun emitProgress(value: Double) {
        mainHandler.post {
            eventSink?.success(value)
        }
    }

    private fun finishAllSuccess(dbPath: String) {
        val snapshot: List<MethodChannel.Result>
        synchronized(pendingLock) {
            snapshot = pendingResults.toList()
            pendingResults.clear()
            isExtracting.set(false)
        }
        mainHandler.post {
            for (res in snapshot) {
                res.success(dbPath)
            }
        }
    }

    private fun finishAllError(code: String, message: String) {
        val snapshot: List<MethodChannel.Result>
        synchronized(pendingLock) {
            snapshot = pendingResults.toList()
            pendingResults.clear()
            isExtracting.set(false)
        }
        mainHandler.post {
            for (res in snapshot) {
                res.error(code, message, null)
            }
        }
    }
}
