## ChunkSource over stdin (fd 0). Blocking reads, StreamChunkSize per T3.

import ../core/[consts, ports]
import fdio

type
  StdinChunks* = object

proc next*(s: var StdinChunks): Chunk =
  readChunk(0, StreamChunkSize)
