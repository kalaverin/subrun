# app/subrun.nim
# A transparent POSIX stdio/lifecycle proxy between a host (the invoking
# process: supervisord, MCP client, terminal) and a guest (the spawned
# process).  Byte-exact stdio forwarding, exact exit-code fidelity, bounded
# orphan-free teardown.  Contract: .serena/memories/solutions/subrun/
# overview-fixes/solution.md

import
  std/[posix, os, oserrors, monotimes, times, strutils, tables],
  pkg/chronicles,
  pkg/cligen

# All wrapper logs go to stderr — stdout is the guest's data channel
# (MCP JSON-RPC), it must stay clean (S1.5, J4).
logStream wrapperLog[textlines[stderr]]

logScope:
  stream = wrapperLog

# -----------------------------------------------------------------------------
# Platform FFI
# -----------------------------------------------------------------------------

# poll(2): portable across linux/freebsd/macosx for our tiny fd set (≤6).
# epoll/kqueue deliberately not used (they would create platform branches for
# zero gain at this scale; signals wake poll via EINTR since handlers are
# installed).
type
  TPollFd {.importc: "struct pollfd", header: "<poll.h>".} = object
    fd*: cint
    events*: cshort
    revents*: cshort

const
  POLLIN = 0x0001.cshort
  POLLOUT = 0x0004.cshort
  POLLERR = 0x0008.cshort
  POLLHUP = 0x0010.cshort
  POLLNVAL = 0x0020.cshort

proc poll(fds: ptr TPollFd, nfds: cint, timeout: cint): cint {.importc, header: "<poll.h>".}

when defined(linux):
  const PR_SET_PDEATHSIG = 1
  const PR_SET_NAME = 15
  proc prctlDeathsig(option, sig: cint): cint {.importc: "prctl", header: "<sys/prctl.h>".}
  proc prctlSetName(option: cint, name: cstring): cint {.importc: "prctl", header: "<sys/prctl.h>".}

when defined(freebsd):
  const PROC_PDEATHSIG_CTL = 14
  const P_PID = 0
  proc procctl(idtype, id, cmd: cint, data: pointer): cint {.importc, header: "<sys/procctl.h>".}
  proc setproctitle(fmt: cstring) {.varargs, importc, header: "<unistd.h>".}

when defined(macosx):
  proc pthread_setname_np(name: cstring): cint {.importc, header: "<pthread.h>".}

# Nim's quit() clamps to [-128, 127], mangling 128+signum codes; use C exit
# for those so the host sees the conventional code (S2.1).
proc cexit(status: cint) {.importc: "exit", header: "<stdlib.h>".}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

const
  DefaultGraceTimeout = 5.0
  DefaultHardTimeout = 10.0
  ReadChunk = 65536              # one read(2) size
  StreamCap = 1024 * 1024        # per-direction buffer ceiling (~3 MiB total)
  PollMsActive = 100             # cadence: active / shutdown
  PollMsIdle1 = 1000             # cadence: idle >= 60s
  PollMsIdle2 = 3000             # cadence: idle >= 600s
  IdleThreshold1Sec = 60
  IdleThreshold2Sec = 600

# Catchable signals we handle: forward-all-catchable minus SIGPIPE (SIG_IGN)
# and minus the synchronous fault class {SEGV, BUS, FPE, ILL, TRAP, EMT, SYS}
# (our own crashes, not host events — default disposition kept).
# Built at runtime: std/posix exposes several of these as `var importc`,
# and SIGWINCH/SIGIO are missing entirely on some targets.
when not declared(SIGWINCH):
  const SIGWINCH = cint(28)   # linux/freebsd/macosx all use 28
when not declared(SIGIO):
  when defined(linux):
    const SIGIO = cint(29)
  else:
    const SIGIO = cint(23)    # freebsd/macosx

var gHandledSignals: seq[cint]

let DeadlySignals = [SIGHUP, SIGINT, SIGQUIT, SIGTERM]

proc initHandledSignals() =
  gHandledSignals = @[SIGHUP, SIGINT, SIGQUIT, SIGTERM,
    SIGUSR1, SIGUSR2, SIGCHLD, SIGCONT,
    SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH,
    SIGALRM, SIGVTALRM, SIGPROF,
    SIGXCPU, SIGXFSZ, SIGURG, SIGIO]

# -----------------------------------------------------------------------------
# Signal bookkeeping (async-signal-safe: handler only sets a flag)
# -----------------------------------------------------------------------------

var gSigPending: array[0..31, uint8]

proc onSignal(sig: cint) {.noconv.} =
  if sig >= 0 and sig <= 31:
    gSigPending[sig] = 1

