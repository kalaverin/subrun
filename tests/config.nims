# Test builds mirror the project config (flags, assertions, paths) and add src/.
include "../config.nims"
switch("path", thisDir() & "/../src")
