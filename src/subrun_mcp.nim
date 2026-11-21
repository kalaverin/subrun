## subrun MCP-proxy filter (--tort --mcp): the NDJSON JSON-RPC envelope stays
## byte-valid for the client; only result.content[i].text payloads are
## re-encoded JSON -> Tort for model-side token economy.  Fail-open (P4): any
## transform failure on a line emits that line verbatim — the proxy never
## breaks the envelope and never dies on guest data.

import
  std/[strutils, tables],
  pkg/chronicles,
  tort/tort,
  tort/adapters/yyjson_bridge,
  subrun_textlines

# Same sink as subrun.nim (the vendored POSIX-correct RFC-timestamp format —
# see src/subrun_textlines.nim; bare chronicles `textlines` reads CLOCK_UPTIME
# on FreeBSD): stdout is the guest's data channel, wrapper logs go to stderr
# (S1.5, J4).
logStream wrapperLog[subrun_textlines[stderr]]

logScope:
  stream = wrapperLog

const
  DefaultLineLimit* = 10 * 1024 * 1024   ## P4: oversized line → verbatim
  PreambleBegin* = "<<< MCP-PROXY-INJECTED PREAMBLE -- NOT SERVER DATA >>>"
  PreambleEnd* = "<<< END MCP-PROXY-INJECTED PREAMBLE >>>"

# Compile-time embed, same asset as the legacy stream preamble (E1: missing
# asset = compile error).
const McpPreamble = slurp("tort_agent_preamble.md")

type
  McpFilter* = object
    waitCalls: Table[string, bool]  ## ids of pending tools/call  (P2)
    waitLists: Table[string, bool]  ## ids of pending tools/list  (P2)
    preambleDone: bool              ## preamble injected once per process
    outBuf: string                  ## stdout line accumulator (server→client)
    inBuf: string                   ## stdin line accumulator (tap-only)
    lineLimit: int
    oneWay: bool                    ## --one-way: lossy payload encode (D18+D19)
    outWarned: bool                 ## oversize warnings fire once per process
    inWarned: bool

proc initMcpFilter*(lineLimit = DefaultLineLimit; oneWay = false): McpFilter =
  ## Visibility contract (review HIGH-4): the transform strips `outputSchema`
  ## from tools/list and deduplicates `structuredContent` when `content`
  ## exists — the fields are named here so the removals are observable in
  ## the wrapper log, not silent.
  info "MCP filter initialized",
       stripsOutputSchema = true,
       dropsStructuredContent = true,
       oneWay = oneWay
  McpFilter(lineLimit: lineLimit, oneWay: oneWay)

# -----------------------------------------------------------------------------
# TortValue object helpers (oVal is an insertion-ordered pair seq)
# -----------------------------------------------------------------------------

proc getField(v: TortValue; key: string): TortValue =
  ## nil ≡ "field absent" (ast convention).
  if v.isNil or v.kind != tkObject:
    return nil
  for (k, f) in v.oVal:
    if k == key:
      return f
  nil

proc setField(v: TortValue; key: string; f: TortValue) =
  for p in v.oVal.mitems:
    if p[0] == key:
      p[1] = f
      return
  v.oVal.add((key, f))

proc delField(v: TortValue; key: string) =
  if v.isNil or v.kind != tkObject:
    return
  for i in 0 ..< v.oVal.len:
    if v.oVal[i][0] == key:
      v.oVal.delete(i)
      return

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

# -----------------------------------------------------------------------------
# L3: request/response correlation
# -----------------------------------------------------------------------------

proc idKey(id: TortValue): string =
  ## Canonical wait-set key: the JSON serialization of the id value, so the
  ## string "5" and the number 5 stay distinct per JSON-RPC.  nil/absent/null
  ## id → "" (never registered).
  if id.isNil or id.kind == tkNull:
    return ""
  toJsonText(id)

proc scanRequestLine(f: var McpFilter; line: string) =
  ## Tap on client→server: register ids we are allowed to transform answers
  ## for.  Garbage, batches, notifications and other methods are ignored;
  ## the bytes themselves always reach the guest unchanged.
  let v = try:
    parseJson(line)
  except TortError:
    return
  if v.kind != tkObject:
    return                                # JSON-RPC batches unused in MCP stdio
  let meth = v.getField("method")
  if meth.isNil or meth.kind != tkString:
    return
  let key = idKey(v.getField("id"))
  if key.len == 0:
    return                                # notification: no response to wait for
  case meth.sVal
  of "tools/call":
    f.waitCalls[key] = true
  of "tools/list":
    f.waitLists[key] = true
  else:
    discard

# -----------------------------------------------------------------------------
# L4: response transforms
# -----------------------------------------------------------------------------

proc tryFragParse(s: string): TortValue =
  ## --one-way payload helper: full-string JSON parse, nil when not valid JSON.
  try:
    parseJson(s)
  except TortError:
    nil

proc injectPreamble(f: var McpFilter; tortText: string): string =
  ## Preamble lands INSIDE the first transformed text item, bracketed by
  ## explicit markers so the model can tell the injection from server data.
  if f.preambleDone:
    return tortText
  f.preambleDone = true
  PreambleBegin & "\n" & McpPreamble.strip(leading = false) & "\n" &
    PreambleEnd & "\n\n" & tortText