# -----------------------------------------------------------------------------
# Types
# -----------------------------------------------------------------------------

type
  FdKind = enum fkStdin, fkStdout, fkStderr

  StreamState = enum
    ssOpen      # read src (if buffer not full), write dst (if buffer non-empty)
    ssDraining  # src hit EOF; flush remaining buffer to dst, then close dst
    ssClosed    # direction is dead, never enters the poll set

  Stream = object
    srcFd: cint           # -1 = source done
    dstFd: cint           # -1 = destination done
    buf: string
    readOff: int
    state: StreamState

  ShutdownSource = enum
    shsNone              # no shutdown in progress
    shsForwardedSignal   # deadly signal already delivered by forwarding —
                         # we do NOT send our own SIGTERM (no invented events)
    shsHostDied          # ppid-poll detected host death — we SIGTERM the group

  Config = object
    binary: string
    args: seq[string]
    cwd: string           # resolved absolute; --cwd or invocation cwd (S4.1)
    logDir: string        # resolved absolute, anchored at invocation cwd (S4.4)
    graceTimeout: float
    hardTimeout: float
    env: seq[(string, string)]
    verbose: bool
    debugMode: bool       # derived once at startup (S5.5)

  Logger = object
    enabled: bool
    file: File
    currentSection: FdKind
    sectionOpen: bool

  Runner = object
    cfg: Config
    guestPid: Pid         # == guest pgid after setpgid(0,0) — no separate field
    hostPid: Pid          # our ppid at start
    guestExited: bool
    gaveUp: bool
    lastStatus: cint      # single writer: the reap in the loop
    shutdown: ShutdownSource
    shutdownStart: MonoTime
    sigkillSent: bool
    streams: array[FdKind, Stream]
    pollFds: array[6, TPollFd]     # rebuilt from live state every iteration
    pollMap: array[6, tuple[kind: FdKind, isSrc: bool]]
    logger: Logger
    logSessionCounter: int
    lastActivity: MonoTime

# -----------------------------------------------------------------------------
# Low-level fd helpers
# -----------------------------------------------------------------------------

proc closeFd(fd: cint) =
  if fd >= 0:
    discard posix.close(fd)

proc setCloexec(fd: cint) =
  let flags = posix.fcntl(fd, F_GETFD, 0)
  if flags >= 0:
    discard posix.fcntl(fd, F_SETFD, flags or FD_CLOEXEC)

proc setNonBlocking(fd: cint) =
  let flags = posix.fcntl(fd, F_GETFL, 0)
  if flags >= 0:
    discard posix.fcntl(fd, F_SETFL, flags or O_NONBLOCK)

# O_NONBLOCK on inherited 0/1/2 is a flag of the SHARED open file description:
# it may leak to the host (e.g. a terminal).  Save at startup, restore before
# exit (S6 / level-4 contract).
var gSavedFdFlags: array[0..2, cint] = [-1, -1, -1]

proc saveFdFlags() =
  for fd in 0..2:
    gSavedFdFlags[fd] = posix.fcntl(cint(fd), F_GETFL, 0)

proc restoreFdFlags() =
  for fd in 0..2:
    if gSavedFdFlags[fd] >= 0:
      discard posix.fcntl(cint(fd), F_SETFL, gSavedFdFlags[fd])
      gSavedFdFlags[fd] = -1

proc restoreOneFdFlag(fd: cint) =
  ## Per-fd restore before a mid-run close of an inherited fd: closing our
  ## descriptor does NOT reset flags on the shared description, so the
  ## restore must happen BEFORE the close, not only at exit.
  if fd >= 0 and fd <= 2 and gSavedFdFlags[fd] >= 0:
    discard posix.fcntl(fd, F_SETFL, gSavedFdFlags[fd])
    gSavedFdFlags[fd] = -1

# -----------------------------------------------------------------------------
# Signal handlers setup / platform hooks
# -----------------------------------------------------------------------------

proc installHandler(sig: cint, handler: typeof(SIG_DFL)) =
  ## sigaction WITHOUT SA_RESTART: libc signal() sets SA_RESTART (BSD
  ## semantics on macOS and glibc alike), which would restart poll()/read()
  ## after a caught signal and silently degrade the frozen EINTR instant-wake
  ## (S6.7/S6.9) down to the cadence bound.  flags=0: poll wakes instantly.
  var sa: Sigaction
  sa.sa_handler = handler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard posix.sigaction(sig, sa)

