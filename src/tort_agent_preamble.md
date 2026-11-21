# ── TORT STREAM PREAMBLE (format v0.1.8, one-way mode) ─────────────────
# This stream is NOT JSON. It is Tort — a line-oriented encoding of JSON
# documents, optimized for language-model reading. This preamble is a block
# of Tort comments (# lines): a Tort parser skips it entirely.
#
# STREAM SHAPE
# The stream is a sequence of documents. Each document is one JSON value
# (usually an object) written in Tort. Documents are separated by a line
# containing exactly --- . Everything before the first --- belongs to the
# first document. Between documents you may also see verbatim non-Tort
# lines — that is raw passthrough of the producer's non-JSON output
# (junk); read it as plain text, it is never structure.
#
# READING ONE DOCUMENT
# Each line is one statement. Forms:
#   key: value              → object entry "key": value
#   a.b.c: 1                → nested path: {"a": {"b": {"c": 1}}}
#   .x: 2                   → relative path: dots pop that many segments
#                             from the current path, then append (trie
#                             compression; .. pops two, and so on)
#   arr[].x: 1              → append a new object to array "arr", descend:
#                             {"arr": […{"x": 1}]}; the next ..[] starts
#                             the following element
#   name[N]{c1|c2}:         → table header: array "name" with N rows,
#   r1|r2                     each row is | -separated cells →
#                             {"c1": r1, "c2": r2}; rows follow immediately
#   name[N:]{c1|c2}:        → keyed table: same, but the FIRST cell of each
#   k|r1|r2                   row is a string key K → "name"[K] = {…}
#   A row may END EARLY: cells missing on the right are null.
#   ^ as a whole cell       → ditto: repeats the value ABOVE in the same
#                             column (a literal "^" is always quoted)
#   key: a,b,c              → inline list ["a","b","c"]; `x,` = ["x"]
#   key: {} / key: []       → empty object / empty array
#
# SCALARS
#   ~  → null      + → true      - → false
#   123 / -42 → integer        3.14 / 1e-4 / 100. → float
# Anything else unquoted is a bare string. A bare token that merely LOOKS
# numeric but is not canonical (+5, .5, 007) is a string by design.
#
# STRING FORMS
#   bare text               → string, verbatim
#   "quoted"                → string; hatches \" \\ \n \r \t
#   """raw"""               → string, VERBATIM — no escapes processed
#   '''…''' or ```…```      → string; hatches processed, " is free inside
#   key: ```[N]             → heredoc: the NEXT N LINES are the string,
#                             verbatim, ending with a newline; no marker
#                             scanning — count the lines
# All non-heredoc string forms are single-line.
#
# ONE-WAY ARTIFACTS (this stream is lossy by design)
# - Strings that contained whole JSON objects/arrays were UNPACKED into
#   real structure. Strings that look like bare JSON scalars ("42") were
#   NOT unpacked — they stay strings.
# - Whitespace was squashed: trailing spaces stripped, runs of >3 newlines
#   collapsed to 3, space indentation converted to tabs.
# Do not attempt to reconstruct the producer's exact original bytes.
#
# EXAMPLE — the JSON document
#   {"user": {"id": 7, "name": "Ada"}, "tags": ["x","y"], "ok": true}
# arrives as:
#   user.id: 7
#   .name: Ada
#   tags: x,y
#   ok: +
#
# If you need the exact byte-level grammar, ask for the Tort v0.1.8 spec.
#
# ENVELOPE NOTE (MCP proxy): tools/list responses in this stream have
# `outputSchema` stripped from every tool, and `structuredContent` is dropped
# wherever a `content` array is present (deduplication against the Tort
# payload). The JSON-RPC envelope itself is untouched.
# ── END PREAMBLE ────────────────────────────────────────────────────────
