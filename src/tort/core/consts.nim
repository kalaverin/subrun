## Core-level constants (F6: no magic values in logic modules).

const
  JaccardThreshold* = 0.85       ## table-shape uniformity cutoff, spec §5.1
  StreamChunkSize* = 64 * 1024   ## stream read chunk, design T3
  BatchReadChunk* = 1024 * 1024  ## batch stdin read chunk (whole input to memory)
  MaxUnpackDepth* = 8            ## --one-way: cap on nested JSON-in-string unpack (D19)
