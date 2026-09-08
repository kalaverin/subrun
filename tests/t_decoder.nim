## Decoder conformance battery — Tort spec v0.1.8 §10, cases A–T.
## Case P (lossy --one-way) lives in t_encoder.nim; case N does not exist.

import unittest2
import tort/tort
import helpers

suite "decoder: spec v0.1.8 cases":
  test "case A: deep alternating rollback":
    ## Case A erratum (parked, aggregate A3): the spec §10 expected JSON for
    ## `....i: 4` contradicts §3.1 rollback counting. The implementation
    ## follows §3.1 (4 dots = 4-level rollback from a.b.c.g.h -> a.i); the
    ## test pins current behavior until the erratum is resolved.
    checkJson decode("""a.b.c.d.e: 1
.f: 2
..g.h: 3
....i: 4""", strict = true),
      """{"a":{"b":{"c":{"d":{"e":1,"f":2},"g":{"h":3}}},"i":4}}"""

  test "case B: empty vs null cells":
    checkJson decode("""items[2]{id|label|meta}:
1||~
2|valid|~""", strict = true),
      """{"items":[{"id":1,"label":"","meta":null},{"id":2,"label":"valid","meta":null}]}"""

  test "case C: pipe escaping in cells":
    checkJson decode("""commands[1]{cmd|desc}:
cat file \| grep err|Search logs""", strict = true),
      """{"commands":[{"cmd":"cat file | grep err","desc":"Search logs"}]}"""

  test "case D: quoted strings round-trip":
    checkJson decode("""title: "~"
note: " trailing space """", strict = true),
      """{"title":"~","note":" trailing space "}"""

  test "case E: quoted keys & escaped idents":
    checkJson decode("\"ключ\": 1\nsys\\.config.item: 2", strict = true),
      """{"ключ":1,"sys.config":{"item":2}}"""

  test "case F: comments & blank lines inside tables":
    checkJson decode("""t[2]{a|b}:
# leading comment
1|2

  # indented comment
3|4""", strict = true),
      """{"t":[{"a":1,"b":2},{"a":3,"b":4}]}"""

  test "case G: empty document / zero-row table":
    checkJson decode("", strict = true), "{}"
    checkJson decode("t[0]{a|b}:", strict = true), """{"t":[]}"""

  test "case H: narrow numbers":
    checkJson decode("""a: +5
b: .5
c: 007
d: -0
e: 1e-4""", strict = true),
      """{"a":"+5","b":".5","c":"007","d":0,"e":0.0001}"""

  test "case I: empty containers (v0.1.2)":
    checkJson decode("""cfg: {}
queue: []
literal: "{}"""", strict = true),
      """{"cfg":{},"queue":[],"literal":"{}"}"""

  test "case J: single-element & trailing-comma lists (v0.1.3)":
    checkJson decode("""one: x,
two: a,b,
plain: x""", strict = true),
      """{"one":["x"],"two":["a","b"],"plain":"x"}"""

  test "case K: multi-section document (v0.1.3)":
    checkJson decode("""a: 1
---
b: 2""", strict = true),
      """[{"a":1},{"b":2}]"""

  test "case K: root scalar document":
    checkJson decode("42", strict = true), "42"

  test "case L: trailing-dot floats (v0.1.3)":
    checkJson decode("""f: 100.
g: "100."
z: 0.""", strict = true),
      """{"f":100.0,"g":"100.","z":0.0}"""

  test "case M: raw strings (v0.1.4)":
    checkJson decode("args: \"\"\"{\"command\": \"ls -la\", \"timeout\": 120}\"\"\"\nshort: \"a\\\"b\"\nlit: \"\\\"\\\"\\\"\"", strict = true),
      "{\"args\":\"{\\\"command\\\": \\\"ls -la\\\", \\\"timeout\\\": 120}\",\"short\":\"a\\\"b\",\"lit\":\"\\\"\\\"\\\"\"}"

  test "case O: escaped fence (v0.1.7, D20)":
    checkJson decode("new: '''class X:\\n\\t\"\"\"dense quotes\"\"\"'''\nold: \"sparse \\\"one\\\" quote stays classic\"\nraw: \"\"\"dense \"single-line\" \"content\" with \"quotes\" ok\"\"\"", strict = true),
      "{\"new\":\"class X:\\n\\t\\\"\\\"\\\"dense quotes\\\"\\\"\\\"\",\"old\":\"sparse \\\"one\\\" quote stays classic\",\"raw\":\"dense \\\"single-line\\\" \\\"content\\\" with \\\"quotes\\\" ok\"}"

  test "case Q: right-truncated rows (v0.1.8, D21)":
    checkJson decode("""logs[2]{code|status|time|err|trace}:
200|OK|12ms
404|NF|3ms|missing""", strict = true),
      """{"logs":[{"code":200,"status":"OK","time":"12ms","err":null,"trace":null},{"code":404,"status":"NF","time":"3ms","err":"missing","trace":null}]}"""

  test "case R: ditto cells (v0.1.8, D22)":
    checkJson decode("""logs[3]{host|level|msg}:
worker-1|INFO|Login OK
^|^|Token refresh
^|WARN|Timeout""", strict = true),
      """{"logs":[{"host":"worker-1","level":"INFO","msg":"Login OK"},{"host":"worker-1","level":"INFO","msg":"Token refresh"},{"host":"worker-1","level":"WARN","msg":"Timeout"}]}"""

  test "case S: anonymous array scope (v0.1.8, D23)":
    checkJson decode("""arr[].type: A
.name: foo
..[].type: B
.value: bar
q[]: 5""", strict = true),
      """{"arr":[{"type":"A","name":"foo"},{"type":"B","value":"bar"}],"q":[5]}"""

  test "case T: length-prefixed heredoc (v0.1.8, D24)":
    checkJson decode("""code: ```[2]
def hello():
    print("ok")""", strict = true),
      """{"code":"def hello():\n    print(\"ok\")\n"}"""

  test "case T: N = 0 decodes to empty string":
    checkJson decode("code: ```[0]", strict = true), """{"code":""}"""

  test "case T: DocSep-like content line is data":
    checkJson decode("""code: ```[2]
---
not a separator""", strict = true),
      """{"code":"---\nnot a separator\n"}"""

  test "T01: \\n escape is legal in bare KV values (spec §1.2 qcValue)":
    checkJson decode("msg: line1\\nline2", strict = true),
      """{"msg":"line1\nline2"}"""

  test "T01: literal comma escape still yields a single item":
    checkJson decode("a: x\\,y", strict = true), """{"a":"x,y"}"""

  test "T01: \\n in a list item stays rejected (qcItem has no 'n')":
    checkErr ekBadEscape:
      discard decode("list: a\\nb, c", strict = true)

  test "T02: LWW scalar-over-object replace invalidates nested slots":
    checkJson decode("a.b: 1\na: 2\na.c: 3\na.b: 4", strict = false),
      """{"a":{"c":3,"b":4}}"""

  test "T02: stale leaf slot after replace does not crash or corrupt":
    checkJson decode("a.b: 1\na: 2\na.b: 3", strict = false),
      """{"a":{"b":3}}"""

  test "T02: strict mode still raises before any mutation":
    checkErr ekDuplicateKey:
      discard decode("a.b: 1\na: 2\na.b: 3", strict = true)

  test "T03: root-level heredoc decodes (D24)":
    checkJson decode("```[2]\nline one\nline two", strict = true),
      "\"line one\\nline two\\n\""

  test "T03: root heredoc with N=0 is the empty string":
    checkJson decode("```[0]", strict = true), "\"\""

  test "T03: root heredoc EOF short -> UnterminatedHeredoc":
    checkErr ekUnterminatedHeredoc:
      discard decode("```[2]\nonly one", strict = true)

  test "T04: keyed-table key cell is trailing-trimmed like any cell":
    checkJson decode("name[1:]{k|v}:\nk1 | 1", strict = true),
      """{"name":{"k1":{"v":" 1"}}}"""

  test "T04: quoted key cell stays verbatim":
    checkJson decode("name[1:]{k|v}:\n\"k1 \"| 1", strict = true),
      """{"name":{"k1 ":{"v":" 1"}}}"""

  test "T05: \\u0001 inside a quoted key must not alias a dotted path":
    ## joinPath joins segments with '\x01'; a quoted key may legally carry
    ## '\x01' (\"a\\u0001b\") — without length-prefixing the slots keys collide.
    checkJson decode("\"a\\u0001b\".x: 1\na.b.x: 2", strict = true),
      "{\"a\\u0001b\":{\"x\":1},\"a\":{\"b\":{\"x\":2}}}"

  test "T33: bare root value with trailing content is rejected":
    checkErr ekBadLiteral:
      discard decode("42\n43", strict = true)

  test "T33: root heredoc with trailing KV content is rejected":
    checkErr ekBadLiteral:
      discard decode("```[1]\nx\na: 1", strict = true)

  test "T33: root scalar with trailing comments and blanks decodes":
    checkJson decode("42\n# tail\n", strict = true), "42"

  test "T33: section shape invariants (leading/trailing DocSep)":
    checkJson decode("a: 1", strict = true), """{"a":1}"""
    checkJson decode("a: 1\n---\n", strict = true), """[{"a":1}]"""
    checkJson decode("---\na: 1", strict = true), """[{},{"a":1}]"""
    checkJson decode("---", strict = true), "[{}]"          ## seps-only doc
    checkJson decode("---\n---", strict = true), "[{},{}]"

suite "decoder: negative cases (spec §7)":
  test "duplicate key in strict mode -> DuplicateKey":
    checkErr ekDuplicateKey:
      discard decode("a: 1\na: 2", strict = true)

  test "duplicate key non-strict: last write wins":
    checkJson decode("a: 1\na: 2", strict = false), """{"a":2}"""

  test "fewer rows than declared -> RowCountMismatch":
    checkErr ekRowCountMismatch:
      discard decode("""items[2]{id}:
1""", strict = true)

  test "case Q negative: row overflow -> WidthMismatch":
    checkErr ekWidthMismatch:
      discard decode("""logs[1]{a|b}:
1|2|3""", strict = true)

  test "case R negative: ditto in first row -> DittoUnderflow":
    checkErr ekDittoUnderflow:
      discard decode("""logs[2]{host|msg}:
^|first
x|second""", strict = true)

  test "case R: quoted/escaped caret is a plain string":
    checkJson decode("""logs[1]{host|msg}:
"^"|\^""", strict = true),
      """{"logs":[{"host":"^","msg":"^"}]}"""

  test "case S negative: [] under scalar prefix -> BadPath":
    checkErr ekBadPath:
      discard decode("a: 1\na[]: 2", strict = true)

  test "case S negative: [] in a TableKey -> BadPath":
    checkErr ekBadPath:
      discard decode("t[][1]{a}:\nx", strict = true)

  test "case T negative: EOF short of N -> UnterminatedHeredoc":
    checkErr ekUnterminatedHeredoc:
      discard decode("""code: ```[2]
only one line""", strict = true)

  test "case T negative: heredoc header in a table cell -> BadLiteral":
    checkErr ekBadLiteral:
      discard decode("""t[1]{a}:
```[1]""", strict = true)

  test "case T negative: malformed header count -> BadLiteral":
    checkErr ekBadLiteral:
      discard decode("code: ```[x]\nbody", strict = true)
