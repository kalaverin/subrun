## Stream layer — TortFilter (incremental JSON-stream -> Tort, D22') and the
## pumpBuf resync/junk rules (spec §9, D5/D12/D13).

import unittest2
import std/strutils
import tort/tort
import helpers

suite "stream: TortFilter documents":
  test "single document":
    var f = initTortFilter(oneWay = false)
    var outp = f.feed("""{"a": 1}""")     ## no trailing newline: nothing buffered
    outp.add f.finish()
    checkJson decode(outp, strict = true), """{"a":1}"""
    check f.stats.docsEmitted == 1
    check f.stats.junkChunks == 0

  test "two documents get DocSep (D13)":
    var f = initTortFilter(oneWay = false)
    var outp = f.feed("""{"a": 1}""" & "\n")
    outp.add f.feed("""{"b": 2}""" & "\n")
    outp.add f.finish()
    checkJson decode(outp, strict = true), """[{"a":1},{"b":2}]"""
    check f.stats.docsEmitted == 2

  test "document split across chunks":
    var f = initTortFilter(oneWay = false)
    check f.feed("""{"a":""") == ""
    let outp = f.feed(" 1}\n")
    check "a: 1" in outp
    check f.stats.docsEmitted == 1

suite "stream: junk handling (spec §9)":
  test "junk line passes through verbatim, following doc still decodes":
    var f = initTortFilter(oneWay = false)
    let outp = f.feed("not json\n{\"a\": 1}\n")
    check "not json" in outp
    check "a: 1" in outp
    check f.stats.junkChunks == 1
    check f.stats.docsEmitted == 1

  test "dropJunk removes junk from output":
    var f = initTortFilter(oneWay = false, dropJunk = true)
    let outp = f.feed("not json\n{\"a\": 1}\n")
    check "not json" notin outp
    check "a: 1" in outp
    check f.stats.junkChunks == 1

  test "resync junks only up to the first newline (D12)":
    var f = initTortFilter(oneWay = false)
    let outp = f.feed("!!bad!! {\"not\": \"a doc\"}\n{\"ok\": true}\n")
    check "!!bad!!" in outp
    check "ok: +" in outp                 ## booleans render as +/- (consts.nim)
    check f.stats.docsEmitted == 1

  test "EOF partial tail is junked (T3)":
    var f = initTortFilter(oneWay = false)
    discard f.feed("""{"a":""")
    let outp = f.finish()
    check """{"a":""" in outp
    check f.stats.junkChunks == 1
    check f.stats.docsEmitted == 0

  test "buffer overflow flushes verbatim as junk and self-heals":
    var f = initTortFilter(oneWay = false, maxBuffered = 16)
    ## an incomplete document over the cap is flushed in the SAME feed
    let out1 = f.feed("""{"incomplete": "still going...""")
    check "still going" in out1           ## overflow flushed verbatim
    let out2 = f.feed(" more bytes past the cap")
    check "more bytes" in out2            ## non-JSON head junks immediately
    let out3 = f.feed("{\"ok\": 1}\n")     ## resyncs on the next doc
    check "ok: 1" in out3
    check f.stats.junkChunks >= 1
    check f.stats.docsEmitted == 1
