# Error codes and source diagnostics

Public error codes consist of one uppercase phase prefix and four decimal digits.
`P` covers the parser frontend, including lexing and layout. `N` and `T` are
reserved for name resolution and type checking; their proposed registry is below.
Only the P registry is implemented today.
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

## Resolution and proposed elaboration diagnostics

Resolution N codes are implemented in `Ficus.Error.Resolve`; the future-feature
and T assignments remain an elaboration contract. Render mappings are explicit,
never derived from enum positions. Preserve existing P codes and parser fixture kinds. A source that fails
parsing stays a P error, even if another frontend could classify it semantically.

Use a shared diagnostic envelope with phase-tagged code, severity, primary span,
message, diagnostic ID, and related labeled spans. Adapt the existing parser
Diagnostic into that envelope without changing its code meaning. Error kind is
separate from display wording; maintain compatibility with existing authored
semantic fixture kinds when adding codes. For example UnknownPragma maps to
N0101, PreludeRequired to N0120, and InvalidImportSelection to N0205. An existing
InvalidPatternAnnotation due to a missing scoped type variable maps to N0007;
a well-scoped but incompatible annotation is a T error.

| Code | Proposed constructor / meaning | Primary location; related locations |
| --- | --- | --- |
| N0001 | UnresolvedName | Failing name occurrence, including a BUILTIN target |
| N0002 | AmbiguousName | Used occurrence; candidate declarations and every introducing import route |
| N0003 | WrongNamespace | Used occurrence; resolved entity declaration explaining its role |
| N0004 | DuplicateDeclaration | Later independent local declaration; earlier declaration (not competing imports) |
| N0005 | DuplicatePatternBinder | Repeated binder; first binder in the same pattern/parameter list |
| N0006 | ReservedName | Attempted binding; reserved entity identity, if source-defined |
| N0007 | InvalidTypeVariableScope | Unbound type-variable occurrence in an annotation; enclosing binder/signature context |
| N0010 | DuplicateSignature | Later signature target; first signature |
| N0011 | MissingSignatureTarget | Signature name without a defining clause or valid BUILTIN association |
| N0012 | ClauseArityMismatch | Later inconsistent clause head (name and written parameters); first clause head establishing the expected written value arity |
| N0099 | InvalidAbstractTree | Invalid node's origin; internal boundary error, not a substitute for a source diagnostic |
| N0101 | UnknownPragma | Directive name |
| N0102 | UnsupportedFeature | Directive/construct unavailable in selected language version |
| N0103 | InvalidPragmaArguments | Bad argument, or directive name for missing arguments; accepted argument contract |
| N0104 | InvalidPragmaPlacement | Misplaced directive; applicable declaration/header |
| N0105 | InvalidPragmaTarget | Target occurrence; target declaration |
| N0111 | UnknownBuiltin | BUILTIN key, not the target name |
| N0112 | ConflictingBuiltinAssociation | Later association; earlier association and target declarations |
| N0120 | PreludeRequired | do keyword or interpolated literal; disabling pragma |
| N0121 | MissingSugarBinding | Sugar origin; missing/inconsistent compiler-library registry entry (including Prelude.stringAppend) |
| N0201 | ModuleNotFound | Explicit module path or implicit Prelude header anchor; provider search summary |
| N0202 | InvalidModuleIdentity | File/module anchor; configured source root and offending path component |
| N0203 | ImportCycle | Closing import edge; ordered cycle-edge spans |
| N0204 | MissingExport | Selected member or qualified terminal; supplying import/export module |
| N0205 | InvalidImportSelection | Invalid constructor/record member selection; owning type declaration |
| N0206 | AmbiguousReexport | Conflicting later pub token; earlier public declaration/re-export and candidate identities |
| N0207 | ModuleNotImportable | Import edge to a future STANDALONE module; its header pragma |
| T0001 | TypeMismatch | Incompatible use/initializer; expected signature or originating constraint |
| T0002 | InfiniteType | Occurs-check origin; binding/use that introduced the cyclic equation |
| T0003 | KindMismatch | Supplied type or kind annotation; expected-kind origin |
| T0004 | InvalidAnnotation | Well-scoped invalid type/signature annotation; its constrained pattern/expression |
| T0005 | ExcessTypeArguments | First excess @ argument; explicit quantifier declaration |
| T0006 | TypeBinderMismatch | Definition/lambda binder; corresponding signature binder list |
| T0099 | InvalidCoreTree | Invalid generated/source origin; internal boundary failure |
| T0101 | ExpressionHole | Hole occurrence, with inferred zonked type |
| T0102 | UnresolvedWeakType | Binding/receiver origin; uses keeping it unresolved |
| T0103 | InvalidTypeHole | Hole in a prohibited type-only location |
| T0201 | ExpansiveInitializer | Complete immediate initializer; relevant top-level/member declaration |
| T0202 | UnsafeRecursiveInitialization | Unprotected recursive reference; source-ordered SCC members |
| T0203 | RefutablePattern | Entire do-bind pattern; bound result type and a useful uncovered case |
| T0301 | NonRecordReceiver | Update/projection receiver; inferred type origin |
| T0302 | UnknownField | Field label; inferred nominal record declaration |
| T0303 | DuplicateField | Repeated field label; first occurrence |
| T0304 | MissingField | Constructor occurrence; missing nominal field declarations |
| T0401 | UnsatisfiedConstraint | Constrained use; trait/context declaration |
| T0402 | AmbiguousConstraint | Binding/signature; unresolved predicates and variable origins |
| T0403 | InvalidImplementation | Impl header or offending member; ownership/overlap/missing-member evidence (split into dedicated codes when implementing M5) |
| T0501 | BuiltinContractMismatch | Declared signature/kind; BUILTIN key contract and association |
| T0502 | MissingBuiltinSignature | BUILTIN target; absent/incomplete ordinary signature |
| T0503 | UnexpectedBuiltinDefinition | Extra source body; signature-backed builtin association |
| N0902 | RepeatedModuleQualifier (warning) | Repeated qualifier import; earlier bindings; distinct modules are checked at use sites |
| N0901 | Shadowing (warning) | New sequential binder; hidden binder |
| T0901 | NonExhaustiveMatch (warning) | Match/function origin; uncovered case |
| T0902 | RedundantClause (warning) | Redundant clause; covering earlier clauses |
| T0903 | KindDefaulting (warning) | Parameter/kind-hole origin; selected default |

