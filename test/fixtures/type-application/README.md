# Explicit type binders and application (v0)

Source inventory for SPEC §7.3; not wired into the scaffold runner and not executed.
Rank1.ficus covers explicit signature, definition and lambda binders and scoped
annotations. Parsing.ficus is parser-only coverage for kind annotations, compound
and qualified type atoms, holes, prefix-with boundaries, and longer @ operators.

PrefixBoundaries.ficus covers complete named definition heads, leading type-binder
lambdas, ordinary lambdas, applications, if conditions, match guards, and nested
type/kind arrows. LambdaTypeBinderAfterValue.ficus must not be accepted by scanning
for a later arrow after an invalid lambda parameter prefix.

Negative designated primary spans (one-based, inclusive):

| File | Proposed category | Primary span |
| --- | --- | --- |
| LambdaTypeBinderAfterValue.ficus | UnexpectedToken | 1:17–18 (->) |
| HigherRank.ficus | InvalidTypeSyntax | 1:8–8 (nested opening brace) |
| ConcreteBinder.ficus | InvalidTypeBinder | 1:5–7 (Int) |
| InterleavedArgument.ficus | InvalidTypeArgumentPlacement | 1:15–15 (@) |
| ExcessArgument.ficus | ExcessTypeArguments | 3:17–23 (@String) |
| TypeOnlyExpansive.ficus | ExpansiveTopLevelInitializer | 2:12–25 (makePrinter ()) |

Nested quantifiers have no v0 grammar production. A later shared parser admitting
higher-rank syntax must still reject this fixture semantically in v0; align the
category with that implementation. Assert kind and primary span, not wording.

Additional checks must cover binder/signature positional alignment, inferred
schemes retaining written binder order, unknown annotation variables, kind errors,
hole inference, implicit quantifiers not accepting explicit arguments, duplicate
binders, and the prohibition on type binders after value parameters. Explicit
polymorphic lambdas cannot be used as higher-rank arguments in v0. Type erasure
must preserve effect order, value restriction, recursive initialization safety,
source-based monomorphism, and where timing based only on value parameters.
