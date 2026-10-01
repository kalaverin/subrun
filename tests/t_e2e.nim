## End-to-end smoke over the built binaries (bin/tort, bin/subrun).
## Skipped with a clear message when the binaries are not built (make build).

import unittest2
import std/[os, osproc, strutils]
import tort/adapters/yyjson_bridge

const
  TortBin = "bin" / "tort"
  SubrunBin = "bin" / "subrun"

proc shq(s: string): string =
  ## Single-quote shell escaping.
  "'" & s.replace("'", "'\\''") & "'"

proc run(bin: string; args: openArray[string]; input = ""): tuple[outp: string; code: int] =
  ## Run a binary, feed input on stdin, capture stdout only (stderr stays out:
  ## subrun's wrapper logs go to stderr and must not pollute assertions).
  var parts = @[shq(bin)]
  for a in args:
    parts.add shq(a)
  let (o, c) = execCmdEx(parts.join(" "), input = input, options = {poUsePath})
  (o, c)

proc normJson(s: string): string =
  ## Normalize JSON text for comparison (whitespace-insensitive).
  toJsonText(parseJson(s.strip()))

suite "e2e: tort CLI":
  test "encode then decode round-trips":
    if not fileExists(TortBin):
      skip()
    let (tortText, c1) = run(TortBin, ["encode"], """{"a": 1, "b": [1, 2]}""")
    check c1 == 0
    check "a: 1" in tortText
    let (jsonText, c2) = run(TortBin, ["decode"], tortText)
    check c2 == 0
    check normJson(jsonText) == normJson("""{"a":1,"b":[1,2]}""")

  test "stream cleans mixed output":
    if not fileExists(TortBin):
      skip()
    let (o, c) = run(TortBin, ["stream", "--one-way=false"],
                     "junk line\n{\"a\": 1}\n")
    check c == 0
    check "junk line" in o
    check "a: 1" in o

  test "T29: flags-only invocation accepts cligen space-form values":
    if not fileExists(TortBin):
      skip()
    let (o, c) = run(TortBin, ["--one-way", "false"], "{\"a\": 1}\n")
    check c == 0
    check "a: 1" in o

  test "T29: flags-only --drop-junk drops junk":
    if not fileExists(TortBin):
      skip()
    let (o, c) = run(TortBin, ["--drop-junk", "--one-way=false"],
                     "junk line\n{\"a\": 1}\n")
    check c == 0
    check "junk" notin o
    check "a: 1" in o

  test "T29: --help is cligen-generated with flag documentation":
    if not fileExists(TortBin):
      skip()
    let (o, c) = run(TortBin, ["--help"])
    check c == 0
    check "drop-junk" in o
    check "one-way" in o
    check "optional-params" in o          ## cligen help shape, not a one-liner

  test "T29: unknown flag exits 2":
    if not fileExists(TortBin):
      skip()
    let (_, c) = run(TortBin, ["--bogus"])
    check c == 2

suite "e2e: subrun proxy":
  test "plain passthrough keeps stdout identical":
    if not fileExists(SubrunBin):
      skip()
    let (o, c) = run(SubrunBin, ["--", "/bin/echo", "hello"])
    check c == 0
    check o.strip() == "hello"

  test "guest exit code propagates":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--", "/bin/sh", "-c", "exit 7"])
    check c == 7

  test "--tort filters guest stdout JSON":
    if not fileExists(SubrunBin):
      skip()
    let (o, c) = run(SubrunBin, ["--tort", "--", "/bin/echo", """{"a": 1}"""])
    check c == 0
    check "a: 1" in o
