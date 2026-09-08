## tort CLI — delivery layer (L5). Contains ONLY: arg dispatch, one central
## error→exit-code map (E2), fd wiring. cligen is confined to this file (D7).

import std/[os, posix, tables]
import cligen
import tort/tort
import tort/adapters/[fdio, stdin_chunks, stdout_sink, yyjson_bridge]

proc exitCodeOf(k: TortErrorKind): int =
  ## The single exit-code map: io → 1, everything else → 2 (L5 decision).
  if k == ekIo: 1 else: 2

proc guarded(body: proc()) =
  ## Central TortError handler: stderr "line:col kind: msg", then exit map.
  discard signal(SIGPIPE, SIG_IGN)     ## EPIPE must surface as an error, not death
  try:
    body()
  except TortError as e:
    var msg: string
    if e.line > 0:
      msg = $e.line & ":" & $e.col & " "
    msg.add $e.errKind & ": " & e.msg
    stderr.writeLine msg
    quit(exitCodeOf(e.errKind))

proc tryParseJsonFrag(s: string): TortValue =
  ## --one-way helper: full-string JSON parse, nil when not valid JSON.
  try:
    parseJson(s)
  except TortError:
    nil

proc cmdEncode(oneWay = false) =
  ## stdin: one JSON document → stdout: Tort.
  ## --one-way is LOSSY (D18+D19): JSON-in-string unpack, gcd-indent→tabs,
  ## trailing ws strip, \n-runs→3.
  guarded(proc() =
    let tp: TryJsonParse = if oneWay: tryParseJsonFrag else: nil
    writeAll(1, encode(parseJson(readAll(0)), tp)))

proc cmdDecode(nonStrict = false) =
  ## stdin: Tort text → stdout: compact JSON. Strict by default (D1).
  guarded(proc() =
    writeAll(1, toJsonText(decode(readAll(0), strict = not nonStrict))))

proc cmdStream(dropJunk = false; oneWay = true) =
  ## stdin: stream of JSON docs (+ junk) → stdout: Tort per doc, real-time.
  ## DEFAULT command (D21'). --one-way is ON here by default (LOSSY, D18+D19):
  ## JSON-in-string unpack, gcd-indent→tabs, trailing ws strip, \n-runs→3.
  ## --one-way=false restores the bijective stream codec.
  guarded(proc() =
    var src = StdinChunks()
    var sink = StdoutSink()
    var wire = YySplitter()
    let tp: TryJsonParse = if oneWay: tryParseJsonFrag else: nil
    discard streamRun(src, sink, wire, dropJunk, tp))

const StreamHelp = {
  "dropJunk": "Drop undecodable junk instead of passing it through verbatim",
  "oneWay": "Lossy payload transform (D18+D19); --one-way=false restores the bijective codec",
}.toTable

when isMainModule:
  ## D21': bare `tort` (or a flags-only invocation) = stream, the default
  ## command. One parser for the whole CLI (T29): flags-only args are
  ## dispatched to cmdStream by cligen itself; subcommands go to dispatchMulti.
  cgParseErrorExitCode = 2   ## CLI syntax errors exit 2, like the codec (E2)
  let argv = commandLineParams()
  if argv.len == 0:
    cmdStream()
  elif argv[0][0] == '-':
    dispatch(cmdStream, cmdName = "tort", help = StreamHelp)
  else:
    dispatchMulti(
      [cmdEncode, cmdName = "encode"],
      [cmdDecode, cmdName = "decode"],
      [cmdStream, cmdName = "stream"]
    )
