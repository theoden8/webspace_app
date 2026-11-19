package org.codeberg.theoden8.webspace

/**
 * The URL a share's text carries (LIR-005): the text itself when it is an
 * http(s) URL once trimmed, else the first http(s) URL inside it, else none.
 */
object ShareText {
    private val scheme = Regex("""^([A-Za-z][A-Za-z0-9+.\-]*):""")
    private val embedded = Regex("""https?://\S+""")

    fun urlIn(text: String?): String? {
        val trimmed = text?.trim() ?: return null
        if (trimmed.isEmpty()) return null
        val direct = scheme.find(trimmed)?.groupValues?.get(1)?.lowercase()
        return if (direct == "http" || direct == "https") {
            trimmed
        } else {
            embedded.find(trimmed)?.value
        }
    }
}
