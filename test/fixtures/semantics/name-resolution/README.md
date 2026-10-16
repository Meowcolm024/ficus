# Name resolution fixtures and proposed M2 runner

The current parser runner checks negative semantic sources for parser acceptance;
it does not yet execute resolution or validate N codes. Keep that separation.
Existing expectations retain their original kinds/spans. New entries additionally
record draft codes and source roots; unknown JSON fields are harmless to the
current parser-acceptance check. These authored manifests are not AST goldens.

Use an injected module provider rooted at the case's positive/negative directory
and local support/, plus ../../support for the single shared mini Prelude.
Module filenames remain uppercase. See ../../support/README.md for the library
and injected builtin/sugar contracts. Local support modules opt out explicitly
to avoid hidden import cycles. Graph projects override these default roots.

| Positive case | Required resolver assertion |
| --- | --- |
| UnusedImportConflict | Two distinct imported x candidates are legal without an occurrence |
| SameEntityViaReexport | Both routes to x select canonical Resolve.Left.x; no ambiguity |
| CanonicalAlias | L.x resolves to Resolve.Left.x, never a new L-owned declaration |
| CanonicalReexport | B.x resolves to Resolve.Left.x, retaining Bridge as an import route |
| LocalBinderHidesImports | Body x denotes the fresh parameter ID, not either imported x |
| UnusedPreludeConflict | Implicit Prelude.not and explicit Left.not coexist unused |
| SameEntityReexport | Public x has one identity, Resolve.Left.x, with two routes |

Negative cases use expectations.json. N0002 points at the used x (or not in AmbiguousPrelude) and reports both
canonical candidates/import spans. AmbiguousReexport fails at the second pub,
without any body occurrence; MissingUnusedExport and ModuleMissing fail even
though the names are unused. Existing NoPreludeDo/Interpolation remain semantic
errors despite explicit imports of library methods. Existing BUILTIN cases keep
key/target/pragma argument spans distinct.

When implementing M2, add code and related-span assertions without changing
existing primary spans by bulk acceptance. The isolated provider/graph cases in `graphs/` now cover explicit, aliased,
selected, re-export and implicit-Prelude cycles, missing modules, an acyclic
Prelude bootstrap, a diamond, and local value recursion. Add signature and
clause grouping, sequential shadowing/initializer visibility, duplicate binders,
@ type scopes, alias/module/type separation, qualified constructors, and deferred
record fields. Generated-origin assertions cover do, interpolation, and clause
lowering; identity assertions compare relations, not allocator-specific integers.
Keep duplicate local module-alias tests pending A19 instead of choosing a default.
No resolver/AST fixture execution is claimed by this inventory.

## Written clause arity

ClauseArityMismatch, ClauseArityMismatchWhere, and ClauseArityMismatchTypeBinder
parse normally and fail grouping/desugaring with N0012 before inference.
ClauseArityMismatchImpl covers an implementation member; ClauseArityMismatchSigned
shows that a two-arrow signature does not repair a shorter written clause. Count
written value patterns, not signature arrows or a returned lambda, and exclude
static @ binders. The later head is primary; the first head is related. Arity is
checked per binding, not per spelling across scopes or sequential declarations.
EqualClauseArity, EqualClauseArityTypeBinders, ClauseArityPatternSlots,
ClauseArityDifferentScopes, and SequentialDifferentArities cover matching arity,
alpha-renamed type binders, products as one slot, independent scopes, and legal
sequential shadowing. The last two must not be merged into one case group.
Repeated zero-argument definitions remain duplicate-declaration cases.
