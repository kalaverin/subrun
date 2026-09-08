## Line splitter — the only place that splits on Newline (spec §2: "\r\n" | "\n").
## Line numbers are 1-based; they feed line:col error positions.
## No filtering here: blank/comment decisions live next to scope logic (G4).

type
  TortLine* = tuple[num: int, text: string]

proc splitLines*(src: string): seq[TortLine] =
  var start = 0
  var num = 1
  var i = 0
  while i < src.len:
    if src[i] == '\n':
      var text = src[start ..< i]
      if text.len > 0 and text[^1] == '\r':
        text.setLen(text.len - 1)
      result.add (num, text)
      inc num
      start = i + 1
    inc i
  if start < src.len:
    ## EOF terminates the final line (G9); \r-trim applies there too.
    var text = src[start ..< src.len]
    if text.len > 0 and text[^1] == '\r':
      text.setLen(text.len - 1)
    result.add (num, text)
