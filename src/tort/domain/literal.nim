## Scalar literal rules — the ONLY module knowing the text form of scalars (both ways).
## Spec: tort-spec-v0.1.2.md §1.1 (typing), §1.2 (escapes), §2 (productions), §6 (canon).

import std/strutils
import std/math
import consts, ast, errors

type
  QuoteContext* = enum
    qcValue                  ## bare KV value: escapes \n \\
    qcCell                   ## table cell: escapes \| \n \\
    qcItem                   ## inline-list item: escapes \, \\
    qcKey                    ## bare key ident: escapes \. \:
    qcRoot                   ## root bare value (v0.1.3): ':'/'[' would
    qcRootItem               ##   collide with KV/table line detection

# ---------------------------------------------------------------- parse side

proc isIntLit*(s: string): bool =
  ## IntLit ::= "-"? ( "0" | [1-9] [0-9]* )
  var i = 0
  if i < s.len and s[i] == '-':
    inc i
  if i >= s.len:
    return false
  if s[i] == '0':
    return i + 1 == s.len
  if s[i] notin {'1'..'9'}:
    return false
  inc i
  while i < s.len:
    if s[i] notin {'0'..'9'}:
      return false
    inc i
  true

proc isFloatLit*(s: string): bool =
  ## FloatLit ::= "-"? IntPart ( Frac Exp? | Exp )
  var i = 0
  if i < s.len and s[i] == '-':
    inc i
  let intStart = i
  if i < s.len and s[i] == '0':
    inc i
  else:
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
    if i == intStart or s[intStart] notin {'1'..'9'}:
      return false
  var sawFrac = false
  var sawExp = false
  if i < s.len and s[i] == '.':
    sawFrac = true
    inc i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
    ## D11: zero digits after the dot is legal — `100.` is a float
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    sawExp = true
    inc i
    if i < s.len and (s[i] == '-' or s[i] == '+'):
      inc i
    let eStart = i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
    if i == eStart:
      return false
  i == s.len and (sawFrac or sawExp)

proc escapeSet(ctx: QuoteContext): set[char] =
  case ctx
  of qcValue, qcRoot: {'n', '\\', ','}   ## \, allowed per spec §2 note 2
  of qcCell: {'|', 'n', '\\'}
  of qcItem, qcRootItem: {',', '\\'}
  of qcKey: {'.', ':'}

proc unescapeChar(c: char): char =
  case c
  of 'n': '\n'
  else: c                            ## \\ \| \, \. \: map to the char itself

