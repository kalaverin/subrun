# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

switch("define", "release")
switch("assertions", "off")
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
