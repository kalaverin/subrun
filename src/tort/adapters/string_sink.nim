## JsonSink accumulating into a string — library/embedder use (D22').
## flush() is a no-op: there is no downstream fd to push to; take() drains.

type
  StringSink* = object
    buf: string

proc emit*(s: var StringSink; tort: string) =
  s.buf.add tort

proc junk*(s: var StringSink; raw: string) =
  s.buf.add raw

proc flush*(s: var StringSink) =
  discard

proc take*(s: var StringSink): string =
  ## Drain the accumulated output.
  result = s.buf
  s.buf.setLen(0)
