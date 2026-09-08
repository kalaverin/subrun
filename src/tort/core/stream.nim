## Stream use case: chunked JSON-docs-and-junk in → per-doc TT out (tolerant, D1-flip).
## Memory is bounded by the largest single document, not the stream length (D5).
## EPIPE is NOT handled here — that is the sink adapter's boundary (L4/L5).

import std/strutils
import ../domain/consts
import ../domain/errors
import encoder
import ports

type
  StreamStats* = object
    docsEmitted*: int
    junkChunks*: int
    docsFailed*: int

proc pumpBuf*[K: JsonSink; W: JsonWire](
    buf: var string; sink: var K; wire: var W; dropJunk: bool;
    tryParse: TryJsonParse; eof: bool; stats: var StreamStats) =
  ## Inner stream loop, shared by streamRun (fd path) and TtFilter (library
  ## path, D22'): process buf until NeedMore/exhaustion. eof=true enables the
  ## EOF-tail rule (a partial document becomes junk).
  while buf.len > 0:
    let r = wire.trySplit(buf)
    case r.state
    of ssNeedMore:
      if eof:
        ## tail at EOF: partial document — passthrough verbatim or drop (T3)
        inc stats.junkChunks
        if not dropJunk:
          sink.junk(buf)
        buf = ""
      break
    of ssInvalid:
      ## resync (delta D12): junk only up to the first newline —
      ## a later valid doc in the same buffer must not be swallowed.
      let nl = buf.find('\n')
      let piece = if nl >= 0: buf[0 .. nl] else: buf
      buf = if nl >= 0: buf[nl + 1 .. ^1] else: ""
      inc stats.junkChunks
      if not dropJunk:
        sink.junk(piece)
    of ssDoc:
      buf = r.rest
      try:
        ## D13: DocSep between docs — stream output of N docs is a valid
        ## v0.1.3 multi-section document, `tort stream | tort decode` = JSON array.
        if stats.docsEmitted > 0:
          sink.emit(DocSepToken & "\n")
        sink.emit(encode(wire.parseDoc(r.doc), tryParse))
        inc stats.docsEmitted
      except TtError:
        ## valid JSON but unencodable (e.g. NaN) — tolerant mode: junk it
        inc stats.docsFailed
        if not dropJunk:
          sink.junk(r.doc)
      sink.flush()

proc streamRun*[S: ChunkSource; K: JsonSink; W: JsonWire](
    src: var S; sink: var K; wire: var W; dropJunk: bool;
    tryParse: TryJsonParse = nil): StreamStats =
  var buf = ""
  var eof = false
  while not eof:
    let ch = src.next()
    eof = ch.atEof
    buf.add ch.text
    pumpBuf(buf, sink, wire, dropJunk, tryParse, eof, result)
  if buf.len == 0:
    sink.flush()
