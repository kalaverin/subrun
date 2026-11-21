## Unit tests for subrun --timeout / --signal logic (no built binaries needed).
## The app module is INCLUDE'd, not imported: `import subrun` binds zero
## symbols in this Nim setup (module name == nimble package name; the module
## compiles — its hints appear — but nothing is exported into the importer).
## Include sidesteps the resolution quirk; `when isMainModule` in the app
## still keeps the dispatch path inert here.

import unittest2
import std/[monotimes, posix]
include ../src/subrun

# Readback helpers for the setProcessTitle unit test (mirrors the app's FFI).
when defined(macosx):
  proc pthreadSelf(): pointer {.importc: "pthread_self", header: "<pthread.h>".}
  proc pthreadGetName(thread: pointer, name: cstring, len: int): cint {.importc: "pthread_getname_np", header: "<pthread.h>".}
when defined(linux):
  const PR_GET_NAME = 16
  proc prctlGetName(option: cint, name: cstring): cint {.importc: "prctl", header: "<sys/prctl.h>".}

suite "timeout: parseSignal":
  test "accepts names, any case, SIG prefix, surrounding whitespace":
    check parseSignal("TERM") == SIGTERM
    check parseSignal("sigterm") == SIGTERM
    check parseSignal("SigHup") == SIGHUP
    check parseSignal(" SIGQUIT ") == SIGQUIT
    check parseSignal("USR1") == SIGUSR1

  test "accepts numbers":
    check parseSignal("15") == SIGTERM
    check parseSignal("1") == SIGHUP

  test "rejects garbage, out-of-range, and uncatchable signals":
    expect ValueError:
      discard parseSignal("BOGUS")
    expect ValueError:
      discard parseSignal("0")
    expect ValueError:
      discard parseSignal("32")
    expect ValueError:
      discard parseSignal("SIGKILL")
    expect ValueError:
      discard parseSignal("9")
    expect ValueError:
      discard parseSignal("SIGSTOP")

suite "timeout: checkTimeout":
  test "disabled at 0 even with a startTime deep in the past":
    var r: Runner
    r.cfg.timeout = 0
    r.startTime = getMonoTime() - initDuration(seconds = 100)
    checkTimeout(r)
    check r.shutdown == shsNone

  test "fires shsTimeout when the deadline has passed":
    var r: Runner
    r.cfg.timeout = 1.0
    r.cfg.signal = SIGTERM
    r.guestPid = Pid(999999)      # nonexistent: signalGuestGroup hits ESRCH, no-op
    r.startTime = getMonoTime() - initDuration(seconds = 5)
    checkTimeout(r)
    check r.shutdown == shsTimeout

  test "no-op while another shutdown owns the timeline":
    var r: Runner
    r.cfg.timeout = 1.0
    r.startTime = getMonoTime() - initDuration(seconds = 5)
    r.shutdown = shsForwardedSignal
    checkTimeout(r)
    check r.shutdown == shsForwardedSignal

  test "not yet expired stays shsNone":
    var r: Runner
    r.cfg.timeout = 3600.0
    r.startTime = getMonoTime()
    checkTimeout(r)
    check r.shutdown == shsNone

suite "title: setProcessTitle":
  test "applies the name and reads it back":
    setProcessTitle("torttitle1")
    when defined(macosx):
      var buf: array[64, char]
      check pthreadGetName(pthreadSelf(), cast[cstring](addr buf), buf.sizeof) == 0
      check $cast[cstring](addr buf) == "torttitle1"
    else:
      var buf: array[16, char]
      check prctlGetName(PR_GET_NAME, cast[cstring](addr buf)) == 0
      check $cast[cstring](addr buf) == "torttitle1"

suite "timeout: cadence":
  test "disarmed timeout leaves cadence untouched":
    var r: Runner
    r.lastActivity = getMonoTime()
    check r.cadence() == PollMsActive
    r.lastActivity = getMonoTime() - initDuration(seconds = 120)
    check r.cadence() == PollMsIdle1

  test "near deadline caps the poll timeout at the remaining time":
    var r: Runner
    r.cfg.timeout = 0.05                  # 50 ms to the deadline
    r.startTime = getMonoTime()
    r.lastActivity = getMonoTime()
    let ms = r.cadence()
    check ms >= 1
    check ms <= 50

  test "far deadline keeps the normal backoff":
    var r: Runner
    r.cfg.timeout = 3600.0
    r.startTime = getMonoTime()
    r.lastActivity = getMonoTime()
    check r.cadence() == PollMsActive

  test "shutdown in progress always ticks at the active cadence":
    var r: Runner
    r.cfg.timeout = 0.05
    r.startTime = getMonoTime() - initDuration(seconds = 5)
    r.lastActivity = getMonoTime()
    r.shutdown = shsTimeout
    check r.cadence() == PollMsActive
