## TtFilter — embeddable incremental JSON-stream → TT filter (D22').
## Composition root for library use: owns the wire, sink, and rolling buffer.
## Pure in-memory: no fds, no stdio. Usage:
##
##   var f = initTtFilter()
##   out.add f.feed(chunk)   # per stdout chunk
##   out.add f.finish()      # at EOF
##
## Output of N docs is a valid multi-section document (D13): DocSep lines are
## emitted between docs, so `feed/finish` output decodes as a JSON array.

import domain/[ast, errors]
import core/[stream, encoder]
import adapters/[string_sink, yyjson_bridge]

type
  TtFilter* = object
    wire: YySplitter
    sink: StringSink
    buf: string
    stats: StreamStats
    dropJunk: bool
    tryParse: TryJsonParse

proc oneWayParse(s: string): TtValue =
  ## Full-string JSON parse, nil when not valid JSON (D19).
  try:
    parseJson(s)
  except TtError:
    nil

proc initTtFilter*(oneWay = true; dropJunk = false): TtFilter =
  ## oneWay (default ON, LOSSY per D18+D19): JSON-in-string unpack + whitespace
  ## squash. dropJunk (default OFF): junk is passed through verbatim.
  result.wire = YySplitter()
  result.dropJunk = dropJunk
  if oneWay:
    result.tryParse = oneWayParse

proc feed*(f: var TtFilter; chunk: string): string =
  ## Push a text chunk; returns TT output ready so far (incl. junk passthrough).
  f.buf.add chunk
  pumpBuf(f.buf, f.sink, f.wire, f.dropJunk, f.tryParse, false, f.stats)
  f.sink.take()

proc finish*(f: var TtFilter): string =
  ## EOF: the partial tail is junked/passed through per policy; drains output.
  pumpBuf(f.buf, f.sink, f.wire, f.dropJunk, f.tryParse, true, f.stats)
  f.sink.take()

proc stats*(f: var TtFilter): StreamStats =
  f.stats
