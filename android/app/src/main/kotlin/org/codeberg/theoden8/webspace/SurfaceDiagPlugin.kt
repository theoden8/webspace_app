package org.codeberg.theoden8.webspace

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Samples the composited window pixels over a region of the screen.
 *
 * The webview is a hybrid-composition SurfaceView whose buffer is composited
 * by the OS, out of band of both Flutter's raster tree and the renderer's own
 * draw path. A JS probe or a WebView-level capture reports the renderer's
 * content plane, which is healthy in every confirmed BUG-001 instance; only a
 * window-level PixelCopy reads what the user actually sees. Uniform
 * white/black over the webview rect while the renderer claims a painted
 * document is the blank-surface symptom itself.
 *
 * Everything runs on the main looper (the method-channel handler, the
 * PixelCopy callback, the 1024-pixel histogram), so there is no shared
 * mutable state across threads (BUG-007: none-shared).
 */
class SurfaceDiagPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/surface_diag"
        // PixelCopy scales the source rect into the destination bitmap, so the
        // histogram cost is fixed at SAMPLE_SIZE^2 pixels regardless of the
        // sampled region's on-screen size.
        private const val SAMPLE_SIZE = 32
    }

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sampleWindowRegion" -> {
                    val left = call.argument<Int>("left")
                    val top = call.argument<Int>("top")
                    val width = call.argument<Int>("width")
                    val height = call.argument<Int>("height")
                    if (left == null || top == null || width == null || height == null) {
                        result.error("INVALID_ARGS", "left/top/width/height required", null)
                    } else {
                        sampleWindowRegion(left, top, width, height, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun sampleWindowRegion(
        left: Int,
        top: Int,
        width: Int,
        height: Int,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(mapOf("status" to "unsupported"))
            return
        }
        val decor = activity.window?.decorView
        if (decor == null || decor.width <= 0 || decor.height <= 0) {
            result.success(mapOf("status" to "no-window"))
            return
        }
        val region = Rect(left, top, left + width, top + height)
        if (!region.intersect(Rect(0, 0, decor.width, decor.height)) ||
            region.width() <= 0 || region.height() <= 0
        ) {
            result.success(mapOf("status" to "bad-region"))
            return
        }
        val bitmap = Bitmap.createBitmap(SAMPLE_SIZE, SAMPLE_SIZE, Bitmap.Config.ARGB_8888)
        try {
            PixelCopy.request(
                activity.window,
                region,
                bitmap,
                { copyResult ->
                    if (copyResult == PixelCopy.SUCCESS) {
                        result.success(histogram(bitmap))
                    } else {
                        result.success(mapOf("status" to "copy-failed:$copyResult"))
                    }
                    bitmap.recycle()
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (e: IllegalArgumentException) {
            // Window surface not attached (mid-transition); transient, retry later.
            bitmap.recycle()
            result.success(mapOf("status" to "no-surface"))
        }
    }

    private fun histogram(bitmap: Bitmap): Map<String, Any> {
        val pixels = IntArray(SAMPLE_SIZE * SAMPLE_SIZE)
        bitmap.getPixels(pixels, 0, SAMPLE_SIZE, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
        // Quantize to the top 4 bits per channel so dithering and slight
        // gradients still land in one bucket; report an actual pixel from the
        // dominant bucket rather than the quantized key.
        val counts = HashMap<Int, Int>()
        val representative = HashMap<Int, Int>()
        for (p in pixels) {
            val key = p and 0xF0F0F0F0.toInt()
            counts[key] = (counts[key] ?: 0) + 1
            if (!representative.containsKey(key)) representative[key] = p
        }
        val dominant = counts.maxByOrNull { it.value }!!
        return mapOf(
            "status" to "ok",
            "dominantColor" to (representative[dominant.key] ?: dominant.key),
            "uniformFraction" to dominant.value.toDouble() / pixels.size,
        )
    }
}
