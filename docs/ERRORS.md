# Error codes and source diagnostics

Public error codes consist of one uppercase phase prefix and four decimal digits.
`P` covers the parser frontend, including lexing and layout. `N` and `T` are
reserved for name resolution and type checking when those stages are implemented.
Once published, a code must not be reassigned to a different error. Messages may
change independently of codes.

`Ficus.Error.Parser` owns parser diagnostics and the explicit code registry.
`diagnosticKind` derives the existing lexical/layout/syntax category from the
code. Primary spans remain one-based and inclusive; EOF spans are zero-width.

| Code | Meaning |
| --- | --- |
| P0001 | Unexpected token or end of input |
| P0002 | Invalid syntax |
| P0003 | Invalid declaration head |
| P0004 | Mixed operator associativity |
| P0005 | Empty block where a nonempty block is required |
| P0006 | Missing block or block delimiter |
| P0007 | Invalid syntactic pragma arguments |
| P0008 | Invalid import syntax |
| P0009 | Mixed constructor and record-field type body |
| P0010 | Expression block lacks a final expression |
| P0011 | Invalid module-path component |
| P0012 | Missing lambda binder |
| P0099 | Concrete syntax boundary validation failed |
| P0101 | Insufficient indentation |
| P0102 | Invalid continuation across a layout boundary |
| P0201 | Invalid source character |
| P0202 | Invalid pragma name |
| P0203 | Unterminated pragma |
| P0204 | Unterminated block comment |
| P0205 | Unterminated string or character literal |
| P0206 | Invalid escape sequence |
| P0207 | Invalid character literal length |
| P0208 | Invalid interpolation contents |
| P0209 | Unmatched interpolation brace |

`Ficus.Util.Source` owns source positions, spans, provenance, comments, and the
shared four-column tab-stop setting. Language-specific token types live in
`Ficus.Syntax.Token`.

`Ficus.Error.Pretty.prettyDiagnostic source diagnostic` uses the supplied source
text rather than reading the file named in the span. The CLI therefore shows
excerpts for stdin as well as files. Tabs are expanded using the same setting as
Megaparsec; source columns count Unicode characters. Inclusive spans are
underlined, EOF gets a visible caret, and long multiline spans elide middle lines.
If the referenced line is unavailable, the header still includes the filename,
position, code, and message.
