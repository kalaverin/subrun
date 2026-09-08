## Shared test helpers for the subrun test battery.
## Not a test file itself (nimble test runs tests/t*.nim only).

import unittest2
import std/algorithm
import tort/tort
import tort/adapters/yyjson_bridge

proc sortKeys*(v: TortValue): TortValue =
  ## Recursively sort object keys — the encoder emits the spec-mandated
  ## lexicographic path order (§5.2), so round-trip equality is up to order.
  case v.kind
  of tkObject:
    var pairs = v.oVal
    for p in pairs.mitems:
      p[1] = sortKeys(p[1])
    pairs.sort(proc(a, b: (string, TortValue)): int = cmp(a[0], b[0]))
    ttObject(pairs)
  of tkList:
    var items = v.lVal
    for it in items.mitems:
      it = sortKeys(it)
    ttList(items)
  else:
    v

proc checkJson*(v: TortValue; expectedJson: string) =
  ## Structural equality against expected JSON, readable diff on failure.
  let expected = parseJson(expectedJson)
  if not tortEqual(v, expected):
    echo "got:      ", toJsonText(v)
    echo "expected: ", toJsonText(expected)
  check tortEqual(v, expected)

template checkErr*(kind: TortErrorKind; body: untyped) =
  ## Run body, require a TortError with the given errKind.
  var caught = false
  try:
    body
  except TortError as e:
    caught = true
    check e.errKind == kind
  check caught

proc jget*(v: TortValue; key: string): TortValue =
  ## Object field access for assertions (nil ≡ field absent).
  if v.isNil or v.kind != tkObject:
    return nil
  for (k, f) in v.oVal:
    if k == key:
      return f
  nil

proc jat*(v: TortValue; i: int): TortValue =
  ## Array index access for assertions.
  if v.isNil or v.kind != tkList or i >= v.lVal.len:
    return nil
  v.lVal[i]

proc sb*(s: string): seq[byte] =
  ## string -> seq[byte] for byte-oriented filter APIs.
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc bs*(b: seq[byte]): string =
  ## seq[byte] -> string for byte-oriented filter APIs.
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)
