## Ports — core-owned contracts in the core's vocabulary (D9).
## Nim idiom: concept types, compile-time satisfaction (design Q1-а).
## All sync: D8 carve-out, no async runtime in this tool.

import ../domain/ast

type
  Chunk* = tuple[text: string, atEof: bool]

  SplitState* = enum
    ssDoc                  ## a complete JSON doc was split off
    ssNeedMore             ## input exhausted mid-document
    ssInvalid              ## garbage at the head of the buffer

  SplitResult* = tuple[state: SplitState, doc: string, rest: string]

  ChunkSource* = concept var s
    s.next() is Chunk

  JsonSink* = concept var s
    s.emit(string)         ## parsed doc → Tort text
    s.junk(string)         ## verbatim passthrough of a non-document chunk
    s.flush()              ## push buffered output NOW (per-doc protocol flush)

  JsonWire* = concept var s
    ## JSON text boundary + JSON text → AST, in core vocabulary.
    s.trySplit(string) is SplitResult
    s.parseDoc(string) is TortValue
