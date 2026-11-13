"""What TLA+ text names, read the way SANY reads it: every script under
formal/ that reads a module's text takes its comments out here.
"""


def code(text, *, keep_strings):
    """[text] with its comments blanked, every line break and column kept,
    so a position in it is the source's. Block comments nest. A string keeps
    its text when [keep_strings], else only its quotes, so its words name
    nothing."""
    out, i, depth, n = [], 0, 0, len(text)
    while i < n:
        if text.startswith("(*", i):
            depth += 1
            out.append("  ")
            i += 2
        elif depth and text.startswith("*)", i):
            depth -= 1
            out.append("  ")
            i += 2
        elif depth:
            out.append("\n" if text[i] == "\n" else " ")
            i += 1
        elif text.startswith("\\*", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            body = text[i:j + 1]
            out.append(body if keep_strings else
                       '"' + "".join("\n" if c == "\n" else " "
                                     for c in body[1:-1]) + body[-1:])
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)