proc setupSignalHandlers() =
  for sig in gHandledSignals:
    installHandler(sig, onSignal)
  installHandler(SIGPIPE, SIG_IGN)

proc setPdeathsig() =
  # SIGKILL, not SIGTERM: an abnormal wrapper death must not leave a
  # TERM-trapping guest alive ("no hanging processes" doctrine).
  when defined(linux):
    discard prctlDeathsig(PR_SET_PDEATHSIG, cint(SIGKILL))
  elif defined(freebsd):
    var sig = cint(SIGKILL)
    discard procctl(cint(P_PID), cint(0), cint(PROC_PDEATHSIG_CTL), addr sig)
  # macos: no such mechanism — the net there is pipe EOF/EPIPE on our death.

proc setProcessTitle(title: string) =
  when defined(linux):
    var buf: array[16, char]
    let n = min(title.len, 15)
    if n > 0:
      copyMem(addr buf[0], unsafeAddr title[0], n)
    buf[n] = '\0'
    discard prctlSetName(PR_SET_NAME, cast[cstring](addr buf[0]))
  elif defined(freebsd):
    setproctitle("%s", cstring(title))
  elif defined(macosx):
    var buf: array[64, char]
    let n = min(title.len, 63)
    if n > 0:
      copyMem(addr buf[0], unsafeAddr title[0], n)
    buf[n] = '\0'
    discard pthread_setname_np(cast[cstring](addr buf[0]))

# -----------------------------------------------------------------------------
# Config resolution
# -----------------------------------------------------------------------------

proc parseEnv(s: string): (string, string) =
  let idx = s.find('=')
  if idx < 0:
    raise newException(ValueError, "invalid env format (expected KEY=VALUE): " & s)
  result = (s[0 ..< idx], s[idx + 1 .. ^1])

proc resolveCwd(cwd: string): string =
  ## Explicit --cwd wins; otherwise the invocation cwd is preserved.
  ## Auto-detection is banned by contract (S4.1): the wrapper never
  ## second-guesses the caller's invocation contract.
  if cwd.len > 0:
    return normalizedPath(absolutePath(cwd))
  return getCurrentDir()

proc resolveLogDir(logDir: string): string =
  ## Logs are the wrapper's artifact: anchored at the invocation cwd,
  ## they do not follow the guest's chdir (S4.4).
  return normalizedPath(absolutePath(logDir, getCurrentDir()))

proc detectDebugMode(): bool =
  ## Symlink convention: invoked under a name containing "debug"
  ## (e.g. subrun-debug) — gates SIGUSR1/SIGUSR2 session logging.
  return "debug" in extractFilename(paramStr(0))

# -----------------------------------------------------------------------------
# Session logger (capture-only, debug-gated; delivered bytes only)
# -----------------------------------------------------------------------------

proc sectionLabel(kind: FdKind): string =
  case kind
  of fkStdin: "stdin"
  of fkStdout: "stdout"
  of fkStderr: "stderr"

proc openLogger(r: var Runner) =
  let ts = format(utc(now()), "yyyy'-'MM'-'dd'_'HH'-'mm'-'ss")
  let pid = getCurrentProcessId()
  let base = extractFilename(r.cfg.binary)
  let dir = r.cfg.logDir / base
  inc r.logSessionCounter
  try:
    createDir(dir)
    let path = dir / (ts & "_" & $pid & "_" & $r.logSessionCounter & ".log")
    r.logger.file = open(path, fmWrite)
    r.logger.enabled = true
    r.logger.sectionOpen = false
    info "Logging started", path
  except CatchableError as ex:
    # Logging is subordinate to proxying (S5.1): failure never stops us.
    warn "Failed to start logging", error = ex.msg
    r.logger.enabled = false

proc closeLogger(r: var Runner) =
  if not r.logger.enabled:
    return
  close(r.logger.file)
  r.logger.enabled = false
  r.logger.sectionOpen = false
  info "Logging stopped"

proc captureToSessionLog(r: var Runner, kind: FdKind, data: pointer, len: int) =
  ## Records bytes actually DELIVERED to the destination (uniform for all
  ## three directions).  Capture-only: never touches the stream itself.
  if not r.logger.enabled or len <= 0:
    return
  if not r.logger.sectionOpen or r.logger.currentSection != kind:
    writeLine(r.logger.file, "\n" & sectionLabel(kind) & ":\n" & repeat('-', 80))
    r.logger.currentSection = kind
    r.logger.sectionOpen = true
  discard writeBuffer(r.logger.file, data, len)
  flushFile(r.logger.file)

# -----------------------------------------------------------------------------
# Pipes & spawn
# -----------------------------------------------------------------------------

