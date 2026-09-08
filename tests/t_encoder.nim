## Encoder battery — lossless round-trips (bijection §5) and the lossy
## --one-way mode (D18+D19, spec case P).

import unittest2
import std/strutils
import tort/tort
import tort/adapters/yyjson_bridge
import helpers

proc tryJson(s: string): TortValue =
  ## Full-string JSON parse, nil when not valid JSON (D19 helper shape).
  try:
    parseJson(s)
  except TortError:
    nil

suite "encoder: lossless round-trip battery":
  test "round-trip: decode(encode(v)) == v":
    const docs = [
      """{"a":1,"b":"two","c":[1,2,3],"d":{"x":true,"y":null}}""",
      """{"t":[{"a":1,"b":2},{"a":3,"b":4}]}""",
      """{"cfg":{},"queue":[],"literal":"{}"}""",
      """{"code":"line1\nline2\n"}""",
      """{"arr":[{"type":"A","name":"foo"},{"type":"B","value":"bar"}],"q":[5]}""",
      """{"title":"~","note":" trailing space "}""",
      """{"ключ":1,"sys.config":{"item":2}}""",
      """{"f":100.0,"g":"100.","z":0.0}""",
      """{"nested":{"deep":{"deeper":{"x":[1,{"y":2}]}}}}""",
      """{"s":"commas, inside","q":"quotes \"inside\"","p":"pipe | inside"}""",
      "{}",
    ]
    for j in docs:
      checkpoint j
      let v = parseJson(j)
      let back = decode(encode(v), strict = true)
      if not tortEqual(sortKeys(back), sortKeys(v)):
        echo "json:     ", j
        echo "tort:     ", encode(v)
        echo "got:      ", toJsonText(back)
      check tortEqual(sortKeys(back), sortKeys(v))

  test "heredoc preferred for trailing-newline strings (D24 §6.2)":
    let outp = encode(parseJson("""{"code":"def f():\n    pass\n"}"""))
    check "```[2]" in outp
    check "def f():\n    pass\n" in outp

  test "empty containers encode as literals (v0.1.2)":
    let outp = encode(parseJson("""{"cfg":{},"queue":[]}"""))
    check "cfg: {}" in outp
    check "queue: []" in outp

  test "uniform object array encodes as table":
    let outp = encode(parseJson("""{"t":[{"a":1,"b":2},{"a":3,"b":4}]}"""))
    check "t[2]{a|b}:" in outp

suite "encoder: --one-way mode (spec case P, LOSSY)":
  test "case P: whitespace squash":
    let v = parseJson(
      """{"input string": "def f():\n    x = 1   \n        deeper\n\n\n\n\ntail"}""")
    let back = decode(encode(v, tryJson), strict = true)
    checkJson back, """{"input string":"def f():\n\tx = 1\n\t\tdeeper\n\n\ntail"}"""

  test "case P: JSON-in-string unpack (D19)":
    let v = parseJson("""{"args": "{\"path\": \"/x.py\"}", "s": "42"}""")
    let back = decode(encode(v, tryJson), strict = true)
    checkJson back, """{"args":{"path":"/x.py"},"s":"42"}"""

  test "one-way is opt-in: nil tryParse keeps strings verbatim":
    let v = parseJson("""{"s": "{\"a\": 1}", "ws": "x    y"}""")
    let back = decode(encode(v), strict = true)
    checkJson back, """{"s":"{\"a\": 1}","ws":"x    y"}"""
