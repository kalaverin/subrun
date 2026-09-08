# Test builds mirror the project config (flags, assertions, paths) and add src/.
include "../config.nims"
switch("path", thisDir() & "/../src")
# Unit tests include the app module directly (import binds zero symbols when
# the module name equals the nimble package name); this define keeps the
# app's CLI dispatch block inert inside test binaries.
switch("define", "subrunTesting")