type PipeSet = array[FdKind, tuple[r, w: cint]]

proc setupPipes(pipes: var PipeSet) =
  for kind in FdKind:
    var fds: array[2, cint]
    if posix.pipe(fds) != 0:
      raise newException(OSError, "pipe failed: " & $osLastError())
    pipes[kind] = (fds[0], fds[1])
  # Wrapper-side ends must not leak to grandchildren (S6.5).
  setCloexec(pipes[fkStdin].w)
  setCloexec(pipes[fkStdout].r)
  setCloexec(pipes[fkStderr].r)
  setNonBlocking(pipes[fkStdin].w)
  setNonBlocking(pipes[fkStdout].r)
  setNonBlocking(pipes[fkStderr].r)

proc buildArgvEnvp(cfg: Config): auto =
  ## Built in the PARENT before fork: no Nim allocations in the forked guest.
  let argv = allocCStringArray(@[cfg.binary] & cfg.args)
  var envMap: Table[string, string]
  for k, v in envPairs():
    envMap[k] = v
  for (k, v) in cfg.env:
    envMap[k] = v        # explicit override wins (S4.2)
  var envSeq: seq[string]
  for k, v in envMap:
    envSeq.add(k & "=" & v)
  let envp = allocCStringArray(envSeq)
  (argv, envp)

proc spawnGuest(cfg: Config, pipes: var PipeSet): Pid =
  let (argv, envp) = buildArgvEnvp(cfg)
  let pid = posix.fork()
  if pid < 0:
    raise newException(OSError, "fork failed: " & $osLastError())
  if pid == 0:
    # --- guest, pre-exec ---
    for sig in gHandledSignals:
      discard posix.signal(sig, SIG_DFL)
    discard posix.signal(SIGPIPE, SIG_DFL)
    discard setpgid(0, 0)             # own process group (two-sided; parent too)

    closeFd(pipes[fkStdin].w)
    closeFd(pipes[fkStdout].r)
    closeFd(pipes[fkStderr].r)
    if posix.dup2(pipes[fkStdin].r, 0) < 0: quit(126)
    if posix.dup2(pipes[fkStdout].w, 1) < 0: quit(126)
    if posix.dup2(pipes[fkStderr].w, 2) < 0: quit(126)
    closeFd(pipes[fkStdin].r)
    closeFd(pipes[fkStdout].w)
    closeFd(pipes[fkStderr].w)

    if posix.chdir(cstring(cfg.cwd)) != 0:
      stderr.writeLine("subrun: failed to chdir to " & cfg.cwd)
      quit(126)

    setPdeathsig()

    discard posix.execve(cstring(cfg.binary), argv, envp)
    stderr.writeLine("subrun: execve failed for " & cfg.binary & ": " & $strerror(errno))
    quit(126)
  else:
    # Two-sided setpgid: closes the race of forwarding kill(-pid) before the
    # guest's own setpgid lands (idempotent; EACCES/ESRCH are harmless here).
    discard setpgid(pid, pid)
    closeFd(pipes[fkStdin].r)
    closeFd(pipes[fkStdout].w)
    closeFd(pipes[fkStderr].w)
    # Parent-side copies of argv/envp are dead weight after fork (the guest
    # owns its own post-fork copies until execve).
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    return pid

# -----------------------------------------------------------------------------
# Signal policy (runs in the main loop, never in the handler)
# -----------------------------------------------------------------------------

proc forwardSignal(r: var Runner, sig: cint) =
  ## Group delivery: covers the guest's whole tree, no terminal doubles.
  if r.guestExited:
    return
  if posix.kill(Pid(-int(r.guestPid)), sig) < 0 and errno != ESRCH:
    warn "Signal forward failed", sig = sig, error = $strerror(errno)

proc signalGuestGroup(r: var Runner, sig: cint) =
  ## Escalation-only variant with lifecycle logging.
  if r.guestExited:
    return
  if posix.kill(Pid(-int(r.guestPid)), sig) < 0:
    if errno != ESRCH:
      warn "Escalation signal failed", sig = sig, error = $strerror(errno)
  else:
    info "Sent signal to guest group", sig = sig, pgid = int(r.guestPid)

proc jobControlStop(r: var Runner, sig: cint) =
  ## ssh/sudo dance: guest stops first, then we stop with default
  ## disposition; on wake (SIGCONT, delivered via gSigPending) we reinstall
  ## and the loop forwards CONT to the guest.
  forwardSignal(r, sig)
  discard posix.signal(sig, SIG_DFL)
  discard posix.kill(getpid(), sig)
  installHandler(sig, onSignal)

