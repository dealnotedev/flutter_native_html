package tech.plink.flutter_html

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Bridges incoming "open .eml" intents (ACTION_VIEW / ACTION_SEND) to Flutter
 * over a [MethodChannel], so the demo can render a file the user opened from
 * Gmail, a file manager, or the downloads list — no plugin required.
 *
 * Dart pulls the launch file via `getInitialEml`; files opened while the app is
 * already running arrive through the `onEml` callback (the activity is
 * `singleTop`, so the OS routes them to [onNewIntent]).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "tech.plink.flutter_html/eml"
    private var channel: MethodChannel? = null
    private val inputExecutor = Executors.newSingleThreadExecutor()
    private val maxInputBytes = 20 * 1024 * 1024

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialEml" -> readIntentAsync(intent) { result.success(it) }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readIntentAsync(intent) { payload ->
            if (payload != null) channel?.invokeMethod("onEml", payload)
        }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        inputExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun readIntentAsync(intent: Intent?, deliver: (Map<String, Any>?) -> Unit) {
        inputExecutor.execute {
            val payload = readIntent(intent)
            runOnUiThread {
                if (!isDestroyed) deliver(payload)
            }
        }
    }

    /** Returns `{name, bytes}` for an openable file in [intent], or null. */
    private fun readIntent(intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            else -> intent.data // ACTION_VIEW and friends
        }
        if (uri == null) return null
        return try {
            val (name, size) = fileInfo(uri)
            if (size != null && size > maxInputBytes) throw EmailInputTooLarge()
            val bytes = contentResolver.openInputStream(uri)?.use {
                it.readEmailBytes(maxInputBytes)
            }
                ?: return null
            mapOf("name" to name, "bytes" to bytes)
        } catch (_: EmailInputTooLarge) {
            mapOf("error" to "File is too large to render safely")
        } catch (_: Exception) {
            mapOf("error" to "Could not read the email file")
        }
    }

    /** The file's display name (e.g. `receipt.eml`), falling back to a default. */
    private fun fileInfo(uri: Uri): Pair<String, Long?> {
        var name = "email.eml"
        var size: Long? = null
        try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) name = cursor.getString(index) ?: name
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex).takeIf { it >= 0 }
                    }
                }
            }
        } catch (_: Exception) {
            // Some providers don't support the query; keep the default name.
        }
        return name to size
    }
}
