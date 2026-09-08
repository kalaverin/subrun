## Grammar constants for Tort v0.1.2 — every magic token of the format lives here.
## Spec: .serena/memories/solutions/subrun/tt_proto/tort-spec-v0.1.2.md

const
  NullToken* = "~"            ## null literal
  TrueToken* = "+"            ## boolean true literal
  FalseToken* = "-"           ## boolean false literal
  EmptyObjToken* = "{}"       ## empty-object literal (KV-value position only)
  EmptyArrToken* = "[]"       ## empty-array literal (KV-value position only)
  QuoteChar* = '"'            ## quoted-string delimiter
  EscapeChar* = '\\'          ## escape introducer, all contexts
  CommentChar* = '#'          ## comment introducer (line level)
  PipeChar* = '|'             ## cell/header separator
  CommaChar* = ','            ## inline-list separator
  ColonChar* = ':'            ## key/value separator
  DotChar* = '.'              ## path separator / relative-dot

  NoExpLow* = 1e-6            ## floats >= this use plain notation (D2)
  NoExpHigh* = 1e21           ## floats < this use plain notation (D2)

  RawFence* = "\"\"\""       ## RawString delimiter: verbatim, no escapes (v0.1.4)
  EscFences* = ["'''", "```"]  ## EscapedFence delimiters: D3 hatches, '"' free (D20, v0.1.7)
  DocSepToken* = "---"       ## section separator line (v0.1.3); stream doc boundary (D13)
  RawMinEscapes* = 3          ## raw form needs at least this many escapable chars
  RawDensityDiv* = 20         ##   and at least len/div of them (5%)
  MaxNewlineRun* = 3          ## squash: cap consecutive '\n' at this (D18, lossy)

  BareIdentChars* = {
    'a'..'z', 'A'..'Z', '0'..'9', '_', '-'
  }                           ## unescaped BareIdent character set