proc reapGuest(r: var Runner) =
  var status: cint
  while true:
    let ret = waitpid(r.guestPid, status, WNOHANG)
    if ret > 0:
      if r.guestExited:
        return
      r.lastStatus = status
      r.guestExited = true
      if WIFEXITED(status):
        info "Guest exited", pid = int(r.guestPid), code = int(WEXITSTATUS(status))
      elif WIFSIGNALED(status):
        info "Guest exited", pid = int(r.guestPid), code = 128 + int(WTERMSIG(status))
      else:
        info "Guest exited", pid = int(r.guestPid), code = 1
      # stdin to a dead guest is pointless: drop buffer (S1.4), stop polling.
      var s = addr r.streams[fkStdin]
      closeFd(s.dstFd)
      s.dstFd = -1
      s.srcFd = -1                    # fd 0 itself stays open (host's channel)
      s.buf.setLen(0)
      s.readOff = 0
      s.state = ssClosed
      return
    if ret == 0:
      return
    if errno == EINTR:
      continue                        # S6.3: retry, never a false break
    if errno == ECHILD:
      if r.guestExited:
        return                    # late SIGCHLD flag; zombie already consumed
      # Unreachable by design (only we ever reap our guest).  Leaving
      # guestExited=false here would hang the loop forever (exit invariant
      # unreachable), so fail safe and loud (review delta 19.3/L4).
      error "waitpid: ECHILD with live guest flag — treating as give-up"
      r.guestExited = true
      r.gaveUp = true             # finalize: exit 1, lastStatus never read
      return
    error "waitpid failed", error = $strerror(errno)
    return

proc beginShutdown(r: var Runner, src: ShutdownSource) =
  if r.shutdown != shsNone:
    return                            # repeated deadly: forwarded, timers unchanged
  r.shutdown = src
  r.shutdownStart = getMonoTime()
  info "Shutdown initiated", source = $src,
       graceTimeout = r.cfg.graceTimeout, hardTimeout = r.cfg.hardTimeout
  # stdin EOF at t0, always (stage 04.3).
  var s = addr r.streams[fkStdin]
  closeFd(s.dstFd)
  s.dstFd = -1
  s.srcFd = -1
  s.buf.setLen(0)
  s.readOff = 0
  s.state = ssClosed
  if src == shsHostDied:
    # Nobody else will manage the guest: the graceful signal is ours to send.
    signalGuestGroup(r, SIGTERM)

proc tickEscalation(r: var Runner) =
  ## V2 timeline.  Group signals only while the guest lives; the hard-timeout
  ## give-up runs ALWAYS — including the drain phase — so a stalled drain
  ## after a deadly signal is still bounded (traversal delta, stage 18).
  let elapsedSec = float(inMilliseconds(getMonoTime() - r.shutdownStart)) / 1000.0
  if not r.guestExited and not r.sigkillSent and elapsedSec >= r.cfg.graceTimeout:
    warn "Grace timeout expired, escalating to SIGKILL"
    signalGuestGroup(r, SIGKILL)
    r.sigkillSent = true
  if elapsedSec >= r.cfg.hardTimeout:
    error "Hard timeout: giving up (bounded exit, guest may survive)"
    r.gaveUp = true

proc checkHostAlive(r: var Runner) =
  ## Reparenting detection: a dead host means we get reparented (to
  ## launchd/pid 1), so getppid() diverges from the captured hostPid.
  ## kill(ppid, 0) cannot meet the frozen latency bound: if the host dies
  ## before our first getppid(), hostPid is captured as 1 and ESRCH never
  ## fires.  Residual (host died before exec AND terminal stdin): the guest
  ## still learns via pipe EOF when the host's pipe ends close.
  if getppid() != r.hostPid:
    info "Host died (reparented)", hostPid = int(r.hostPid)
    beginShutdown(r, shsHostDied)

proc toggleSessionLog(r: var Runner, sig: cint) =
  ## Debug-mode only (consumed, never forwarded — stage 03.3).
  if sig == SIGUSR1:
    if r.logger.enabled:
      closeLogger(r)
    openLogger(r)
  else:
    closeLogger(r)

proc drainSignals(r: var Runner) =
  for sig in 1..31:
    if gSigPending[sig] == 0:
      continue
    gSigPending[sig] = 0
    let s = cint(sig)
    if s == SIGCHLD:
      reapGuest(r)
    elif s == SIGUSR1 or s == SIGUSR2:
      if r.cfg.debugMode:
        toggleSessionLog(r, s)
      else:
        forwardSignal(r, s)
    elif s == SIGTSTP or s == SIGTTIN or s == SIGTTOU:
      jobControlStop(r, s)
    elif s == SIGCONT:
      forwardSignal(r, s)
    else:
      forwardSignal(r, s)
      if s in DeadlySignals:
        beginShutdown(r, shsForwardedSignal)