proc transformCallResult(f: var McpFilter; v: TortValue) =
  ## tools/call response: P3 structuredContent dedup + P0 per-item payload
  ## re-encode.  Mutates the envelope TortValue in place.
  let res = v.getField("result")
  if res.isNil or res.kind != tkObject:
    return
  var content = res.getField("content")
  let structured = res.getField("structuredContent")
  if not structured.isNil:
    if not content.isNil and content.kind == tkList and content.lVal.len > 0:
      res.delField("structuredContent")   # pure duplicate of content (P3)
    else:
      # structuredContent is the only carrier: surface it as a text item so
      # the normal pipeline below Tort-encodes it.
      let item = ttObject(@[("type", ttStr("text")),
                            ("text", ttStr(toJsonText(structured)))])
      res.setField("content", ttList(@[item]))
      res.delField("structuredContent")
      content = res.getField("content")
  if content.isNil or content.kind != tkList:
    return
  let tp: TryJsonParse = if f.oneWay: tryFragParse else: nil
  for item in content.lVal:
    if item.isNil or item.kind != tkObject:
      continue
    let typ = item.getField("type")
    if typ.isNil or typ.kind != tkString or typ.sVal != "text":
      continue
    let txt = item.getField("text")
    if txt.isNil or txt.kind != tkString:
      continue
    let payload = try:
      parseJson(txt.sVal)
    except TortError:
      continue                            # not JSON: item verbatim
    if payload.kind != tkObject and payload.kind != tkList:
      continue                            # scalar JSON: nothing to save
    item.setField("text", ttStr(f.injectPreamble(encode(payload, tp))))

proc slimToolsList(v: TortValue) =
  ## tools/list response (P1): outputSchema is the dominant context cost and
  ## is unused by the client protocol flow — delete it from every tool.
  let res = v.getField("result")
  if res.isNil or res.kind != tkObject:
    return
  let tools = res.getField("tools")
  if tools.isNil or tools.kind != tkList:
    return
  for t in tools.lVal:
    if not t.isNil and t.kind == tkObject:
      t.delField("outputSchema")

proc transformLine(f: var McpFilter; line: string): string =
  ## One complete NDJSON line server→client.  Fail-open: any failure returns
  ## the original bytes; only responses to ids we registered are transformed,
  ## everything else passes through verbatim.
  try:
    let v = parseJson(line)
    if v.kind != tkObject:
      return line
    if not v.getField("method").isNil:
      return line                         # server-initiated request/notification
    let key = idKey(v.getField("id"))
    if key.len == 0:
      return line
    var taken: bool
    let isCall = f.waitCalls.take(key, taken)
    let isList = not isCall and f.waitLists.take(key, taken)
    if not isCall and not isList:
      return line                         # unknown id, progress, etc.
    if v.getField("result").isNil:
      return line                         # error response: id consumed, verbatim
    if isCall:
      f.transformCallResult(v)
    else:
      slimToolsList(v)
    toJsonText(v)                         # envelope rebuild: key order kept
  except CatchableError as e:
    debug "mcp: line transform failed, passthrough", error = e.msg
    line

# -----------------------------------------------------------------------------
# L2: line framing (NDJSON; tail without '\n' buffered until more data or EOF)
# -----------------------------------------------------------------------------

proc feedStdout*(f: var McpFilter; chunk: openArray[byte]): seq[byte] =
  ## Accumulate, split complete lines, transform each (fail-open), restore
  ## the '\n' separator unconditionally — the NDJSON framing never changes.
  if chunk.len == 0:
    return @[]
  let oldLen = f.outBuf.len
  f.outBuf.setLen(oldLen + chunk.len)
  copyMem(addr f.outBuf[oldLen], unsafeAddr chunk[0], chunk.len)
  while true:
    let nl = f.outBuf.find('\n')
    if nl < 0:
      if f.outBuf.len > f.lineLimit:
        if not f.outWarned:
          f.outWarned = true
          warn "mcp: stdout line exceeds limit, passthrough", limit = f.lineLimit
        result.add(toBytes(f.outBuf))
        f.outBuf.setLen(0)
      break
    let line = f.outBuf[0 ..< nl]
    f.outBuf.delete(0, nl)
    result.add(toBytes(f.transformLine(line)))
    result.add(byte('\n'))

proc feedStdin*(f: var McpFilter; chunk: openArray[byte]) =
  ## Tap-only: complete lines feed the wait-sets; the bytes themselves are
  ## forwarded to the guest by the caller, unchanged.
  if chunk.len == 0:
    return
  let oldLen = f.inBuf.len
  f.inBuf.setLen(oldLen + chunk.len)
  copyMem(addr f.inBuf[oldLen], unsafeAddr chunk[0], chunk.len)
  while true:
    let nl = f.inBuf.find('\n')
    if nl < 0:
      if f.inBuf.len > f.lineLimit:
        if not f.inWarned:
          f.inWarned = true
          warn "mcp: stdin line exceeds limit, correlation skipped",
               limit = f.lineLimit
        f.inBuf.setLen(0)
      break
    let line = f.inBuf[0 ..< nl]
    f.inBuf.delete(0, nl)
    f.scanRequestLine(line)

proc drain*(f: var McpFilter): seq[byte] =
  ## EOF on guest stdout: the unterminated tail is still a complete message
  ## semantically — attempt the transform, fail-open to verbatim.
  if f.outBuf.len == 0:
    return @[]
  let tail = f.outBuf
  f.outBuf.setLen(0)
  toBytes(f.transformLine(tail))
