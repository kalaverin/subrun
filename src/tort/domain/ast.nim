## Tort AST — TortValue. Spec: tort-spec-v0.1.2.md.
## No table kind: a table is an encoding form, not a data type.
## Construction goes through the constructors only (kind/payload always agree).

type
  TortKind* = enum
    tkNull
    tkBool
    tkInt
    tkFloat
    tkString
    tkList
    tkObject

  TortValue* = ref object
    case kind*: TortKind
    of tkNull:
      discard
    of tkBool:
      bVal*: bool
    of tkInt:
      iVal*: int64
    of tkFloat:
      fVal*: float64
    of tkString:
      sVal*: string
    of tkList:
      lVal*: seq[TortValue]
    of tkObject:
      oVal*: seq[(string, TortValue)]   ## insertion order is format semantics

proc ttNull*(): TortValue =
  TortValue(kind: tkNull)

proc ttBool*(v: bool): TortValue =
  TortValue(kind: tkBool, bVal: v)

proc ttInt*(v: int64): TortValue =
  TortValue(kind: tkInt, iVal: v)

proc ttFloat*(v: float64): TortValue =
  TortValue(kind: tkFloat, fVal: v)

proc ttStr*(v: string): TortValue =
  TortValue(kind: tkString, sVal: v)

proc ttList*(items: seq[TortValue]): TortValue =
  TortValue(kind: tkList, lVal: items)

proc ttObject*(pairs: seq[(string, TortValue)]): TortValue =
  TortValue(kind: tkObject, oVal: pairs)

proc tortEqual*(a, b: TortValue): bool =
  ## Deep structural equality (D22 encoder: ditto emission test).
  ## nil ≡ "field absent"; objects compare positionally (insertion order
  ## is format semantics). Not an `==` overload by design.
  if a.isNil or b.isNil:
    return a.isNil == b.isNil
  if a.kind != b.kind:
    return false
  case a.kind
  of tkNull: true
  of tkBool: a.bVal == b.bVal
  of tkInt: a.iVal == b.iVal
  of tkFloat: a.fVal == b.fVal
  of tkString: a.sVal == b.sVal
  of tkList:
    if a.lVal.len != b.lVal.len:
      return false
    for i in 0 ..< a.lVal.len:
      if not tortEqual(a.lVal[i], b.lVal[i]):
        return false
    true
  of tkObject:
    if a.oVal.len != b.oVal.len:
      return false
    for i in 0 ..< a.oVal.len:
      if a.oVal[i][0] != b.oVal[i][0] or not tortEqual(a.oVal[i][1], b.oVal[i][1]):
        return false
    true
