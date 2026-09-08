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
