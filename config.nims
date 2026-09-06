# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

switch("define", "danger")
switch("mm", "arc")
switch("opt", "speed")
switch("passC", "-flto")
switch("passL", "-flto")
switch("passL", "-s")
