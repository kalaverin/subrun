## Tort → TortValue decoder. Recursive descent, one proc per grammar production.
## Spec: tort-spec-v0.1.2.md §2 (grammar), §3 (trie scoping), §4 (tables), §7 (strict).

import std/[strutils, tables]
import ../domain/[ast, errors, literal, consts]
import lines as ttLines

type
  KeyEnd = tuple[delim: char, pos: int]   ## first structural delimiter after the key

  DecodeState = object
    root: TortValue
    strict: bool
    slots: Table[string, int]             ## joined full path → slot in parent oVal

proc isBlank(text: string): bool =
  for c in text:
    if c notin {' ', '\t'}:
      return false
  true

proc isComment(text: string): bool =
  ## G4-б: comments may be indented.
  for c in text:
    if c in {' ', '\t'}:
      continue
    return c == CommentChar
  false

proc findKeyEnd(text: string; line: int): KeyEnd =
  ## Walk the key region respecting key escapes (\., \:) and quoted idents.
  ## Stops at the first bare ':' (KV line) or bare '[' (table header).
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == EscapeChar:
      if i + 1 < text.len:
        i += 2
        continue
      raiseErr(ekBadEscape, "dangling escape in key", line, i + 1)
    if opensString(text, i):
      i = parseStringAt(text, i, line, 1).next
      continue
    if c == ColonChar or c == '[':
      return (c, i)
    inc i
  ('\0', -1)

proc parseIdentAt(s: string; start: int; line: int): tuple[val: string, next: int] =
  ## Ident production: bare (unescape \. \:) or quoted.
  if start < s.len and opensString(s, start):
    return parseStringAt(s, start, line, 1)
  var i = start
  while i < s.len:
    let c = s[i]
    if c == EscapeChar:
      i += 2                                ## dangling escape caught by unescapeBare
      continue
    if c in {DotChar, ColonChar, '|', '[', ']', '{', '}', ','}:
      break
    inc i
  (unescapeBare(s[start ..< i], qcKey, line, start + 1), i)

proc resolveKey(keyTok: string; line: int): tuple[dots: int, segments: seq[string]] =
  ## KvKey/TableKey: leading dots + unescaped-dot split of the tail.
  var dots = 0
  while dots < keyTok.len and keyTok[dots] == DotChar:
    inc dots
  let tail = keyTok[dots .. ^1]
  if tail.len == 0:
    raiseErr(ekBadLiteral, "key is dots only", line, 1)
  result.dots = dots
  var i = 0
  while i < tail.len:
    let (ident, next) = parseIdentAt(tail, i, line)
    if ident.len == 0 and not opensString(tail, i):
      raiseErr(ekBadLiteral, "empty key segment", line, dots + i + 1)
    result.segments.add ident
    if next >= tail.len:
      break
    if tail[next] != DotChar:
      raiseErr(ekBadLiteral, "unexpected character in key", line, dots + next + 1)
    i = next + 1
    if i >= tail.len:
      raiseErr(ekBadLiteral, "trailing dot in key", line, dots + i)

proc applyScope(scope: var seq[string]; dots: int; segments: seq[string]; line: int) =
  ## Trie-scoping state transition, spec §3.1.
  if dots == 0:
    scope.setLen(0)
  else:
    if dots > scope.len:
      raiseErr(ekBacktrackUnderflow,
               "backtrack depth " & $dots & " exceeds scope depth " & $scope.len, line, 1)
    scope.setLen(scope.len - dots)
  for s in segments:
    scope.add s

proc joinPath(path: seq[string]): string =
  ## FinalKey joining per spec §3.1. Separated segments are unambiguous here:
  ## this is an internal index key, not user-facing text.
  path.join("\u0001")

proc insertAt(st: var DecodeState; path: seq[string]; val: TortValue; line: int) =
  ## Insert val at path. Duplicate FinalKey: strict → ekDuplicateKey;
  ## non-strict → LWW (spec §3.2). Path-through-scalar is the same class.
  ## Index tables keyed by joined path keep this O(path), not O(siblings).
  var node = st.root
  for i in 0 ..< path.len - 1:
    let objKey = joinPath(path[0 .. i])
    var child: TortValue
    if st.slots.hasKey(objKey):
      child = node.oVal[st.slots[objKey]][1]
      if child.kind != tkObject:
        if st.strict:
          raiseErr(ekDuplicateKey, "key path conflicts with a scalar: " & path[i], line, 1)
        child = ttObject(@[])                 ## LWW: scalar replaced by object
        node.oVal[st.slots[objKey]][1] = child
    else:
      child = ttObject(@[])
      st.slots[objKey] = node.oVal.len
      node.oVal.add (path[i], child)
    node = child
  let leafKey = joinPath(path)
  if st.slots.hasKey(leafKey):
    if st.strict:
      raiseErr(ekDuplicateKey, "duplicate key: " & path[^1], line, 1)
    node.oVal[st.slots[leafKey]][1] = val     ## LWW keeps position
    return
  st.slots[leafKey] = node.oVal.len
  node.oVal.add (path[^1], val)

