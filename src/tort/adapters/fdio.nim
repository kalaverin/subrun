## Raw fd I/O helpers — direct posix, no FILE* buffering (L5 decisions).
## Blocking fds only; partial-write loop is mandatory; EINTR retried here;
## EPIPE → silent quit(0) ("tort encode | head -1" is not an error, T3 generalized).

import posix
import ../domain/errors
import ../core/consts

proc writeAll*(fd: cint; s: string) =
  var off = 0
  while off < s.len:
    let n = posix.write(fd, addr s[off], s.len - off)
    if n < 0:
      let e = errno
      if e == EINTR:
        continue
      if e == EPIPE:
        quit(0)
      raiseErr(ekIo, "write failed: errno " & $e)
    off += n

proc readChunk*(fd: cint; size: int): tuple[text: string, atEof: bool] =
  result.text = newString(size)
  while true:
    let n = posix.read(fd, addr result.text[0], size)
    if n < 0:
      if errno == EINTR:
        continue
      raiseErr(ekIo, "read failed: errno " & $errno)
    if n == 0:
      return ("", true)
    result.text.setLen(n)
    return (result.text, false)

proc readAll*(fd: cint): string =
  while true:
    let (text, atEof) = readChunk(fd, BatchReadChunk)
    if atEof:
      return
    result.add text
