## MCP-proxy filter — NDJSON framing, wait-set correlation (P2), envelope-
## preserving payload transform (P0/P1/P3), fail-open (P4), preamble (P5).

import unittest2
import std/strutils
import subrun_mcp
import tort/tort
import tort/adapters/yyjson_bridge
import helpers

proc callReq(id: string): string =
  ## Client->server tools/call request line (the stdin tap registers its id).
  "{\"jsonrpc\":\"2.0\",\"id\":" & id &
    ",\"method\":\"tools/call\",\"params\":{\"name\":\"x\",\"arguments\":{}}}\n"

proc callResp(id, text: string): string =
  ## Server->client tools/call result; text must already be JSON-escaped.
  "{\"jsonrpc\":\"2.0\",\"id\":" & id &
    ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"" & text &
    "\"}]}}\n"

suite "mcp filter: framing":
  test "complete line passes through with newline restored":
    var f = initMcpFilter()
    let line = "plain server output\n"
    check bs(f.feedStdout(sb(line))) == line

  test "line split across chunks is reassembled":
    var f = initMcpFilter()
    check f.feedStdout(sb("split line")).len == 0
    check bs(f.feedStdout(sb(" tail\n"))) == "split line tail\n"

  test "drain emits the unterminated EOF tail":
    var f = initMcpFilter()
    discard f.feedStdout(sb("no newline tail"))
    check bs(f.drain()) == "no newline tail"
    check f.drain().len == 0

  test "oversize line passes verbatim (P4)":
    var f = initMcpFilter(lineLimit = 8)
    let long = "this line is way over the limit\n"
    check bs(f.feedStdout(sb(long))) == long

suite "mcp filter: correlation and transform":
  test "tools/call response payload becomes Tort, envelope stays valid":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1")))
    let outp = bs(f.feedStdout(sb(callResp("1", "{\\\"a\\\": 1}"))))
    let v = parseJson(outp.strip())
    let text = v.jget("result").jget("content").jat(0).jget("text").sVal
    check "a: 1" in text
    check PreambleBegin in text          ## first transform carries the preamble
    check PreambleEnd in text

  test "preamble injected exactly once":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1") & callReq("2")))
    let outp1 = bs(f.feedStdout(sb(callResp("1", "{\\\"a\\\": 1}"))))
    let outp2 = bs(f.feedStdout(sb(callResp("2", "{\\\"b\\\": 2}"))))
    check PreambleBegin in outp1
    check PreambleBegin notin outp2
    check "b: 2" in outp2

  test "scalar JSON payload stays verbatim":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1")))
    let line = callResp("1", "42")
    check bs(f.feedStdout(sb(line))) == line

  test "non-JSON text payload stays verbatim":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1")))
    let line = callResp("1", "just plain text")
    check bs(f.feedStdout(sb(line))) == line

  test "structuredContent dedup: dropped when content is present (P3)":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1")))
    let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"a\\\": 1}\"}],\"structuredContent\":{\"a\":1}}}\n"
    let v = parseJson(bs(f.feedStdout(sb(line))).strip())
    check v.jget("result").jget("structuredContent") == nil

  test "structuredContent surfaced as text item when content absent (P3)":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1")))
    let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"structuredContent\":{\"a\":1}}}\n"
    let v = parseJson(bs(f.feedStdout(sb(line))).strip())
    let content = v.jget("result").jget("content")
    check content.kind == tkList
    check "a: 1" in content.jat(0).jget("text").sVal

suite "mcp filter: tools/list slimming (P1)":
  test "outputSchema removed from every tool":
    var f = initMcpFilter()
    f.feedStdin(sb(
      "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}\n"))
    let line = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"tools\":[{\"name\":\"a\",\"outputSchema\":{\"x\":1}},{\"name\":\"b\"}]}}\n"
    let v = parseJson(bs(f.feedStdout(sb(line))).strip())
    let tools = v.jget("result").jget("tools")
    check tools.jat(0).jget("outputSchema") == nil
    check tools.jat(1).jget("outputSchema") == nil
    check tools.jat(0).jget("name").sVal == "a"

suite "mcp filter: fail-open (P4)":
  test "unknown id passes verbatim":
    var f = initMcpFilter()
    let line = callResp("99", "{\\\"a\\\": 1}")
    check bs(f.feedStdout(sb(line))) == line

  test "server-initiated method passes verbatim":
    var f = initMcpFilter()
    let line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n"
    check bs(f.feedStdout(sb(line))) == line

  test "error response consumes the id but stays verbatim":
    var f = initMcpFilter()
    f.feedStdin(sb(callReq("1")))
    let err = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"boom\"}}\n"
    check bs(f.feedStdout(sb(err))) == err
    ## id was taken: a later response with the same id is not transformed
    let late = callResp("1", "{\\\"a\\\": 1}")
    check bs(f.feedStdout(sb(late))) == late

  test "garbage line passes verbatim":
    var f = initMcpFilter()
    let line = "this is not json at all\n"
    check bs(f.feedStdout(sb(line))) == line

suite "mcp filter: --one-way payloads":
  test "one-way unpacks JSON-in-string inside payloads (D19)":
    var f = initMcpFilter(oneWay = true)
    f.feedStdin(sb(callReq("1")))
    let outp = bs(f.feedStdout(sb(
      callResp("1", "{\\\"nested\\\": \\\"{\\\\\\\"x\\\\\\\": 2}\\\"}"))))
    let text = parseJson(outp.strip()).jget("result").jget("content")
      .jat(0).jget("text").sVal
    check "nested.x: 2" in text