proc parseValue(raw: string; line: int; colBase: int): TortValue =
  ## ValueLine production (v0.1.3 order): the quote-aware comma split comes
  ## FIRST — a list of quoted items starts with '"' too. Containers and single
  ## quoted strings are whole-value forms.
  let trimmed = raw.strip(leading = false, chars = {' ', '\t'})   ## spec §6.3
  if trimmed == EmptyObjToken:
    return ttObject(@[])
  if trimmed == EmptyArrToken:
    return ttList(@[])
  var items = splitUnescaped(trimmed, CommaChar, qcItem, line, colBase)
  if items.len > 1:
    if items[^1].len == 0:
      items.setLen(items.len - 1)            ## D7: one trailing comma is legal
    var vals: seq[TortValue] = @[]
    for it in items:
      if it.len == 0:
        raiseErr(ekBadLiteral, "empty element in inline list", line, colBase)
      if opensString(it, 0):
        let (val, next) = parseStringAt(it, 0, line, colBase)
        if next != it.len:
          raiseErr(ekBadLiteral, "trailing content after quoted list item", line, colBase)
        vals.add ttStr(val)
      else:
        vals.add classifyBare(it, qcItem, line, colBase)
    return ttList(vals)
  ## single value
  if trimmed.len > 0 and opensString(trimmed, 0):
    let (val, next) = parseStringAt(trimmed, 0, line, colBase)
    if next != trimmed.len:
      raiseErr(ekBadLiteral, "trailing content after quoted string", line, colBase + next)
    return ttStr(val)
  classifyBare(trimmed, qcValue, line, colBase)

proc skipWs(text: string; i: int): int =
  var j = i
  while j < text.len and text[j] in {' ', '\t'}:
    inc j
  j

proc parseKv(text: string; line: int; colonPos: int; st: var DecodeState;
             scope: var seq[string]) =
  let keyTok = text[0 ..< colonPos]
  let (dots, segments) = resolveKey(keyTok, line)
  let valStart = skipWs(text, colonPos + 1)
  let val = parseValue(text[valStart .. ^1], line, valStart + 1)
  applyScope(scope, dots, segments, line)
  insertAt(st, scope, val, line)

proc parseHeader(text: string; line: int; bracketPos: int): tuple[
    dots: int, name: seq[string], count: int, keyed: bool, columns: seq[string]] =
  ## TableHeader / KeyedHeader production (spec §2).
  let keyTok = text[0 ..< bracketPos]
  let (dots, segments) = resolveKey(keyTok, line)
  result.dots = dots
  result.name = segments
  var i = bracketPos + 1
  let nStart = i
  while i < text.len and text[i] in {'0'..'9'}:
    inc i
  if i == nStart:
    raiseErr(ekBadLiteral, "missing row count in table header", line, i + 1)
  try:
    result.count = parseInt(text[nStart ..< i])
  except ValueError:
    raiseErr(ekBadLiteral, "row count out of range", line, nStart + 1)
  if i < text.len and text[i] == ColonChar:
    result.keyed = true
    inc i
  if i >= text.len or text[i] != ']':
    raiseErr(ekBadLiteral, "expected ']' in table header", line, i + 1)
  inc i
  if i >= text.len or text[i] != '{':
    raiseErr(ekBadLiteral, "expected '{' in table header", line, i + 1)
  inc i
  let hStart = i
  while i < text.len and text[i] != '}':
    inc i
  if i >= text.len:
    raiseErr(ekBadLiteral, "unterminated header list", line, hStart + 1)
  let hList = text[hStart ..< i]
  inc i
  if i >= text.len or text[i] != ColonChar:
    raiseErr(ekBadLiteral, "expected ':' after table header", line, i + 1)
  if i + 1 != text.len:
    raiseErr(ekBadLiteral, "trailing content after table header", line, i + 2)
  if hList.len == 0:
    raiseErr(ekBadLiteral, "empty header list", line, hStart + 1)
  var j = 0
  while j < hList.len:
    let (ident, next) = parseIdentAt(hList, j, line)
    if ident.len == 0 and not opensString(hList, j):
      raiseErr(ekBadLiteral, "empty column name", line, hStart + j + 1)
    result.columns.add ident
    if next >= hList.len:
      break
    if hList[next] != '|':
      raiseErr(ekBadLiteral, "expected '|' in header list", line, hStart + next + 1)
    j = next + 1
    if j >= hList.len:
      raiseErr(ekBadLiteral, "trailing '|' in header list", line, hStart + j + 1)

