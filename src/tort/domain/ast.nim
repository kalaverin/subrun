## TT AST — TtValue. Spec: tort-spec-v0.1.2.md.
## No table kind: a table is an encoding form, not a data type.
## Construction goes through the constructors only (kind/payload always agree).

type
  TtKind* = enum
    tkNull
    tkBool
    tkInt
    tkFloat
    tkString
    tkList
    tkObject

  TtValue* = ref object
    case kind*: TtKind
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
      lVal*: seq[TtValue]
    of tkObject:
      oVal*: seq[(string, TtValue)]   ## insertion order is format semantics

proc ttNull*(): TtValue =
  TtValue(kind: tkNull)

proc ttBool*(v: bool): TtValue =
  TtValue(kind: tkBool, bVal: v)

proc ttInt*(v: int64): TtValue =
  TtValue(kind: tkInt, iVal: v)

proc ttFloat*(v: float64): TtValue =
  TtValue(kind: tkFloat, fVal: v)

proc ttStr*(v: string): TtValue =
  TtValue(kind: tkString, sVal: v)

proc ttList*(items: seq[TtValue]): TtValue =
  TtValue(kind: tkList, lVal: items)

proc ttObject*(pairs: seq[(string, TtValue)]): TtValue =
  TtValue(kind: tkObject, oVal: pairs)
