## TtValue → TT encoder. Spec: tort-spec-v0.1.2.md §5 (decision matrix), §6 (canon).
## Shape detection (Jaccard tables) + dot-trie prefix-diff emission.

import std/[algorithm, sets, strutils]
import ../domain/[ast, errors, literal, consts]
import consts as coreConsts

type
  EmitItem = object
    path: seq[string]
    blk: string          ## non-empty: whole table block (multi-line)
    leaf: TtValue        ## blk empty: KV leaf value

proc isScalarish(v: TtValue): bool =
  ## Table cells / inline-list items must be scalars; containers force fallback.
  v.kind notin {tkList, tkObject}

proc keySet(v: TtValue): HashSet[string] =
  for (k, _) in v.oVal:
    result.incl k

proc keyJaccard(items: seq[TtValue]): float =
  ## Key-set Jaccard similarity across object items, spec §5.1.
  var uni, inter: HashSet[string]
  for idx, it in items:
    let ks = keySet(it)
    if idx == 0:
      inter = ks
    else:
      inter = inter * ks
    uni = uni + ks
  if uni.len == 0:
    return 1.0
  inter.len.float / uni.len.float

proc isTableCandidate(v: TtValue): bool =
  ## Array of >= 2 uniform objects with scalar-only fields (spec §5.1).
  if v.kind != tkList or v.lVal.len < 2:
    return false
  for it in v.lVal:
    if it.kind != tkObject:
      return false
    for (_, f) in it.oVal:
      if not isScalarish(f):
        return false
  keyJaccard(v.lVal) >= JaccardThreshold

proc isKeyedCandidate(v: TtValue): bool =
  ## Object of >= 2 uniform non-empty objects with scalar-only fields (§5 matrix).
  if v.kind != tkObject or v.oVal.len < 2:
    return false
  var vals: seq[TtValue] = @[]
  for (_, f) in v.oVal:
    if f.kind != tkObject or f.oVal.len == 0:
      return false
    for (_, g) in f.oVal:
      if not isScalarish(g):
        return false
    vals.add f
  keyJaccard(vals) >= JaccardThreshold

proc unionColumns(items: seq[TtValue]): seq[string] =
  var seen: HashSet[string]
  for it in items:
    for (k, _) in it.oVal:
      if k notin seen:
        seen.incl k
        result.add k
  result.sort()                        ## deterministic column order (C4)

proc findField(obj: TtValue; key: string): TtValue =
  for (k, f) in obj.oVal:
    if k == key:
      return f
  nil

proc renderTable(absName: string; items: seq[TtValue]): string =
  ## TableBlock emission (spec §4 shape, §5.1 heuristics).
  ## absName is the fully rendered absolute key (multi-segment, pending D8).
  let cols = unionColumns(items)
  var lines: seq[string] = @[]
  var header = absName & "[" & $items.len & "]{"
  for idx, c in cols:
    if idx > 0:
      header.add PipeChar
    header.add renderKey(c)
  header.add "}:"
  lines.add header
  for it in items:
    var row = ""
    for idx, c in cols:
      if idx > 0:
        row.add PipeChar
      let cell = findField(it, c)
      row.add(if cell.isNil: NullToken else: renderScalar(cell, qcCell))
    lines.add row
  lines.join("\n")

proc renderKeyedTable(absName: string; obj: TtValue): string =
  ## KeyedTableBlock emission: first column = object key (raw string, spec §4.5).
  var vals: seq[TtValue] = @[]
  for (_, f) in obj.oVal:
    vals.add f
  let cols = unionColumns(vals)
  var lines: seq[string] = @[]
  var header = absName & "[" & $obj.oVal.len & ":]{key"
  for c in cols:
    header.add PipeChar
    header.add renderKey(c)
  header.add "}:"
  lines.add header
  for (k, f) in obj.oVal:
    var row = renderScalar(ttStr(k), qcCell)
    for c in cols:
      row.add PipeChar
      let cell = findField(f, c)
      row.add(if cell.isNil: NullToken else: renderScalar(cell, qcCell))
    lines.add row
  lines.join("\n")

proc renderLeaf(v: TtValue): string =
  ## KV leaf value: scalar, inline scalar list, or empty container (v0.1.2).
  case v.kind
  of tkList:
    if v.lVal.len == 0:
      return EmptyArrToken
    if v.lVal.len == 1:
      ## D7 (v0.1.3): trailing comma marks a single-element list.
      return renderScalar(v.lVal[0], qcItem) & CommaChar
    var s = ""
    for idx, it in v.lVal:
      if idx > 0:
        s.add CommaChar
      s.add renderScalar(it, qcItem)
    s
  of tkObject:
    if v.oVal.len == 0:
      return EmptyObjToken
    raiseErr(ekEncodeImpossible, "internal: non-empty object is not a leaf")
  else:
    renderScalar(v, qcValue)

proc renderPathAbs(path: seq[string]): string =
  for idx, seg in path:
    if idx > 0:
      result.add DotChar
    result.add renderKey(seg)