# -----------------------------------------------------------------------------
# I/O engine
# -----------------------------------------------------------------------------

proc pending(s: Stream): int =
  s.buf.len - s.readOff

proc appendCompact(s: var Stream, data: pointer, len: int) =
  ## Append with cheap compaction: reset when fully consumed, compact at
  ## readOff >= 64 KiB so the buffer does not collect garbage.
  if s.readOff == s.buf.len:
    s.buf.setLen(0)
    s.readOff = 0
  elif s.readOff >= 65536:
    copyMem(addr s.buf[0], addr s.buf[s.readOff], s.buf.len - s.readOff)
    s.buf.setLen(s.buf.len - s.readOff)
    s.readOff = 0
  let oldLen = s.buf.len
  s.buf.setLen(oldLen + len)
  copyMem(addr s.buf[oldLen], data, len)

proc closeHostFd(fd: cint) =
  restoreOneFdFlag(fd)
  closeFd(fd)

proc closeDirection(r: var Runner, kind: FdKind) =
  ## Permanent failure or deliberate teardown of one direction (S1.8).
  var s = addr r.streams[kind]
  closeHostFd(s.srcFd)
  s.srcFd = -1
  closeHostFd(s.dstFd)
  s.dstFd = -1
  s.buf.setLen(0)
  s.readOff = 0
  s.state = ssClosed

proc tryFlush(r: var Runner, kind: FdKind) =
  var s = addr r.streams[kind]
  if s.dstFd < 0:
    return
  while pending(s[]) > 0:
    let n = posix.write(s.dstFd, addr s.buf[s.readOff], pending(s[]))
    if n > 0:
      captureToSessionLog(r, kind, addr s.buf[s.readOff], n)
      s.readOff += n
      if s.readOff >= s.buf.len:
        s.buf.setLen(0)
        s.readOff = 0
    elif errno == EINTR:
      continue
    elif errno == EAGAIN or errno == EWOULDBLOCK:
      break                         # wait for POLLOUT
    else:
      error "Write error, closing direction", fd = $kind, error = $strerror(errno)
      closeDirection(r, kind)
      return
  if s.state == ssDraining and pending(s[]) == 0:
    # EOF timing fidelity (S1.3): for outputs dstFd is our own fd 1/2 —
    # closing it gives the host an immediate EOF, not one deferred to exit.
    closeHostFd(s.dstFd)
    s.dstFd = -1
    s.state = ssClosed

proc onSourceEof(r: var Runner, kind: FdKind) =
  var s = addr r.streams[kind]
  closeHostFd(s.srcFd)
  s.srcFd = -1
  if kind == fkStdin:
    # Host stdin EOF: the unwritten buffer is dropped (S1.4 — data addressed
    # to a departing reader); the guest receives EOF.
    closeFd(s.dstFd)              # guest pipe — not a host fd, no flag restore
    s.dstFd = -1
    s.buf.setLen(0)
    s.readOff = 0
    s.state = ssClosed
  else:
    s.state = ssDraining
    tryFlush(r, kind)

proc pumpRead(r: var Runner, kind: FdKind) =
  var s = addr r.streams[kind]
  if s.srcFd < 0 or s.state == ssClosed:
    return
  var chunk: array[ReadChunk, byte]
  var n = posix.read(s.srcFd, addr chunk[0], ReadChunk)
  while n < 0 and errno == EINTR:
    n = posix.read(s.srcFd, addr chunk[0], ReadChunk)   # S6.3: retry
  if n > 0:
    appendCompact(s[], addr chunk[0], int(n))
    tryFlush(r, kind)
  elif n == 0:
    onSourceEof(r, kind)
  elif errno == EAGAIN or errno == EWOULDBLOCK:
    discard
  else:
    warn "Read error, treating as EOF", fd = $kind, error = $strerror(errno)
    onSourceEof(r, kind)

