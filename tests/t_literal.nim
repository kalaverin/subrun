## Scalar literal rules — spec §1.1 (typing), §1.2 (escapes), §6 (canon).
## Data-driven tables over the single module that owns text forms of scalars.

import unittest2
import tort/tort
import helpers

suite "literal: token typing (spec §1.1)":
  test "classifyBare: null/bool/int/float/string":
    const cases = [
      ("~", "null"),
      ("+", "true"),
      ("-", "false"),
      ("42", "42"),
      ("-7", "-7"),
      ("-0", "0"),
      ("1e-4", "0.0001"),
      ("3.5", "3.5"),
      ("+5", "\"+5\""),
      (".5", "\".5\""),
      ("007", "\"007\""),
      ("hello", "\"hello\""),
      ("true", "\"true\""),    ## bools are +/- tokens; "true" is a string
      ("false", "\"false\""),
    ]
    for (tok, j) in cases:
      checkJson classifyBare(tok, qcValue, 1, 1), j

suite "literal: escape sets per context (spec §1.2)":
  test "context-specific escapes":
    check unescapeBare("a\\nb", qcValue, 1, 1) == "a\nb"
    check unescapeBare("a\\\\b", qcValue, 1, 1) == "a\\b"
    check unescapeBare("a\\|b", qcCell, 1, 1) == "a|b"
    check unescapeBare("a\\nb", qcCell, 1, 1) == "a\nb"
    check unescapeBare("a\\^b", qcCell, 1, 1) == "a^b"
    check unescapeBare("a\\,b", qcItem, 1, 1) == "a,b"
    check unescapeBare("a\\.b", qcKey, 1, 1) == "a.b"
    check unescapeBare("a\\:b", qcKey, 1, 1) == "a:b"

  test "unknown escape -> BadEscape":
    checkErr ekBadEscape:
      discard unescapeBare("a\\xb", qcCell, 1, 1)
    checkErr ekBadEscape:
      discard unescapeBare("a\\qb", qcKey, 1, 1)

suite "literal: quoted strings":
  test "quote() escapes (QEscape set)":
    check quote("""a"b""") == """"a\"b""""
    check quote("a\\b") == "\"a\\\\b\""
    check quote("a\nb") == "\"a\\nb\""
    check quote("a\tb") == "\"a\\tb\""

  test "parseQuotedAt round-trip":
    for s in ["", "plain", "a\"b", "a\\b", "line1\nline2", "~", " tail "]:
      let (val, next) = parseQuotedAt(quote(s), 0, 1, 1)
      check val == s
      check next == quote(s).len

  test "unterminated quote -> UnterminatedQuote":
    checkErr ekUnterminatedQuote:
      discard parseQuotedAt("\"abc", 0, 1, 1)

suite "literal: needsQuoting (spec §6.2)":
  test "must quote":
    const q = ["~", "+", "-", "42", "3.5", " leading", "trailing ",
               "-x", "+x", "#comment", "a,b", "a\"b", "a\\b", "a\nb"]
    for s in q:
      checkpoint s
      check needsQuoting(s, qcValue)

  test "stays bare":
    const b = ["hello", "a.b", "x-y", "ключ", "true", "false"]
    for s in b:
      checkpoint s
      check not needsQuoting(s, qcValue)

  test "context-sensitive":
    check needsQuoting("a|b", qcCell)
    check not needsQuoting("a|b", qcValue)
    check needsQuoting("{}", qcValue)
    check needsQuoting("[]", qcValue)
    check needsQuoting("^", qcCell)
    check not needsQuoting("", qcCell)     # empty cell stays bare (D6)
    check needsQuoting("", qcValue)

suite "literal: canonFloat (D2/D11)":
  test "canonical forms keep a float marker":
    check canonFloat(0.0) == "0."
    check canonFloat(100.0) == "100."
    check canonFloat(0.5) == "0.5"
    check canonFloat(-2.25) == "-2.25"

  test "NaN/Inf are not representable":
    checkErr ekEncodeImpossible:
      discard canonFloat(1.0 / 0.0)
    checkErr ekEncodeImpossible:
      discard canonFloat(0.0 / 0.0)

suite "literal: heredoc header (v0.1.8, D24)":
  test "valid headers":
    check parseHeredocHeader("```[0]", 1, 1) == 0
    check parseHeredocHeader("```[2]", 1, 1) == 2
    check parseHeredocHeader("```[123]", 1, 1) == 123

  test "not a heredoc -> -1 (EscapedFence path)":
    check parseHeredocHeader("```", 1, 1) == -1
    check parseHeredocHeader("```x", 1, 1) == -1
    check parseHeredocHeader("plain", 1, 1) == -1

  test "malformed headers -> BadLiteral":
    checkErr ekBadLiteral:
      discard parseHeredocHeader("```[]", 1, 1)
    checkErr ekBadLiteral:
      discard parseHeredocHeader("```[2", 1, 1)
    checkErr ekBadLiteral:
      discard parseHeredocHeader("```[2]junk", 1, 1)

suite "literal: squashWs (D18, --one-way only)":
  test "trailing whitespace stripped per line":
    check squashWs("a   \nb  ") == "a\nb"

  test "gcd indent -> tabs":
    check squashWs("f():\n    x = 1\n        deeper") == "f():\n\tx = 1\n\t\tdeeper"

  test "newline runs capped at 3":
    check squashWs("a\n\n\n\n\nb") == "a\n\n\nb"

suite "literal: renderString/renderScalar pick minimal form":
  test "renderString":
    check renderString("hello", qcValue) == "hello"
    check renderString("~", qcValue) == "\"~\""
    check renderString(" trailing ", qcValue) == "\" trailing \""

  test "renderScalar":
    check renderScalar(ttNull(), qcValue) == "~"
    check renderScalar(ttBool(true), qcValue) == "+"
    check renderScalar(ttBool(false), qcValue) == "-"
    check renderScalar(ttInt(42), qcValue) == "42"
    check renderScalar(ttFloat(100.0), qcValue) == "100."
    check renderScalar(ttStr("x"), qcValue) == "x"