proc parseCell(raw: string; line: int; col: int): TortValue =
  ## Cell production: QuotedString | CellText; empty bare cell → "" (D6).
  let trimmed = raw.strip(leading = false, chars = {' ', '\t'})
  if trimmed.len > 0 and opensString(trimmed, 0):
    let (val, next) = parseStringAt(trimmed, 0, line, col)
    if next != trimmed.len:
      raiseErr(ekBadLiteral, "trailing content after quoted cell", line, col + next)
    return ttStr(val)
  classifyBare(trimmed, qcCell, line, col)

proc isDocSep(text: string): bool =
  ## DocSep production (v0.1.3): optional ws + "---" + optional ws.
  text.strip(chars = {' ', '\t'}) == DocSepToken

proc decodeSection(ls: seq[TortLine]; start: int; strict: bool): tuple[obj: TortValue, next: int] =
  ## One Section production: lines up to (not including) the next DocSep.
  var st = DecodeState(root: ttObject(@[]), strict: strict)
  var scope: seq[string] = @[]
  var i = start
  while i < ls.len:
    let text = ls[i].text
    let line = ls[i].num
    if isBlank(text) or isComment(text):
      inc i
      continue
    if isDocSep(text):
      break
    let (delim, pos) = findKeyEnd(text, line)
    if delim == ColonChar:
      parseKv(text, line, pos, st, scope)
      inc i
    elif delim == '[':
      let (dots, name, count, keyed, columns) = parseHeader(text, line, pos)
      applyScope(scope, dots, name, line)
      var rows: seq[TortValue] = @[]
      var keyedObj = ttObject(@[])
      var seen = 0
      var j = i + 1
      while seen < count:
        if j >= ls.len or isDocSep(ls[j].text):
          raiseErr(ekRowCountMismatch,
                   "table expected " & $count & " rows, got " & $seen, line, 1)
        let rt = ls[j].text
        if isBlank(rt) or isComment(rt):
          inc j                                       ## spec §4.2: skipped, not counted
          continue
        let cells = splitUnescaped(rt, PipeChar, qcCell, ls[j].num, 1)
        if cells.len != columns.len:
          raiseErr(ekWidthMismatch,
                   "row has " & $cells.len & " cells, schema has " & $columns.len,
                   ls[j].num, 1)
        if keyed:
          let keyCell = cells[0]
          let k = if keyCell.len > 0 and opensString(keyCell, 0):
                    parseStringAt(keyCell, 0, ls[j].num, 1).val
                  else:
                    unescapeBare(keyCell, qcCell, ls[j].num, 1)
          var obj: seq[(string, TortValue)] = @[]
          for c in 1 ..< columns.len:
            obj.add (columns[c], parseCell(cells[c], ls[j].num, 1))
          var dup = false
          for p in keyedObj.oVal.mitems:
            if p[0] == k:
              if st.strict:
                raiseErr(ekDuplicateKey, "duplicate keyed-table key: " & k, ls[j].num, 1)
              p[1] = ttObject(obj)                    ## LWW
              dup = true
              break
          if not dup:
            keyedObj.oVal.add (k, ttObject(obj))
        else:
          var obj: seq[(string, TortValue)] = @[]
          for c in 0 ..< columns.len:
            obj.add (columns[c], parseCell(cells[c], ls[j].num, 1))
          rows.add ttObject(obj)
        inc seen
        inc j
      let tableVal = if keyed: keyedObj else: ttList(rows)
      insertAt(st, scope, tableVal, line)
      i = j
    else:
      raiseErr(ekBadLiteral, "line is neither a KV line nor a table header", line, 1)
  (st.root, i)

proc decode*(src: string; strict: bool): TortValue =
  let ls = ttLines.splitLines(src)
  ## RootValue detection (v0.1.3): the WHOLE document is one keyless value line.
  var content: seq[TortLine] = @[]
  var sepCount = 0
  for l in ls:
    if isBlank(l.text) or isComment(l.text):
      continue
    if isDocSep(l.text):
      inc sepCount
      continue
    content.add l
  if sepCount == 0 and content.len == 1:
    let (delim, pos) = findKeyEnd(content[0].text, content[0].num)
    if delim == '\0' or pos == 0:
      ## no key region at all: bare root value (root "[]" hits '[' at pos 0)
      let text = content[0].text
      let start = skipWs(text, 0)
      return parseValue(text[start .. ^1], content[0].num, start + 1)
  ## Sections: N sections → array of N objects; 1 section → the object.
  if sepCount == 0:
    return decodeSection(ls, 0, strict).obj
  var sections: seq[TortValue] = @[]
  var i = 0
  while i < ls.len:
    let (obj, next) = decodeSection(ls, i, strict)
    sections.add obj
    i = next + 1                                 ## skip the DocSep line itself
  ttList(sections)
