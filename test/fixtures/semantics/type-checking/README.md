# Type-checking conformance fixtures

These are independent library modules, not selected executable entries. Load each
with the shared `../../support/Prelude.ficus`; no `main` is required. SPEC is the
source of truth. `Ficus.Infer.CorpusSpec` infers these modules, compares the
authored positive schemes modulo variable renaming, checks negative diagnostic
kinds and primary spans, and independently validates elaborated positive Core.

The parser suite automatically discovers both positive and negative `.ficus`
files. The typechecking runner validates Abstract before inference. The existing
`NamedPatternAnnotation` fixture is rejected by the resolver for an out-of-scope
type variable and remains covered there. Other negatives must reach their
intended typechecking phase; rejecting syntax or names does not satisfy them.

## Authored expectations

`positive-expectations.json` specifies schemes for selected exported bindings in
the 19 new positive cases. Type variables are schematic and compared modulo
renaming; `{a}` prefixes retain explicit binder order. Unprefixed variables are
implicitly quantified. These expected types follow SPEC, with comparable
translations checked against GHC/OCaml. The existing `MiniPrelude` and
`IrrefutableConstructors` cases remain additional positive inputs.

`expectations.json` keeps all earlier entries unchanged and adds 31 negative
cases with kind, T code, inclusive primary span, selected source text, and spec
rule. These are authored Ficus contracts, not GHC locations or diagnostic wording.
`additionalDiagnostics` lists further required errors in the same module. For
hole cases, `goalType` and `context` require the completed goal type and relevant
local binding types. Extra independent diagnostics are permitted; cascades from
the same missing expression must not hide another hole or unrelated error.

`reference/expectations.json` maps every new Ficus case to checked compiler
translations or an explicit Ficus-only rule. Haskell and OCaml files use `.hs.txt`
and `.ml.txt` extensions so Stack does not discover them as project modules.
They are copied to isolated temporary directories for compilation, not executed.
This matters for deliberately nonterminating recursive definitions: their types
are being checked, not their termination or runtime behavior.

## Coverage

| Area | Positive cases | Negative cases |
| --- | --- | --- |
| HM and environment | IdentityUses, LocalLetPolymorphism, SignatureSpecialization | ApplicationMismatch, InfiniteType, LambdaParameterMonomorphic, EnvironmentNotGeneralized, SignatureTooGeneral |
| Branches, patterns, aggregates | ConstructorValuePolymorphism, RecordConstructionUpdate; existing IrrefutableConstructors | AnnotationMismatch, IfConditionNotBool, IfBranchesMismatch, MatchBranchesMismatch, GuardNotBool, ConstructorArgumentMismatch, ListElementMismatch; existing record/do cases |
| Scoped types and kinds | ScopedPatternAnnotation, ExplicitBinderOrder, TypeApplicationHole, CompletedSignatureHole, HigherKindedContainer | TypeArgumentKindMismatch, ExcessTypeArguments |
| Recursion and initialization | SafeMutualRecursion, SignedPolymorphicRecursion | UnsignedPolymorphicRecursion, UnprotectedRecursion, ExpansiveTopLevel, ImmediateWhereExpansive |
| Value restriction and weakness | LocalExpansiveSolved, WeakAliasSolved | LocalExpansivePolymorphism, SignedExpansiveLocal, WeakAliasPolymorphism, UnresolvedWeakLocal, CovariantExpansivePolymorphism |
| Qualified types and evidence | SignedConstrainedAlias, ConstrainedFunction, MonomorphicConstraintSolved, SuperclassEvidence, MethodLevelConstraint | UnsignedConstrainedPolymorphism, UnresolvedMonomorphicConstraint, UnsatisfiedTrait, AmbiguousQualifiedSignature |
| Goals and deferred constraints | CompletedSignatureHole | TypedExpressionHole, MultipleExpressionHoles, HoleAndIndependentError, DeferredProjectionUnresolved |

The hole cases require continued elaboration: one fully typed goal, two separately
reported goals with different result types, and a goal alongside an independent
type mismatch. Runtime-lowering rejection of Core holes requires future Core unit
fixtures; source/parser acceptance cannot demonstrate that invariant.

## Reproducing the reference checks

From the repository root, with `ocamlc` on PATH:

```sh
stack exec python3 -- test/fixtures/semantics/type-checking/verify-references.py
stack exec python3 -- test/fixtures/semantics/type-checking/verify-references.py --compiler ghc
stack exec python3 -- test/fixtures/semantics/type-checking/verify-references.py --compiler ocaml
stack exec python3 -- test/fixtures/semantics/type-checking/verify-references.py --report /tmp/ficus-type-reference-report.json
```

The script checks inventory and span/source consistency, then compiles 57
translations: 46 with GHC and 11 with OCaml. It never silently skips an unavailable
compiler. GHC uses monomorphism restriction explicitly, disables deferred errors
and holes, and checks diagnostic codes/counts for negative translations. In
particular, the multiple-hole and hole-plus-error references must emit every
expected diagnostic. No full diagnostic wording is asserted. GHC inferred type
dumps and compiler diagnostics are available in the optional report for review.
Observed baseline: GHC 9.10.3 and OCaml 5.4.1. Review each affected case if compiler
versions change diagnostics; do not bulk-accept failures.

## Limits of the references

Haskell translations pin integer expressions to `Int`; Ficus literals are not
overloaded. Haskell `String` is only a typing analogue of Ficus's primitive String.
Haskell type applications address explicit `forall` binders; Ficus's ordered
`{a}` binders are translated accordingly. Haskell kind annotations use `Data.Kind.Type`.
Record syntax is translated only to test construction/update type preservation,
not field evaluation order or Ficus's deferred nominal selection algorithm.

OCaml is useful for application-result weakness and aliases sharing a monotype.
Its relaxed value restriction also generalizes covariant variables, unlike Ficus's
syntactic rule. See the official [OCaml manual, value restriction and relaxed value restriction](https://ocaml.org/manual/5.3/polymorphism.html#ss:valuerestriction).
The paired cases deliberately establish these boundaries:

| Case | GHC | OCaml | Ficus contract and reason |
| --- | --- | --- | --- |
| LocalExpansivePolymorphism | Accept | Reject | Reject: an expansive local function result stays monomorphic |
| SignedExpansiveLocal | Accept | Reject | Reject: a signature cannot override value restriction |
| CovariantExpansivePolymorphism | Accept | Accept | Reject: Ficus has no relaxed/covariant generalization |
| UnresolvedWeakLocal | Not used | Accept | Reject: Ficus checks all unresolved weak variables at module completion, including unused locals |
| ExpansiveTopLevel | Accept | Accept | Reject: v0 top-level initializers must be non-expansive even at concrete types |
| ImmediateWhereExpansive | Accept | Accept | Reject: a zero-written-parameter where group initializes before the RHS lambda |
| UnprotectedRecursion | Accept | Reject | Reject: recursive reads must be beneath value lambdas |

`ImmediateWhereExpansive` fixes the returned function's argument to Int so the
OCaml counterpart tests initializer policy rather than unrelated weak export
rejection. `UnresolvedWeakLocal` specifically tests an unused *local* variable;
OCaml rejects some escaping weak variables but accepts this one. Ficus references
are v0 only: no mutable Ref API, ETA exception, STANDALONE module, existential, or
higher-rank source type is assumed.

DeferredProjectionUnresolved is SPEC-only: neither Haskell's named selector nor
OCaml's record-label disambiguation models Ficus's requirement that ordinary
inference determine the nominal receiver. The absence of a comparable external
reference is explicit rather than treating another language's behavior as evidence.