proc unescapeBare*(s: string; ctx: QuoteContext; line, col: int): string =
  ## Bare-token unescape with the context escape set (spec §1.2).
  let valid = escapeSet(ctx)
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == EscapeChar:
      if i + 1 >= s.len or s[i + 1] notin valid:
        raiseErr(ekBadEscape, "bad escape in " & $ctx & " at offset " & $i, line, col + i)
      result.add unescapeChar(s[i + 1])
      inc i, 2
    else:
      result.add s[i]
      inc i

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc utf8(cp: int): string =
  if cp < 0x80:
    result = $chr(cp)
  elif cp < 0x800:
    result = $chr(0xC0 or (cp shr 6)) & $chr(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result = $chr(0xE0 or (cp shr 12)) & $chr(0x80 or ((cp shr 6) and 0x3F)) &
             $chr(0x80 or (cp and 0x3F))
  else:
    result = $chr(0xF0 or (cp shr 18)) & $chr(0x80 or ((cp shr 12) and 0x3F)) &
             $chr(0x80 or ((cp shr 6) and 0x3F)) & $chr(0x80 or (cp and 0x3F))

proc isRawAt*(s: string; i: int): bool =
  ## True when the RAW fence `"""` opens at i (sole raw form since v0.1.7 D20).
  i + 3 <= s.len and s[i] == '"' and s[i + 1] == '"' and s[i + 2] == '"'

proc escFenceAt*(s: string; i: int): string =
  ## The EscapedFence opening at i, or "" (D20, v0.1.7).
  for f in EscFences:
    if i + f.len <= s.len and s[i ..< i + f.len] == f:
      return f
  ""

proc fenceAt*(s: string; i: int): string =
  ## Any fence opening at i: raw `"""` or escaped (`'''`, ``` ``` ```).
  if isRawAt(s, i):
    return RawFence
  escFenceAt(s, i)

proc findRawFence*(s: string): string =
  ## RawString fence when eligible: `"""` must not occur in s, and s must not
  ## end with '"' (closing fence would merge into a longer run — the stage-23
  ## bijection bug). "" when ineligible.
  if RawFence notin s and (s.len == 0 or s[^1] != '"'): RawFence else: ""

proc findEscFence*(s: string): string =
  ## First EscapedFence absent from s whose char s does not end with (D20).
  for f in EscFences:
    if f notin s and (s.len == 0 or s[^1] != f[0]):
      return f
  ""

proc opensString*(s: string; i: int): bool =
  ## True when s[i] opens a string token: any fence or QuoteChar.
  s[i] == QuoteChar or fenceAt(s, i).len > 0

proc parseRawAt*(s: string; start: int; line, col: int): tuple[val: string, next: int] =
  ## RawString production: verbatim content until the closing `"""`.
  ## No escape processing whatsoever (spec §2, v0.1.4).
  let contentStart = start + RawFence.len
  var i = contentStart
  while i + RawFence.len <= s.len:
    if s[i] == '\r' or s[i] == '\n':
      raiseErr(ekUnterminatedQuote, "newline inside raw string", line, col + i)
    if s[i ..< i + RawFence.len] == RawFence:
      return (s[contentStart ..< i], i + RawFence.len)
    inc i
  raiseErr(ekUnterminatedQuote, "unterminated raw string", line, col + start)

proc processEscapeAt(s: string; i: int; line, col: int; val: var string): int =
  ## s[i] == EscapeChar. Decodes one D3 hatch into val; returns next index.
  ## Shared by QuotedString and EscapedFence (D20, v0.1.7).
  if i + 1 >= s.len:
    raiseErr(ekUnterminatedQuote, "escape at end of string", line, col + i)
  let e = s[i + 1]
  case e
  of '"': val.add '"'
  of '\\': val.add '\\'
  of 'n': val.add '\n'
  of 'r': val.add '\r'
  of 't': val.add '\t'
  of 'u':
    if i + 5 >= s.len:
      raiseErr(ekBadEscape, "short \\u escape", line, col + i)
    var cp = 0
    for j in 1..4:
      let h = hexVal(s[i + 1 + j])
      if h < 0:
        raiseErr(ekBadEscape, "bad hex in \\u escape", line, col + i + 1 + j)
      cp = cp * 16 + h
    if cp in 0xD800..0xDBFF:
      ## surrogate pair: need a following \uDC00..\uDFFF
      if i + 11 >= s.len or s[i + 6] != EscapeChar or s[i + 7] != 'u':
        raiseErr(ekBadEscape, "lone high surrogate", line, col + i)
      var lo = 0
      for j in 1..4:
        let h = hexVal(s[i + 7 + j])
        if h < 0:
          raiseErr(ekBadEscape, "bad hex in \\u escape", line, col + i + 7 + j)
        lo = lo * 16 + h
      if lo notin 0xDC00..0xDFFF:
        raiseErr(ekBadEscape, "lone high surrogate", line, col + i)
      cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
      val.add utf8(cp)
      return i + 12
    elif cp in 0xDC00..0xDFFF:
      raiseErr(ekBadEscape, "lone low surrogate", line, col + i)
    val.add utf8(cp)
    return i + 6
  else:
    raiseErr(ekBadEscape, "bad escape '\\" & e & "'", line, col + i)
  i + 2

proc parseQuotedAt*(s: string; start: int; line, col: int): tuple[val: string, next: int] =
  ## QuotedString production. s[start] must be QuoteChar.
  result.val = newStringOfCap(s.len - start)
  var i = start + 1
  while i < s.len:
    let c = s[i]
    if c == QuoteChar:
      return (result.val, i + 1)
    if c == '\r' or c == '\n':
      raiseErr(ekUnterminatedQuote, "newline inside quoted string", line, col + i)
    if c == EscapeChar:
      i = processEscapeAt(s, i, line, col, result.val)
      continue
    result.val.add c
    inc i
  raiseErr(ekUnterminatedQuote, "unterminated quoted string", line, col + start)

proc parseEscFenceAt*(s: string; start: int; line, col: int): tuple[val: string, next: int] =
  ## EscapedFence production (D20, v0.1.7): D3 hatches processed, '"' is data,
  ## terminator is the SAME fence triple; literal newlines forbidden.
  let fence = escFenceAt(s, start)
  result.val = newStringOfCap(s.len - start)
  var i = start + fence.len
  while i < s.len:
    let c = s[i]
    if c == '\r' or c == '\n':
      raiseErr(ekUnterminatedQuote, "newline inside fenced string", line, col + i)
    if i + fence.len <= s.len and s[i ..< i + fence.len] == fence:
      return (result.val, i + fence.len)
    if c == EscapeChar:
      i = processEscapeAt(s, i, line, col, result.val)
      continue
    result.val.add c
    inc i
  raiseErr(ekUnterminatedQuote, "unterminated fenced string", line, col + start)

proc parseStringAt*(s: string; start: int; line, col: int): tuple[val: string, next: int] =
  ## Any string token at start: RawString | EscapedFence | QuotedString (v0.1.7).
  if isRawAt(s, start):
    return parseRawAt(s, start, line, col)
  if escFenceAt(s, start).len > 0:
    return parseEscFenceAt(s, start, line, col)
  parseQuotedAt(s, start, line, col)

proc classifyBare*(tok: string; ctx: QuoteContext; line, col: int): TtValue =
  ## Token typing rule, spec §1.1: classification on the RAW token,
  ## unescape only after the token is known to be a string.
  if tok == NullToken:
    return ttNull()
  if tok == TrueToken:
    return ttBool(true)
  if tok == FalseToken:
    return ttBool(false)
  if isIntLit(tok):
    try:
      return ttInt(parseBiggestInt(tok))
    except ValueError:
      raiseErr(ekBadLiteral, "integer literal out of int64 range: " & tok, line, col)
  if isFloatLit(tok):
    return ttFloat(parseFloat(tok))
  ttStr(unescapeBare(tok, ctx, line, col))

proc splitUnescaped*(s: string; sep: char; ctx: QuoteContext; line, col: int): seq[string] =
  ## Split on separators NOT introduced by EscapeChar (spec disambiguation).
  ## Quoted regions are skipped whole (a separator inside "..." is data).
  ## Segments keep their escapes; unescaping is classifyBare's job.
  let valid = escapeSet(ctx)
  result = @[""]
  var i = 0
  while i < s.len:
    if isRawAt(s, i):
      ## raw region: verbatim copy, no escape awareness (v0.1.4)
      result[^1].add RawFence
      i += 3
      while i < s.len:
        if isRawAt(s, i):
          result[^1].add RawFence
          i += 3
          break
        result[^1].add s[i]
        inc i
      continue
    let ef = escFenceAt(s, i)
    if ef.len > 0:
      ## escaped-fence region: escape-aware copy, fence terminator (D20)
      result[^1].add ef
      i += ef.len
      while i < s.len:
        if i + ef.len <= s.len and s[i ..< i + ef.len] == ef:
          result[^1].add ef
          i += ef.len
          break
        result[^1].add s[i]
        if s[i] == EscapeChar and i + 1 < s.len:
          result[^1].add s[i + 1]
          i += 2
          continue
        inc i
      continue
    if s[i] == QuoteChar:
      ## copy the quoted region verbatim
      result[^1].add s[i]
      inc i
      while i < s.len:
        result[^1].add s[i]
        if s[i] == EscapeChar and i + 1 < s.len:
          result[^1].add s[i + 1]
          i += 2
          continue
        if s[i] == QuoteChar:
          inc i
          break
        inc i
      continue
    if s[i] == EscapeChar:
      if i + 1 >= s.len or s[i + 1] notin valid:
        raiseErr(ekBadEscape, "bad escape in " & $ctx & " at offset " & $i, line, col + i)
      result[^1].add s[i]
      result[^1].add s[i + 1]
      inc i, 2
    elif s[i] == sep:
      result.add ""
      inc i
    else:
      result[^1].add s[i]
      inc i

# ---------------------------------------------------------------- render side

proc expandExponent(s: string): string =
  ## "1.5e-7" → "0.00000015"; assumes a valid Nim exponent float string.
  let ePos = s.find({'e', 'E'})
  let mantissa = s[0 ..< ePos]
  let exp = parseInt(s[ePos + 1 .. ^1])
  var neg = false
  var digits = mantissa
  if digits.len > 0 and digits[0] == '-':
    neg = true
    digits = digits[1 .. ^1]
  let dotPos = digits.find('.')
  let pointPos = if dotPos < 0: digits.len else: dotPos
  if dotPos >= 0:
    digits.delete(dotPos .. dotPos)
  let newPoint = pointPos + exp
  var body: string
  if newPoint <= 0:
    body = "0." & repeat('0', -newPoint) & digits
  elif newPoint >= digits.len:
    body = digits & repeat('0', newPoint - digits.len)
  else:
    body = digits[0 ..< newPoint] & "." & digits[newPoint .. ^1]
  if '.' in body:
    body = body.strip(leading = false, chars = {'0'})
    if body.endsWith('.'):
      body.setLen(body.len - 1)
  if neg: "-" & body else: body

proc plainToExp(s: string): string =
  ## "0.0000001" → "1e-7"; "-0.0000120" → "-1.2e-5". Input is Nim's plain form.
  var neg = false
  var body = s
  if body[0] == '-':
    neg = true
    body = body[1 .. ^1]
  let frac = body[2 .. ^1]                 ## strip "0."
  var zeros = 0
  while zeros < frac.len and frac[zeros] == '0':
    inc zeros
  var digits = frac[zeros .. ^1]
  digits = digits.strip(leading = false, chars = {'0'})
  let mantissa = if digits.len == 1: digits
                 else: digits[0] & "." & digits[1 .. ^1]
  (if neg: "-" else: "") & mantissa & "e" & $(-(zeros + 1))

proc normalizeExponent(s: string): string =
  ## Nim prints "1e+21" / "1e-07"; canon is "1e21" / "1e-7" (D2).
  let ePos = s.find({'e', 'E'})
  var mantissa = s[0 ..< ePos]
  if '.' in mantissa:
    mantissa = mantissa.strip(leading = false, chars = {'0'})
    if mantissa.endsWith('.'):
      mantissa.setLen(mantissa.len - 1)
  var expStr = s[ePos + 1 .. ^1]
  var expNeg = false
  if expStr.len > 0 and expStr[0] == '+':
    expStr = expStr[1 .. ^1]
  elif expStr.len > 0 and expStr[0] == '-':
    expNeg = true
    expStr = expStr[1 .. ^1]
  expStr = expStr.strip(leading = true, trailing = false, chars = {'0'})
  if expStr.len == 0:
    expStr = "0"
  mantissa & "e" & (if expNeg: "-" else: "") & expStr

proc canonFloat*(f: float64): string =
  ## Canonical float form, spec §6.1 (D2). Floats always keep a dot or an
  ## exponent so the type survives decoding (pending fork D11).
  if f == 0.0:
    return "0."                              ## float zero keeps its type marker (D11)
  if f != f or f == 1.0/0.0 or f == -1.0/0.0:
    raiseErr(ekEncodeImpossible, "NaN/Inf are not representable in TT")
  var s = $f                                 ## Nim shortest round-trip form
  let af = abs(f)
  if 'e' in s or 'E' in s:
    if af >= NoExpLow and af < NoExpHigh:
      s = expandExponent(s)
    else:
      s = normalizeExponent(s)
  else:
    if af < NoExpLow:
      s = plainToExp(s)                      ## Nim stays plain below 1e-6
    elif '.' in s:
      s = s.strip(leading = false, chars = {'0'})
      if s.endsWith('.'):
        s.setLen(s.len - 1)
  if '.' notin s and 'e' notin s and 'E' notin s:
    s.add "."                                ## trailing-dot float type marker (D11)
  s

proc needsQuoting*(s: string; ctx: QuoteContext): bool =
  ## Spec §6.2: quote only when required.
  if ctx != qcCell and s.len == 0:
    return true                              ## empty cell stays bare (D6)
  if s.len > 0:
    if s == NullToken or s == TrueToken or s == FalseToken:
      return true
    if ctx in {qcValue, qcRoot} and (s == EmptyObjToken or s == EmptyArrToken):
      return true                            ## would decode as a container (v0.1.2)
    if ctx == qcRoot and s == DocSepToken:
      return true                            ## would decode as DocSep (v0.1.3)
    if isIntLit(s) or isFloatLit(s):
      return true
    if s[0] in {' ', '\t'} or s[^1] in {' ', '\t'}:
      return true
    if s[0] in {'-', '+', CommentChar}:
      return true
  for c in s:
    if c == QuoteChar or c == EscapeChar or c < ' ':
      return true
    if ctx in {qcCell} and c == PipeChar:
      return true
    if ctx in {qcItem, qcValue, qcRoot, qcRootItem} and c == CommaChar:
      ## qcValue: a bare comma would re-decode as InlineList (bijection)
      return true
    if ctx in {qcRoot, qcRootItem} and c in {':', '['}:
      ## root bare line: ':'/'[' would trigger KV/table detection (v0.1.3)
      return true
  false

proc quote*(s: string): string =
  ## QuotedString emission, spec §2 QEscape set.
  result = newStringOfCap(s.len + 2)
  result.add QuoteChar
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if c < ' ':
        const hexDigits = "0123456789abcdef"
        result.add "\\u00" & hexDigits[ord(c) shr 4] & hexDigits[ord(c) and 0xF]
      else:
        result.add c
  result.add QuoteChar

proc escapeCount(s: string): int =
  ## How many chars quote() would have to escape.
  for c in s:
    if c == '"' or c == '\\' or c < ' ':
      inc result

proc squashWs*(s: string): string =
  ## LOSSY whitespace compression (D18, v0.1.6, opt-in flag only):
  ## 1. trailing spaces/tabs stripped on every line;
  ## 2. gcd of pure-space leading indents >= 2 → each gcd-unit becomes one '\t'
  ##    (lines with tab/mixed indent are excluded from gcd and left alone);
  ## 3. runs of more than MaxNewlineRun '\n' collapse to MaxNewlineRun.
  ## Breaks bijection by design — never enabled by default.
  if s.len == 0:
    return s
  var ls = s.split('\n')
  for i in 0 ..< ls.len:
    ls[i] = ls[i].strip(leading = false, chars = {' ', '\t'})
  var g = 0
  for l in ls:
    if l.len == 0 or l[0] != ' ':
      continue
    var n = 0
    while n < l.len and l[n] == ' ':
      inc n
    if n < l.len and l[n] == '\t':
      continue                             ## mixed indent — excluded
    g = gcd(g, n)
  if g >= 2:
    for i in 0 ..< ls.len:
      var n = 0
      while n < ls[i].len and ls[i][n] == ' ':
        inc n
      if n >= g and (n == ls[i].len or ls[i][n] != '\t'):
        ls[i] = repeat('\t', n div g) & ls[i][n .. ^1]
  result = newStringOfCap(s.len)
  var nl = 0                               ## consecutive '\n' emitted/would-emit
  for i, l in ls:
    if i > 0:
      inc nl
      if nl <= MaxNewlineRun:
        result.add '\n'
    if l.len > 0:
      result.add l
      nl = 0

proc escapeFenced(s: string): string =
  ## EscapedFence emission (D20): like quote() but '"' is free.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if c < ' ':
        const hexDigits = "0123456789abcdef"
        result.add "\\u00" & hexDigits[ord(c) shr 4] & hexDigits[ord(c) and 0xF]
      else:
        result.add c

proc quoteCount(s: string): int =
  for c in s:
    if c == '"':
      inc result

proc renderString*(s: string; ctx: QuoteContext): string =
  ## Form choice, spec §6.2 (v0.1.7 D20): bare → raw """ (dense escapes,
  ## no newlines) → EscapedFence '''/``` ('"' free, needs >= RawMinEscapes
  ## double-quotes to pay off) → QuotedString.
  if ctx == qcCell and s.len == 0:
    return ""                                ## bare empty cell (D6)
  if not needsQuoting(s, ctx):
    return s
  let esc = escapeCount(s)
  if '\n' notin s and '\r' notin s:
    let rf = findRawFence(s)
    if rf.len > 0 and esc >= max(RawMinEscapes, s.len div RawDensityDiv):
      return rf & s & rf
  if quoteCount(s) >= RawMinEscapes:
    let ef = findEscFence(s)
    if ef.len > 0:
      return ef & escapeFenced(s) & ef
  quote(s)

proc renderScalar*(v: TtValue; ctx: QuoteContext): string =
  ## Scalar → text. Lists/objects are the encoder's job (shape decisions).
  case v.kind
  of tkNull: NullToken
  of tkBool: (if v.bVal: TrueToken else: FalseToken)
  of tkInt: $v.iVal
  of tkFloat: canonFloat(v.fVal)
  of tkString: renderString(v.sVal, ctx)
  of tkList, tkObject:
    raiseErr(ekEncodeImpossible, "renderScalar got a container")

proc renderKey*(k: string): string =
  ## Bare when every char is in BareIdentChars (and non-empty), else quoted.
  if k.len > 0:
    var bare = true
    for c in k:
      if c notin BareIdentChars:
        bare = false
        break
    if bare:
      return k
  quote(k)
