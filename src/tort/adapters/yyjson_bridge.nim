## yyjson anti-corruption adapter — the ONLY module importing yyjson (D7).
## yyjson types never cross this boundary: TortValue and plain strings cross instead.

import yyjson
import yyjson/private          ## yyjson_read_opts + read_size for the splitter
import ../domain/[ast, errors]
import ../core/ports

const
  ReadFlags* = YYJSON_READ_ALLOW_COMMENTS or YYJSON_READ_ALLOW_TRAILING_COMMAS or
               YYJSON_READ_ALLOW_INF_AND_NAN or YYJSON_READ_ALLOW_BOM
    ## forgiving input set (design 03_1)
  SplitFlags* = ReadFlags or YYJSON_READ_STOP_WHEN_DONE
    ## splitter set: STOP_WHEN_DONE gives free doc-boundary detection

proc toTtValue(v: JsonVal): TortValue =
  case v.kind
  of jkNull:
    ttNull()
  of jkBool:
    ttBool(v.bool)
  of jkNumber:
    if v.isSInt:
      ttInt(v.int64)
    elif v.isUInt:
      let u = v.uint64
      if u <= cast[uint64](high(int64)):
        ttInt(cast[int64](u))
      else:
        ttFloat(cast[float](u))     ## u64 beyond int64: nearest double, documented loss
    else:
      ttFloat(v.float)
  of jkString:
    ttStr(v.str)
  of jkArray:
    var items: seq[TortValue] = @[]
    for it in v.items:
      items.add toTtValue(it)
    ttList(items)
  of jkObject:
    var pairs: seq[(string, TortValue)] = @[]
    for k, f in v.pairs:
      pairs.add ($k, toTtValue(f))
    ttObject(pairs)
  of jkNone, jkRaw:
    raiseErr(ekBadJson, "unexpected yyjson value kind: " & $v.kind)

proc parseJson*(text: string): TortValue =
  ## JSON text → TortValue. yyjson errors are translated to ekBadJson with
  ## line:col via yyjson's own locate_pos.
  var doc: JsonDoc
  try:
    doc = readJson(text, ReadFlags)
  except JsonReadError as e:
    var loc: JsonLocation
    var line, col = 0
    if locatePos(text, e.pos, loc):
      line = loc.line
      col = loc.col
    raiseErr(ekBadJson, e.reason, line, col)
  defer:
    doc.close()
  toTtValue(doc.root)

proc toMut(d: JsonMutDoc; v: TortValue): JsonMutVal =
  case v.kind
  of tkNull:
    d.newNull()
  of tkBool:
    d.newBool(v.bVal)
  of tkInt:
    d.newInt(v.iVal)
  of tkFloat:
    d.newFloat(v.fVal)
  of tkString:
    d.newString(v.sVal)
  of tkList:
    let a = d.newArray()
    for it in v.lVal:
      a.add toMut(d, it)
    a
  of tkObject:
    let o = d.newObject()
    for (k, f) in v.oVal:
      o.add(k, toMut(d, f))
    o

proc toJsonText*(v: TortValue): string =
  ## TortValue → compact JSON text (pretty-printing is jq's job, L0).
  var d = newJsonMutDoc()
  defer:
    d.close()
  d.setRoot(toMut(d, v))
  try:
    writeJson(d)
  except JsonWriteError as e:
    raiseErr(ekEncodeImpossible, e.reason)

type
  YySplitter* = object         ## JsonWire port implementation

proc trySplit*(s: var YySplitter; buf: string): SplitResult =
  ## Split one complete JSON doc off the buffer head.
  ## Partial-doc detection (L4 decision): UNEXPECTED_END / EMPTY_CONTENT or
  ## error position at buffer end → ssNeedMore; otherwise ssInvalid.
  var err: YyJsonReadErr
  let p = yyjson_read_opts(buf.cstring, buf.len.csize_t, SplitFlags, nil, addr err)
  if p.isNil:
    case err.code
    of YYJSON_READ_ERROR_UNEXPECTED_END, YYJSON_READ_ERROR_EMPTY_CONTENT:
      return (ssNeedMore, "", buf)
    of YYJSON_READ_ERROR_MEMORY_ALLOCATION:
      raiseErr(ekBadJson, "yyjson out of memory")
    else:
      if cast[int](err.pos) >= buf.len:
        return (ssNeedMore, "", buf)
      return (ssInvalid, "", buf)
  let n = cast[int](yyjson_doc_get_read_size(p))
  yyjson_doc_free(p)
  (ssDoc, buf[0 ..< n], buf[n .. ^1])

proc parseDoc*(s: var YySplitter; text: string): TortValue =
  parseJson(text)
