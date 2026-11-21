## End-to-end smoke over the built binaries (bin/tort, bin/subrun).
## Skipped with a clear message when the binaries are not built (make build).

import unittest2
import std/[os, osproc, strutils, times]
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

  test "T29: flags-only invocation accepts cligen prefix and camelCase forms":
    ## cligen normalizes long options (--one-way == --oneWay) and accepts any
    ## unambiguous prefix (--one-w) — the hand-rolled parser knew neither.
    if not fileExists(TortBin):
      skip()
    let (o1, c1) = run(TortBin, ["--one-w=false"], "{\"a\": 1}\n")
    check c1 == 0
    check "a: 1" in o1
    let (o2, c2) = run(TortBin, ["--dropJunk", "--one-way=false"],
                       "junk line\n{\"a\": 1}\n")
    check c2 == 0
    check "junk" notin o2
    check "a: 1" in o2

  test "T29: --help is cligen-generated with flag documentation":
    if not fileExists(TortBin):
      skip()
    let (o, c) = run(TortBin, ["--help"])
    check c == 0
    check "dropJunk" in o                 ## cligen renders canonical camelCase
    check "oneWay" in o
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

  test "T1: --timeout kills a long guest (143)":
    if not fileExists(SubrunBin):
      skip()
    let t0 = epochTime()
    let (_, c) = run(SubrunBin, ["--timeout", "0.3", "--", "/bin/sleep", "5"])
    let dt = epochTime() - t0
    check c == 143
    check dt >= 0.3 and dt < 2.0

  test "T2: guest exiting before --timeout keeps its code":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--timeout", "30", "--", "/bin/sh", "-c", "exit 0"])
    check c == 0

  test "T3: --timeout 0 is unlimited":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--timeout", "0", "--", "/bin/sh", "-c", "exit 0"])
    check c == 0

  test "T4: negative --timeout rejected at startup":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--timeout", "-1", "--", "/bin/true"])
    check c == 2

  test "T5: guest TERM-trap during grace exits 0 (explicit --signal TERM)":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--timeout", "0.3", "--signal", "TERM", "--",
                                 "/bin/sh", "-c", "trap 'exit 0' TERM; sleep 5"])
    check c == 0

  test "T6: --signal SIGHUP kills with 129":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--timeout", "0.3", "--signal", "SIGHUP", "--",
                                 "/bin/sleep", "5"])
    check c == 129

  test "T7: invalid --signal rejected at startup":
    if not fileExists(SubrunBin):
      skip()
    let (_, c1) = run(SubrunBin, ["--signal", "BOGUS", "--", "/bin/true"])
    check c1 == 2
    let (_, c2) = run(SubrunBin, ["--signal", "SIGKILL", "--", "/bin/true"])
    check c2 == 2

  test "T8: default graceful signal is TERM":
    if not fileExists(SubrunBin):
      skip()
    let (_, c) = run(SubrunBin, ["--timeout", "0.3", "--",
                                 "/bin/sh", "-c", "trap 'exit 0' TERM; sleep 5"])
    check c == 0

  test "T9: symlink-invoked guest keeps its caller-visible argv[0]":
    ## Regression for the argv0 symlink fix: findExe must not resolve the
    ## symlink, otherwise a multicall guest receives its target's name in
    ## argv[0] and dispatches the applet from argv[1].
    if not fileExists(SubrunBin):
      skip()
    let realSleep = findExe("sleep", followSymlinks = false)
    if realSleep.len == 0:
      skip()
    let dir = getTempDir() / ("subrun_t9_" & $getCurrentProcessId())
    createDir(dir)
    let link = dir / "sleep"
    createSymlink(realSleep, link)
    let (_, c) = run(SubrunBin, ["--", link, "1"])
    check c == 0
    removeDir(dir)

  test "T10: --title overrides the wrapper process name":
    if not fileExists(SubrunBin):
      skip()
    let (o, c) = run(SubrunBin, ["--title", "mytitle", "--",
                                 "/bin/sh", "-c", "ps -o comm= -p $PPID"])
    check c == 0
    check "mytitle" in o