proc rebuildPollSet(r: var Runner): cint =
  ## Poll set is rebuilt from LIVE state every iteration: a closed fd can
  ## never linger in poll (the M1/POLLNVAL spin class is dead by construction).
  var n = 0
  for kind in FdKind:
    let s = r.streams[kind]
    if s.state == ssClosed:
      continue
    if s.srcFd >= 0 and s.state == ssOpen and pending(s) + ReadChunk <= StreamCap:
      r.pollFds[n] = TPollFd(fd: s.srcFd, events: POLLIN, revents: 0)
      r.pollMap[n] = (kind, true)
      inc n
    if s.dstFd >= 0 and pending(s) > 0:
      r.pollFds[n] = TPollFd(fd: s.dstFd, events: POLLOUT, revents: 0)
      r.pollMap[n] = (kind, false)
      inc n
  return cint(n)

proc cadence(r: Runner): cint =
  ## Dynamic poll timeout (stage 09.6): shutdown always ticks at 100ms;
  ## steady state backs off by idle time.  Signal/guest-death latency is
  ## unaffected — EINTR and the SIGCHLD flag wake poll at any backoff.
  if r.shutdown != shsNone:
    return PollMsActive
  let idleSec = int(inSeconds(getMonoTime() - r.lastActivity))
  if idleSec >= IdleThreshold2Sec:
    return PollMsIdle2
  if idleSec >= IdleThreshold1Sec:
    return PollMsIdle1
  return PollMsActive

# -----------------------------------------------------------------------------
# Main loop & finalize
# -----------------------------------------------------------------------------

proc finalize(r: var Runner): int =
  ## No waitpid here — the guest is already reaped by the loop (or
  ## deliberately abandoned on the give-up path).  Never blocks (H2 dead).
  closeLogger(r)
  for kind in FdKind:
    if r.streams[kind].state != ssClosed:
      closeDirection(r, kind)
  if r.gaveUp or not r.guestExited:
    return 1                        # S2.2: never invent a guest code
  let status = r.lastStatus
  if WIFEXITED(status):
    return int(WEXITSTATUS(status))
  if WIFSIGNALED(status):
    return 128 + int(WTERMSIG(status))
  return 1

proc runLoop(r: var Runner, pipes: PipeSet): int =
  r.streams[fkStdin] = Stream(srcFd: 0, dstFd: pipes[fkStdin].w, state: ssOpen)
  r.streams[fkStdout] = Stream(srcFd: pipes[fkStdout].r, dstFd: 1, state: ssOpen)
  r.streams[fkStderr] = Stream(srcFd: pipes[fkStderr].r, dstFd: 2, state: ssOpen)
  r.lastActivity = getMonoTime()

  # Born-orphan rule (stage 19.1): hostPid==1 means the host died before our
  # first getppid() — a guest nobody manages is torn down per V2.
  if int(r.hostPid) == 1:
    beginShutdown(r, shsHostDied)

  while true:
    drainSignals(r)
    # Missed-SIGCHLD safety (review delta 19.3/M2): a SIGCHLD landing in the
    # window between fork() and handler install (delta 19.2 ordering) leaves
    # no pending flag, so reap unconditionally every iteration — one cheap
    # waitpid(WNOHANG) — or the exit invariant becomes unreachable.
    if not r.guestExited:
      reapGuest(r)

    # Exit invariant: guest reaped AND both outputs fully drained (H1 dead).
    if r.guestExited and
       r.streams[fkStdout].state == ssClosed and
       r.streams[fkStderr].state == ssClosed:
      break

    if r.shutdown != shsNone:
      tickEscalation(r)
      if r.gaveUp:
        break
    else:
      checkHostAlive(r)

    let nfds = rebuildPollSet(r)
    let timeoutMs = cadence(r)
    let n = poll(addr r.pollFds[0], nfds, cint(timeoutMs))
    if n > 0:
      r.lastActivity = getMonoTime()
      for i in 0 ..< int(nfds):
        let revents = r.pollFds[i].revents
        if revents == 0:
          continue
        let (kind, isSrc) = r.pollMap[i]
        if isSrc:
          if (revents and (POLLIN or POLLHUP or POLLERR or POLLNVAL)) != 0:
            pumpRead(r, kind)
        else:
          if (revents and (POLLOUT or POLLHUP or POLLERR or POLLNVAL)) != 0:
            tryFlush(r, kind)
    elif n < 0 and errno != EINTR:
      error "poll failed", error = $strerror(errno)
      break

  return finalize(r)

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

