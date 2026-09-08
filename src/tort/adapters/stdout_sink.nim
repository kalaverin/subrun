## JsonSink over stdout (fd 1). Buffer per doc; flush() pushes immediately —
## in stream mode flush timing IS the protocol (L5.7: no stdio buffering).

import fdio

type
  StdoutSink* = object
    buf: string

proc emit*(s: var StdoutSink; tort: string) =
  s.buf.add tort

proc junk*(s: var StdoutSink; raw: string) =
  s.buf.add raw

proc flush*(s: var StdoutSink) =
  if s.buf.len > 0:
    writeAll(1, s.buf)
    s.buf.setLen(0)
