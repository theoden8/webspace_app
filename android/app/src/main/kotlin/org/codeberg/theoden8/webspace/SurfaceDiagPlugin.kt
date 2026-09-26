package org.codeberg.theoden8.webspace

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Samples the composited pixels over a region of the screen.
 *
 * A JS probe or a WebView-level capture reports the renderer's content plane,
 * which is healthy in every confirmed BUG-001 instance; only a pixel copy of
 * what SurfaceFlinger composites reads what the user actually sees. Uniform
 * white/black over the webview rect while the renderer claims a painted
 * document is the blank-surface symptom itself.
 *
 * A window copy never includes a SurfaceView's layer. Under hybrid
 * composition that does not matter, because Flutter draws into image views
 * inside the window. In texture mode (PAUSE-032) Flutter and the webview's
 * texture are in `FlutterSurfaceView`, and the window over it is a
 * transparent hole, so the sample fills transparent window pixels from the
 * SurfaceView behind them.
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
                "nativeRepaint" -> {
                    val mode = call.argument<String>("mode")
                    if (mode == null) {
                        result.error("INVALID_ARGS", "mode required", null)
                    } else {
                        result.success(nativeRepaint(mode))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Ask the real Android views to redraw, rather than resizing them from
     * Dart.
     *
     * A Dart-side nudge changes a widget's padding, which reaches the platform
     * view as a resize through Flutter's own plumbing; BUG-001 gap #18 recorded
     * six such nudges landing against a live renderer with the screen blank.
     * These call the View API directly on every WebView in the window, which is
     * what rotation and lock-unlock do and what a resize does not:
     *
     *  - "invalidate": schedule a redraw and a measure/layout pass.
     *  - "visibility": GONE then VISIBLE, so the view detaches from and
     *    re-attaches to the window without the WebView being destroyed.
     *
     * Main-looper only, like everything else here (BUG-007: none-shared).
     */
    private fun nativeRepaint(mode: String): Map<String, Any> {
        val decor = activity.window?.decorView
            ?: return mapOf("status" to "no-window", "views" to 0)
        val views = ArrayList<WebView>()
        collectWebViews(decor, views)
        for (v in views) {
            when (mode) {
                "invalidate" -> {
                    v.invalidate()
                    v.requestLayout()
                }
                "visibility" -> {
                    val previous = v.visibility
                    v.visibility = View.GONE
                    // Restore on the next main-looper turn: setting it back in
                    // this one is coalesced into no change at all, since the
                    // view never reaches a traversal in between.
                    Handler(Looper.getMainLooper()).post {
                        v.visibility = previous
                        v.invalidate()
                    }
                }
                else -> return mapOf("status" to "unknown-mode", "views" to 0)
            }
        }
        return mapOf("status" to "ok", "views" to views.size)
    }

    private fun collectWebViews(view: View, out: MutableList<WebView>) {
        if (view is WebView) {
            out.add(view)
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) collectWebViews(view.getChildAt(i), out)
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
                        fillFromSurfaceBehind(decor, region, bitmap) {
                            result.success(histogram(bitmap))
                            bitmap.recycle()
                        }
                    } else {
                        result.success(mapOf("status" to "copy-failed:$copyResult"))
                        bitmap.recycle()
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (e: IllegalArgumentException) {
            // Window surface not attached (mid-transition); transient, retry later.
            bitmap.recycle()
            result.success(mapOf("status" to "no-surface"))
        }
    }

    private fun fillFromSurfaceBehind(
        decor: View,
        region: Rect,
        windowPixels: Bitmap,
        done: () -> Unit,
    ) {
        val pixels = IntArray(SAMPLE_SIZE * SAMPLE_SIZE)
        windowPixels.getPixels(pixels, 0, SAMPLE_SIZE, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
        val surface = if (pixels.any { (it ushr 24) == 0 }) surfaceBehind(decor, region) else null
        if (surface == null) {
            done()
            return
        }
        val loc = IntArray(2)
        surface.getLocationInWindow(loc)
        val src = Rect(region)
        src.offset(-loc[0], -loc[1])
        val behind = Bitmap.createBitmap(SAMPLE_SIZE, SAMPLE_SIZE, Bitmap.Config.ARGB_8888)
        try {
            PixelCopy.request(
                surface,
                src,
                behind,
                { copyResult ->
                    if (copyResult == PixelCopy.SUCCESS) {
                        val under = IntArray(SAMPLE_SIZE * SAMPLE_SIZE)
                        behind.getPixels(under, 0, SAMPLE_SIZE, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
                        for (i in pixels.indices) {
                            if ((pixels[i] ushr 24) == 0) pixels[i] = under[i]
                        }
                        windowPixels.setPixels(pixels, 0, SAMPLE_SIZE, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
                    }
                    behind.recycle()
                    done()
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (e: IllegalArgumentException) {
            behind.recycle()
            done()
        }
    }

    /** The visible SurfaceView whose window rect contains all of [region]. */
    private fun surfaceBehind(view: View, region: Rect): SurfaceView? {
        if (view.visibility != View.VISIBLE) return null
        if (view is SurfaceView) {
            if (view.width <= 0 || view.height <= 0 || !view.holder.surface.isValid) return null
            val loc = IntArray(2)
            view.getLocationInWindow(loc)
            val rect = Rect(loc[0], loc[1], loc[0] + view.width, loc[1] + view.height)
            return if (rect.contains(region)) view else null
        }
        if (view is ViewGroup) {
            for (i in view.childCount - 1 downTo 0) {
                surfaceBehind(view.getChildAt(i), region)?.let { return it }
            }
        }
        return null
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