proc run(
    graceTimeout: float = DefaultGraceTimeout,
    hardTimeout: float = DefaultHardTimeout,
    cwd: string = "",
    logDir: string = "var/subrunner/log",
    env: seq[string] = @[],
    verbose: bool = false,
    command: seq[string]
): int =
  ## Run a guest process with byte-exact stdio proxying and bounded,
  ## orphan-free lifecycle management.
  ##
  ## Examples:
  ##   subrun -- /usr/bin/node /path/to/mcp-server.js
  ##   subrun --grace-timeout 3 --hard-timeout 8 -- /usr/local/bin/my-server
  ##   subrun --cwd /project/dir -- .venv/bin/python -m mcp_server

  # Crash-loud startup (E1): everything validates before anything spawns.
  if command.len == 0:
    stderr.writeLine("subrun: no command specified. Use -- before arguments.")
    return 2

  var envOverrides: seq[(string, string)]
  for e in env:
    try:
      envOverrides.add(parseEnv(e))
    except CatchableError as ex:
      stderr.writeLine("subrun: " & ex.msg)
      return 2

  let binaryPath = findExe(command[0])
  if binaryPath.len == 0:
    error "Binary not found", binary = command[0]
    return 126

  var cfg = Config(
    binary: expandFilename(binaryPath),
    args: command[1 .. ^1],
    cwd: resolveCwd(cwd),
    logDir: resolveLogDir(logDir),
    graceTimeout: graceTimeout,
    hardTimeout: hardTimeout,
    env: envOverrides,
    verbose: verbose,
    debugMode: detectDebugMode(),
  )
  if not dirExists(cfg.cwd):
    error "CWD does not exist", cwd = cfg.cwd
    return 1

  setProcessTitle(extractFilename(paramStr(0)) & "[" & extractFilename(cfg.binary) & "]")

  info "Wrapper starting", pid = getCurrentProcessId(), hostPid = getppid()
  if cfg.debugMode:
    info "Debug mode enabled", invokedAs = extractFilename(paramStr(0))
  if cfg.verbose:
    # Interim --verbose semantics (stage 10.3): info-level startup dump.
    # Env values are never logged (S4.3).
    info "Config", binary = cfg.binary, args = cfg.args, cwd = cfg.cwd,
         logDir = cfg.logDir, debugMode = cfg.debugMode,
         graceTimeout = cfg.graceTimeout, hardTimeout = cfg.hardTimeout

  saveFdFlags()
  for fd in 0..2:
    setNonBlocking(cint(fd))

  initHandledSignals()   # data only — before fork so the guest's reset loop sees it

  var pipes: PipeSet
  try:
    setupPipes(pipes)
  except CatchableError as ex:
    error "Pipe setup failed", error = ex.msg
    restoreFdFlags()
    return 126

  # Handlers are installed AFTER spawn (stage 19.2): the guest then inherits
  # default dispositions at fork, so a deadly signal kills it even in the
  # pre-exec window.  A host signal landing in this microsecond window kills
  # us by default disposition — the guest is still covered (pdeathsig/EOF).
  var r = Runner(cfg: cfg, hostPid: getppid())
  try:
    r.guestPid = spawnGuest(cfg, pipes)
  except CatchableError as ex:
    error "Failed to launch guest", error = ex.msg
    for kind in FdKind:
      closeFd(pipes[kind].r)
      closeFd(pipes[kind].w)
    restoreFdFlags()
    return 126

  setupSignalHandlers()

  info "Guest launched", pid = int(r.guestPid)
  let code = runLoop(r, pipes)
  restoreFdFlags()
  return code

const
  HelpTable = {
    "graceTimeout": "Timeout for graceful shutdown (SIGTERM) before SIGKILL escalation",
    "hardTimeout": "Timeout for bounded give-up, from shutdown start",
    "cwd": "Working directory (default: caller's current directory)",
    "logDir": "Directory for session/operational logs, resolved against the invocation cwd",
    "env": "Environment variable KEY=VALUE (repeatable, overrides inherited)",
    "verbose": "Log the startup config dump at info level (stderr)",
    "command": "Command and arguments to run (everything after the first non-option argument or --)",
  }.toTable
  ShortTable = {
    "graceTimeout": 'g',
    "hardTimeout": 't',
    "cwd": 'c',
    "verbose": 'v',
  }.toTable

# Everything after the first non-option argument (or an explicit --) is the
# guest command, including its flags — matches Python argparse.REMAINDER and
# the way MCP callers invoke subrun without a leading "--".
clCfg.argEndsOpts = true

dispatchGen(run, cmdName = "subrun", help = HelpTable, short = ShortTable,
            dispatchName = "dispatchRun")

when isMainModule:
  try:
    let exitCode = dispatchRun(commandLineParams())
    if exitCode >= -128 and exitCode <= 127:
      quit(exitCode)
    else:
      flushFile(stdout)
      flushFile(stderr)
      cexit(cint(exitCode))
  except HelpOnly, VersionOnly:
    quit(0)
  except ParseError:
    quit(2)
