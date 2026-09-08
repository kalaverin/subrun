## tt CLI — delivery layer (L5). Contains ONLY: arg dispatch, one central
## error→exit-code map (E2), fd wiring. cligen is confined to this file (D7).

import std/[os, posix]
import cligen
import tort/tort
import tort/adapters/[fdio, stdin_chunks, stdout_sink, yyjson_bridge]

proc exitCodeOf(k: TtErrKind): int =
  ## The single exit-code map: io → 1, everything else → 2 (L5 decision).
  if k == ekIo: 1 else: 2

proc guarded(body: proc()) =
  ## Central TtError handler: stderr "line:col kind: msg", then exit map.
  discard signal(SIGPIPE, SIG_IGN)     ## EPIPE must surface as an error, not death
  try:
    body()
  except TtError as e:
    var msg: string
    if e.line > 0:
      msg = $e.line & ":" & $e.col & " "
    msg.add $e.errKind & ": " & e.msg
    stderr.writeLine msg
    quit(exitCodeOf(e.errKind))

proc tryParseJsonFrag(s: string): TtValue =
  ## --one-way helper: full-string JSON parse, nil when not valid JSON.
  try:
    parseJson(s)
  except TtError:
    nil

proc cmdEncode(oneWay = false) =
  ## stdin: one JSON document → stdout: TT.
  ## --one-way is LOSSY (D18+D19): JSON-in-string unpack, gcd-indent→tabs,
  ## trailing ws strip, \n-runs→3.
  guarded(proc() =
    let tp: TryJsonParse = if oneWay: tryParseJsonFrag else: nil
    writeAll(1, encode(parseJson(readAll(0)), tp)))

proc cmdDecode(nonStrict = false) =
  ## stdin: TT text → stdout: compact JSON. Strict by default (D1).
  guarded(proc() =
    writeAll(1, toJsonText(decode(readAll(0), strict = not nonStrict))))

proc cmdStream(dropJunk = false; oneWay = true) =
  ## stdin: stream of JSON docs (+ junk) → stdout: TT per doc, real-time.
  ## DEFAULT command (D21'). --one-way is ON here by default (LOSSY, D18+D19):
  ## JSON-in-string unpack, gcd-indent→tabs, trailing ws strip, \n-runs→3.
  ## --one-way=false restores the bijective stream codec.
  guarded(proc() =
    var src = StdinChunks()
    var sink = StdoutSink()
    var wire = YySplitter()
    let tp: TryJsonParse = if oneWay: tryParseJsonFrag else: nil
    discard streamRun(src, sink, wire, dropJunk, tp))

const streamUsage = "usage: tort [stream] [--drop-junk] [--one-way[=false]] | tort encode [--one-way] | tt decode [--non-strict]"

when isMainModule:
  ## D21': bare `tt` (or flags-only invocation) = stream, the default command.
  if paramCount() == 0:
    cmdStream()
  elif paramStr(1)[0] == '-':
    ## flags-only: only stream's flags are legal in the default command
    var dropJunk = false
    var oneWay = true
    for a in commandLineParams():
      case a
      of "--drop-junk": dropJunk = true
      of "--one-way": oneWay = true
      of "--one-way=false", "--one-way=0", "--one-way=no", "--one-way=off":
        oneWay = false
      of "-h", "--help":
        echo streamUsage
        quit(0)
      else:
        stderr.writeLine "unknown stream flag: " & a
        stderr.writeLine streamUsage
        quit(2)
    cmdStream(dropJunk = dropJunk, oneWay = oneWay)
  else:
    dispatchMulti(
      [cmdEncode, cmdName = "encode"],
      [cmdDecode, cmdName = "decode"],
      [cmdStream, cmdName = "stream"]
    )
