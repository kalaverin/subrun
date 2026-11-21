# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# The vendored chronicles sink (src/subrun_textlines.nim) is referenced by
# name in the logStream macro; macro-generated imports resolve via --path
# only (not relative to the importing file), so src/ must be on it.
switch("path", thisDir() & "/src")

switch("define", "release")
switch("assertions", "on")    # unittest2 baseline + cheap internal invariants
switch("panics", "on")

switch("opt", "speed")
switch("threads", "on")
switch("mm", "atomicArc")

switch("passC", "-O3")
switch("passC", "-march=native")
switch("passC", "-flto")
switch("passC", "-fdata-sections")
switch("passC", "-ffunction-sections")
switch("passC", "-fomit-frame-pointer")

switch("passL", "-s")
switch("passL", "-flto")