N0002 is emitted only when a candidate set is demanded by an occurrence;
N0206 checks publication even if no expression refers to the name. Deduplicate
candidates by canonical defining identity, never by import path or display text.
Do not emit N0004 for an unused opened-import conflict. Repeated module qualifiers warn with N0902; qualified uses select by exported
terminal name and namespace and report N0002 only for distinct surviving identities.

For generated nodes, primary spans point to the actual originating construct:
implicit Prelude uses a zero-width module-start/header anchor, do-generated
coverage failures use the original pattern, and interpolation-generated calls
use the source segment/literal. Related spans explain the dependency without
borrowing a neighboring source node as primary. Later-stage source maps must
retain these origins after names and types are erased.

Recover locally using diagnostic-linked poison nodes only in a recovery tree.
Suppress duplicate cascades from that poison, not independent errors. Successful
Abstract/Core boundary validators reject poison and unresolved lexical references.
Code, severity, and primary span are fixture assertions; full message prose is not.
Type/coverage failures must never be reclassified as parse failures solely because
a syntactic pattern looks refutable.

CLI diagnostics use `prettyDiagnosticRelativeTo` to display source-location
filenames relative to the working directory, including related-span notes.
Source files outside that directory use parent components. Relative filenames
and virtual names such as `<stdin>` are preserved. Only displayed location
filenames change: diagnostic messages, including absolute module search paths,
and internal spans/source-cache keys remain unchanged. The existing pure
`prettyDiagnostic` API continues to display filenames as supplied.
