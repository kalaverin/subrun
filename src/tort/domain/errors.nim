## TT error vocabulary — one exception class + reason enum (E3/E5).
## line/col are 1-based; (0, 0) means "position not applicable".

type
  TtErrKind* = enum
    ekBacktrackUnderflow   ## K > scope stack depth (spec §3.1)
    ekBadEscape            ## unknown escape in context (spec §1.2)
    ekUnterminatedQuote    ## EOL/EOF inside QuotedString
    ekRowCountMismatch     ## fewer than N rows before block end (spec §4.2)
    ekWidthMismatch        ## cell count != header width (spec §4.3)
    ekDuplicateKey         ## duplicate FinalKey in strict mode (spec §3.2)
    ekBadLiteral           ## malformed header / malformed Integer in [N]
    ekBadJson              ## yyjson read error (adapter boundary)
    ekEncodeImpossible     ## shape not representable in TT (e.g. root non-object)
    ekStreamResync         ## stream: document failed to parse (tolerant mode data)
    ekIo                   ## stdin/stdout read/write failure

  TtError* = object of CatchableError
    errKind*: TtErrKind
    line*: int
    col*: int

proc raiseErr*(k: TtErrKind; msg: string; line = 0; col = 0) {.noreturn.} =
  var e = newException(TtError, msg)
  e.errKind = k
  e.line = line
  e.col = col
  raise e
