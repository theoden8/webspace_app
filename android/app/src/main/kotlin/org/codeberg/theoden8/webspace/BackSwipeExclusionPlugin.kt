package org.codeberg.theoden8.webspace

import android.app.Activity
import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The strip of the left edge the sidebar's arrow tab keeps from the system
 * back swipe (TAB-032), as a system gesture exclusion on the Flutter view,
 * Android 10 and later. Dart owns the claim and sends it whole, in the
 * view's pixels, so nothing is kept here. Main looper only (BUG-007:
 * none-shared).
 */
class BackSwipeExclusionPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/back_swipe_exclusion"
    }

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setRects" -> {
                    val rects = (call.arguments as? List<*>)?.map { rectOf(it) }
                    if (rects == null || rects.any { it == null }) {
                        result.error("BAD_ARGS", "setRects takes a list of [left, top, right, bottom]", null)
                    } else {
                        apply(rects.filterNotNull())
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun rectOf(value: Any?): Rect? {
        val edges = (value as? List<*>)?.map { (it as? Number)?.toDouble() } ?: return null
        if (edges.size != 4 || edges.any { it == null }) return null
        val (left, top, right, bottom) = edges.filterNotNull()
        return Rect(left.toInt(), top.toInt(), Math.ceil(right).toInt(), Math.ceil(bottom).toInt())
    }

    /** The view Flutter draws into, whose pixels the rects are in. */
    private fun flutterView(): View? =
        activity.findViewById<ViewGroup>(android.R.id.content)?.getChildAt(0)

    private fun apply(rects: List<Rect>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        flutterView()?.systemGestureExclusionRects = rects
    }
}
