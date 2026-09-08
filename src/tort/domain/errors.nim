## Tort error vocabulary — one exception class + reason enum (E3/E5).
## line/col are 1-based; (0, 0) means "position not applicable".

type
  TortErrorKind* = enum
    ekBacktrackUnderflow   ## K > scope stack depth (spec §3.1)
    ekBadEscape            ## unknown escape in context (spec §1.2)
    ekUnterminatedQuote    ## EOL/EOF inside QuotedString
    ekRowCountMismatch     ## fewer than N rows before block end (spec §4.2)
    ekWidthMismatch        ## cell count != header width (spec §4.3)
    ekDittoUnderflow       ## ditto cell in a table's first row (D22, v0.1.8)
    ekBadPath              ## [] in a TableKey / [] under scalar-object prefix (D23, v0.1.8)
    ekUnterminatedHeredoc  ## EOF before a heredoc's N content lines (D24, v0.1.8)
    ekDuplicateKey         ## duplicate FinalKey in strict mode (spec §3.2)
    ekBadLiteral           ## malformed header / malformed Integer in [N]
    ekBadJson              ## yyjson read error (adapter boundary)
    ekEncodeImpossible     ## shape not representable in Tort (e.g. root non-object)
    ekStreamResync         ## stream: document failed to parse (tolerant mode data)
    ekIo                   ## stdin/stdout read/write failure

  TortError* = object of CatchableError
    errKind*: TortErrorKind
    line*: int
    col*: int

proc raiseErr*(k: TortErrorKind; msg: string; line = 0; col = 0) {.noreturn.} =
  var e = newException(TortError, msg)
  e.errKind = k
  e.line = line
  e.col = col
  raise e
