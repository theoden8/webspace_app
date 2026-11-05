package org.codeberg.theoden8.webspace

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The one way a line from the Android code reaches the app's log, where the
 * user reads it (DEVTOOLS-014): a failure caught here is named there with its
 * message and causes, as perror names errno, never left in logcat, which the
 * app cannot show.
 *
 * Every engine the app runs listens ([attach]): the activity's and a wake's.
 * Each line goes to every one whose Dart side has said it is listening, filed
 * under the Dart `LogTag` its [Tag] names and kept in memory only. The last
 * [RECENT] lines are kept, so an engine that starts listening late is sent
 * what it missed. A line that can name nothing of the user's also goes to
 * logcat at once, as before there was a sink, where a CI run's failure dump
 * reads it even when no engine came up.
 */
internal object AppLog {
    /**
     * The Dart `LogTag` a line is filed under, by name (a name Dart has no tag
     * for fails `test/js/native_log.test.js`), and whether its lines can name
     * a site, a host or a file the user picked, which keeps them out of
     * logcat. A failure's text comes from outside the app and is kept out
     * whatever its tag.
     */
    @Suppress("EnumEntryName")
    enum class Tag(val namesUserData: Boolean) {
        backgroundLog(false),
        backgroundTask(false),
        contentBlocker(false),
        htmlImport(true),
        location(false),
        mediaSession(true),
        passkey(true),
        proxyRelay(true),
        screenShare(false),
        shortcut(true),
        surfaceDiag(false),
        tls(false),
        webIntercept(true),
    }

    @Suppress("EnumEntryName")
    enum class Level { debug, info, warning }

    class Line(val seq: Long, val level: Level, val tag: Tag, val message: String)

    /** Where lines go: an engine's channel, or a test's list. It must not block. */
    fun interface Sink {
        fun send(lines: List<Line>)
    }

    private class State {
        val recent = ArrayDeque<Line>()
        /** Each listener's last line sent, or null until its Dart side listens. */
        val sent = mutableMapOf<Attached, Long?>()
        var next = 0L
    }

    private const val RECENT = 200
    private val state = Guarded(State())

    fun debug(tag: Tag, message: String) = write(Level.debug, tag, message, logcat = !tag.namesUserData)
    fun info(tag: Tag, message: String) = write(Level.info, tag, message, logcat = !tag.namesUserData)
    fun warning(tag: Tag, message: String) = write(Level.warning, tag, message, logcat = !tag.namesUserData)

    /** A caught failure: what was being done, then the failure with its causes. */
    fun failed(tag: Tag, doing: String, e: Throwable) =
        write(Level.warning, tag, "$doing failed: ${describe(e)}", logcat = false)

    // A sink only posts to a thread, so it is called inside the monitor: lines
    // reach every sink in the order they were written, the missed ones of a
    // late listener included.
    private fun write(level: Level, tag: Tag, message: String, logcat: Boolean) {
        if (logcat) Log.println(priority(level), "Webspace/${tag.name}", message)
        state.with {
            val line = Line(next++, level, tag, message)
            recent.addLast(line)
            while (recent.size > RECENT) recent.removeFirst()
            for (a in sent.filterValues { it != null }.keys) {
                sent[a] = line.seq
                a.sink.send(listOf(line))
            }
        }
    }

    /** A sink that is sent lines once [Attached.ready] is called. */
    fun listen(sink: Sink): Attached {
        val attached = Attached(sink)
        state.with { sent[attached] = null }
        return attached
    }

    class Attached internal constructor(internal val sink: Sink) {
        /** Its Dart side is listening: send what it missed, then every line. */
        fun ready() {
            state.with {
                val after = sent[this@Attached] ?: -1L
                val missed = recent.filter { it.seq > after }
                sent[this@Attached] = missed.lastOrNull()?.seq ?: after
                if (missed.isNotEmpty()) sink.send(missed)
            }
        }

        /** Its engine went: no more lines. */
        fun detach() {
            state.with { sent.remove(this@Attached) }
        }
    }

    /** [engine]'s channel as a sink, ready once its Dart side calls `ready`. */
    fun attach(engine: FlutterEngine): Attached {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        val main = Handler(Looper.getMainLooper())
        val attached = listen { lines ->
            val payload = lines.map {
                mapOf("level" to it.level.name, "tag" to it.tag.name, "message" to it.message)
            }
            main.post {
                // The one line that cannot reach the app's log is why the
                // app's log was not reached: logcat is all that is left.
                runCatching { channel.invokeMethod("lines", payload) }
                    .onFailure { Log.w(TAG, "${lines.size} log line(s) not delivered: ${describe(it)}") }
            }
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    attached.ready()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return attached
    }

    private fun priority(level: Level) = when (level) {
        Level.debug -> Log.DEBUG
        Level.info -> Log.INFO
        Level.warning -> Log.WARN
    }

    /** For tests: forget every line and listener. */
    internal fun resetForTest() {
        state.with {
            recent.clear()
            sent.clear()
            next = 0
        }
    }

    private const val CHANNEL = "org.codeberg.theoden8.webspace/app_log"
    private const val TAG = "WebspaceAppLog"
}