proc flatten(items: var seq[EmitItem]; v: TtValue; path: seq[string]) =
  ## Walk a value: qualifying shapes become blocks; the rest becomes KV leaves.
  ## Non-uniform object arrays flatten via numeric key segments (spec §3.2 trace).
  case v.kind
  of tkObject:
    if v.oVal.len == 0:
      items.add EmitItem(path: path, leaf: v)
    elif isKeyedCandidate(v):
      items.add EmitItem(path: path, blk: renderKeyedTable(renderPathAbs(path), v))
    else:
      for (k, c) in v.oVal:
        flatten(items, c, path & k)
  of tkList:
    if v.lVal.len == 0:
      items.add EmitItem(path: path, leaf: v)
    elif isTableCandidate(v):
      items.add EmitItem(path: path, blk: renderTable(renderPathAbs(path), v.lVal))
    else:
      var allScalar = true
      for it in v.lVal:
        if not isScalarish(it):
          allScalar = false
          break
      if allScalar:
        items.add EmitItem(path: path, leaf: v)
      else:
        for idx, it in v.lVal:
          flatten(items, it, path & $idx)
  else:
    items.add EmitItem(path: path, leaf: v)

proc cmpPath(a, b: seq[string]): int =
  ## Lexicographic by segments (spec §5.2.2).
  for i in 0 ..< min(a.len, b.len):
    if a[i] < b[i]: return -1
    if a[i] > b[i]: return 1
  a.len - b.len

proc emit(root: TtValue): seq[string] =
  var items: seq[EmitItem] = @[]
  for (k, c) in root.oVal:
    flatten(items, c, @[k])
  items.sort(proc(a, b: EmitItem): int = cmpPath(a.path, b.path))
  var prev: seq[string] = @[]
  for it in items:
    if it.blk.len > 0:
      ## Table block: absolute (possibly multi-segment) key already rendered.
      result.add it.blk
      prev = it.path
      continue
    var l = 0
    while l < min(prev.len, it.path.len) and prev[l] == it.path[l]:
      inc l
    let k = prev.len - l
    var line: string
    if k > 0 and k < prev.len:
      ## relative: K dots + suffix (spec §5.2.3)
      line = repeat(DotChar, k)
      for idx in l ..< it.path.len:
        if idx > l:
          line.add DotChar
        line.add renderKey(it.path[idx])
    else:
      ## k == prev.len (no common prefix) or k == 0 (descend): absolute form
      line = renderPathAbs(it.path)
    line.add ColonChar
    line.add ' '
    line.add renderLeaf(it.leaf)
    result.add line
    prev = it.path

type
  TryJsonParse* = proc(s: string): TtValue
    ## --one-way injection point: full-string JSON parse, nil on failure.
    ## Core must not import the yyjson adapter — the app layer supplies this.

proc oneWayTree*(v: TtValue; tryParse: TryJsonParse; depth = 0) =
  ## D18+D19 (--one-way, LOSSY, opt-in): (1) a string value that FULLY parses
  ## as a JSON object/array is replaced by the parsed structure, recursively
  ## (depth-capped); (2) every remaining string value gets whitespace squash —
  ## trailing-ws strip, gcd-indent→tabs, >3 '\n'→3. Keys are never touched.
  ## Unpack runs FIRST so embedded JSON reveals real newlines for the squash.
  case v.kind
  of tkString:
    if depth < MaxUnpackDepth:
      let parsed = tryParse(v.sVal)
      if parsed != nil and parsed.kind in {tkObject, tkList}:
        v[] = parsed[]                       ## string node becomes container
        oneWayTree(v, tryParse, depth + 1)
        return
    v.sVal = squashWs(v.sVal)
  of tkList:
    for it in v.lVal:
      oneWayTree(it, tryParse, depth)
  of tkObject:
    for i in 0 ..< v.oVal.len:
      oneWayTree(v.oVal[i][1], tryParse, depth)
  else:
    discard

proc encode*(v: TtValue; tryParse: TryJsonParse = nil): string =
  ## Root mapping (v0.1.3 D10): object → sections; array of objects →
  ## DocSep-separated sections; scalar / scalar list → one bare ValueLine;
  ## mixed root arrays are rejected. tryParse != nil ⇒ LOSSY --one-way mode.
  if tryParse != nil:
    oneWayTree(v, tryParse)
  case v.kind
  of tkObject:
    if v.oVal.len == 0:
      return ""
    let lines = emit(v)
    result = lines.join("\n")
    if result.len > 0:
      result.add '\n'
  of tkList:
    var allObjects = v.lVal.len > 0
    for it in v.lVal:
      if it.kind != tkObject:
        allObjects = false
        break
    if allObjects:
      var parts: seq[string] = @[]
      for it in v.lVal:
        if it.oVal.len == 0:
          parts.add ""
        else:
          parts.add emit(it).join("\n")
      result = parts.join("\n---\n")
      if result.len > 0:
        result.add '\n'
    else:
      var s = ""
      for idx, it in v.lVal:
        if idx > 0:
          s.add CommaChar
        s.add renderScalar(it, qcRootItem)
      if v.lVal.len == 0:
        s = EmptyArrToken
      elif v.lVal.len == 1:
        s.add CommaChar                      ## D7: single-element root list
      result = s & "\n"
  else:
    result = renderScalar(v, qcRoot) & "\n"
