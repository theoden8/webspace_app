package org.codeberg.theoden8.webspace

/**
 * [e] as a log line names it, as perror names errno: what was thrown and
 * its message, then each cause. A class name alone says that something
 * failed, not why. Every handler that logs what it caught goes through it
 * (`test/js/native_errors_named.test.js`).
 */
internal fun describe(e: Throwable): String =
    generateSequence(e) { t -> t.cause?.takeIf { it !== t } }
        .take(MAX_CAUSES)
        .joinToString(", caused by ") { t ->
            listOfNotNull(t.javaClass.simpleName, t.message?.takeIf { it.isNotBlank() }).joinToString(": ")
        }

private const val MAX_CAUSES = 4
