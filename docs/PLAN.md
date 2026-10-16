# Ficus implementation plan

This document is non-normative. [SPEC.md](SPEC.md) defines language behavior and versioned feature designs; [IMPL.md](IMPL.md) records compiler architecture and engineering choices. This plan tracks implementation order, conformance checks, and unresolved decisions. Milestones are planned work, not claims of completed implementation.

## 1. Approach

- Build a small end-to-end slice before completing kinds and traits: Concrete → Abstract → Core → Runtime → compiled evaluator.
- Introduce each boundary validator with its AST, source spans, provenance, and fixtures. Later stages must not depend on earlier-stage types.
- Map every normative spec rule to a fixture. Negative fixtures assert diagnostic kind and primary span, not complete wording. Bug fixes begin with failing fixtures; review each generated golden diff.
- Check parse/pretty-print round trips, formatter idempotence, and compiled evaluator equivalence to the direct interpreter, including errors and effect order.
- Track open decisions by ID, owner document, and deadline. Recommendations below are proposals, not defaults. Settle language choices in SPEC.md before implementation; record engineering choices in IMPL.md. If code contradicts SPEC.md, stop and ask which is wrong.

## 2. v0 milestones

| ID | Milestone | Scope | Exit criteria |
| --- | --- | --- | --- |
| M0 | Foundations | Stack project and CI, spans/provenance, diagnostic renderer, fixture harness, conformance matrix | Labeled source diagnostics render in tests; fixture assertions identify kind and primary span |
| M1 | Syntax | Lexer, parser-driven layout, Megaparsec, Concrete AST, dynamic spelling-based operator grouping, concrete pretty-printer | v0 grammar and layout fixtures pass; round-trip and idempotence properties pass |
| M2 | Resolution and Abstract AST | Module graph/import cycles, imports/re-exports, namespaces, uncommitted dotted chains, declaration identity, clause grouping, `do`/interpolation, dependency analysis | Abstract validator passes; unresolved/duplicate member names, deferred import ambiguity/use-site errors, pub conflicts, and the separately selected module collision policy, unsafe recursive dependencies, and Prelude-disabled sugar are covered; sequential shadowing warns |
| M3 | End-to-end slice | HM without traits, value restriction, signed/unsigned recursion, first-order ADTs, products, lists, patterns, distinct `if`, strict blocks and `where`, typed Core, minimal Runtime and compiled evaluator, ordinary declarations with resolved `BUILTIN` metadata and primitives | A program with list functions and mutually recursive functions runs through all four stages; all boundary validators run in tests |
| M4 | Types complete | Kinds and defaulting, rank-1 explicit signature quantifiers, scoped @ binders/type applications, parenthesized pattern annotations with scoped type variables, kind-annotated alias parameters and regular recursive ADTs, built-in higher-kinded constructors, type/kind holes, expression-hole errors, record construction/update and deferred field constraints | Kind, alias, hole, annotated-pattern, and record fixtures pass; pending projection variables remain monomorphic; expression holes remain representable in diagnostic Core but fail elaboration; Runtime lowering independently rejects them |
| M5 | Traits | Haskell 98 heads, superclass cycles, visible implementation sets, orphan/overlap checks, method constraints, ambiguity and monomorphism restrictions, explicit dictionaries, default non-expansive top-level/member initializers | `Functor []`, `Bifunctor (*)`, marker `Monad`, thunked Seq, and short-circuiting Alternative Maybe work; signed/unsigned constrained bindings and constrained methods are covered; derived functions remain outside dictionaries |
| M6 | Runtime completeness | Safe arity raising, single-constructor/single-field wrapper erasure, lexical addresses and numeric IDs, dictionary erasure only when evidence is unused, Runtime validator, direct interpreter oracle, runtime provenance | Compiled and direct evaluators agree on values, errors, and effect order; partial/extra applications and intermediate `where` initialization are covered |
| M7 | Prelude and v0 conformance | Proposed v0 builtin/Class/System.IO/Data inventory (PRELUDE §1), explicit thunked sequencing/choice and derived seqLeft/seqRight, explicit stdlib bootstrap imports, reviewed implicit Prelude exports excluding Data.Map, explicit entry-module selection and required own `main` with either supported signature, exhaustiveness/redundancy warnings, end-to-end scripts | Every v0 spec rule has a fixture; sample scripts run; required decisions are reflected in their owner documents; Stack build/tests pass |

The initial CLI command surface belongs to v1+. An internal execution harness can exercise M3–M7 without promising a v0 public `run` command. Constant-stack tail calls are not a v0 guarantee; backend-specific optimization is optional.

### M2 breakdown: resolution and Abstract boundary

Implement the proposed design in [IMPL §§1.4–1.6](IMPL.md#14-resolution-passes-and-canonical-names-proposed-m2-design). M2 is not a single lookup pass. Use in-memory summaries first; v1+ artifact serialization is not a prerequisite. The current parser/Concrete validator remain the input boundary.

| Step | Deliverable | Dependencies / acceptance evidence |
| --- | --- | --- |
| M2a | Stage-neutral module/global/local/type-variable IDs, Abstract-owned Node wrapper, generated-origin metadata, diagnostic envelope and draft N-code registry | Inspect current Source/Parser/Pretty APIs; preserve P-code compatibility. Canonical globals retain original owner through aliases/re-exports; local shadowing produces different IDs. No Abstract imports of Concrete |
| M2b | Module provider, header pragma classification, reserved identities, implicit Prelude edges, graph/cache and cycle diagnostics | M2a. Missing explicit/implicit modules, NO_IMPLICIT_PRELUDE bootstrap, unknown/unsupported/misplaced directives, BUILTIN retaining Prelude, implicit cycles. Specify provider root/distribution B17 before actual filesystem discovery; use a deterministic injected provider in unit tests |
| M2c | Public export summaries, import selections, nominal record-member metadata, opened-name candidate sets, implementation visibility closure | M2b. Unused conflicts accepted; use-site ambiguity rejected, including implicit Prelude; canonical identity deduplication; invalid selections/missing exports checked immediately; conflicting pub exports rejected. Repeated qualifiers warn; use sites filter by exported name/namespace and canonical identity |
| M2d | Clause/signature grouping, declaration preallocation, mutually visible versus sequential scopes, pattern/type-variable binding, BUILTIN target association | M2c. Equal written value arity checked before clause merging (N0012), excluding @ binders/RHS lambdas; forward top-level/where refs, sequential initializer seeing the previous binding, duplicate local/pattern/signature diagnostics, signature-local versus @-scoped variables, method ownership and target order independence |
| M2e | Name/dotted-chain resolution, hygienic operator/do/interpolation and lambda-pattern lowering, record construction-versus-update classification | M2d. Canonical refs, no constructor-projection fallback, disabled sugar errors, registry-selected methods unaffected by local names, simple-binder lambdas with explicit matches, required do-coverage obligations, per-parameter match timing, ordered field RHSs and preserved where timing. Interpolation uses the separately configured Prelude.stringAppend contract |
| M2f | Abstract validator and inference-facing module package | M2e. Structural tests for every Abstract form, simple-binder lambda invariant, common clause arity, ID closure/dominance, exports and obligations; no Concrete nodes or raw sugar. Symbolic typed field obligations and expression holes are allowed; unresolved lexical references and poison are not |
| M2g | Resolver fixture runner, diagnostic rendering and M3 handoff | M2f. Multi-file positive/negative cases assert N-code/kind/primary/related spans, canonical targets and binder relations; parser still accepts semantic failures. Feed validated Abstract to a minimal HM checker, retaining clause/pattern and parameter metadata through Core elaboration |

At M3/M4, add T-code tests for field selection, @ binder alignment, holes,
coverage/refutability, generalization, and recursive initialization. M5 extends
those checks for traits, visible implementations and evidence. Module cycles are
an M2 error; unsafe value SCCs and dictionary initialization are typed checks.

Lambda-pattern normalization cases and expected Abstract invariants are in
`test/fixtures/desugaring/pattern-lambdas/`; M2e/M2f check hygiene, matching
before later argument effects, annotation preservation, do coverage, and where timing.

The shared mini library is `test/fixtures/support/Prelude.ficus`; semantic
fixtures use its source root and fixed fixture builtin/sugar contracts. It is
not the production stdlib distribution decision B17. Isolated graph projects
must keep their explicit source roots and no shared Prelude fallback.

Resolution fixture inventory: `test/fixtures/semantics/name-resolution/README.md`.
Isolated graph projects and code/span/edge expectations live in its `graphs/`
directory; M2g must discover every project source, not just top-level negatives.
Existing negative manifests retain their authored kind/span contract; add code
assertions when the resolver runner exists rather than bulk-renaming fixtures.
Name-conflict timing is settled in SPEC. Source lookup now requires an
unambiguous configured provider; duplicate matching files are configuration
errors. Observable ordering of implicit versus explicit import initialization
remains a follow-up. Concatenation uses Prelude.stringAppend; repeated module
qualifiers warn and resolve at use sites by canonical identity.

### M3–M5 breakdown: inference, elaboration, and typed Core

[TYPECHECKING.md](TYPECHECKING.md) refines M3–M5 into T0–T12, with dependencies,
acceptance evidence, module ownership, and a proposed typed Core calculus. T0–T6
provide the trait-free M3 execution slice; T7–T8 finish kinds, explicit type
operations, holes, and nominal fields for M4; T9–T12 add qualified inference,
evidence, dictionaries, and checked interfaces for M5. These are planned steps,
not completed work. Read the binding-boundary schedule before implementing
generalization: value restriction, monomorphism restriction, initialization
admissibility, and recursive protection are separate checks. Recheck initialization
after evidence insertion, before publishing validated Core.

### Required coverage

- **M1:** Layout boundaries for prefix `with` and postfix record construction/update, application precedence and left-associated suffix chains, nested `=`/`<-`, delimited `if` conditions, pragmas, qualified operators, mixed associativity, comments/dots/brace escapes, spaced qualification/projection, leading-dot continuations versus same-indent rejection, parenthesized dotted `with` scrutinees, projection-before-application precedence, and infix-pattern declaration rejection in every context. `::`, `Type`, `magic`, `True`, and `False` use ordinary parser productions. All pragmas share an ALL_CAPITAL name plus identifier/string arguments; names and argument meanings are validated later. Keys do not enter scope. `_` retains its ordinary identifier form until contextual interpretation.
- **M1/M4:** Cover `{a}` signature prefixes, @ definition/lambda binders, kind annotations, atomic/parenthesized type arguments, holes, prefix-with boundaries, shared definition/lambda/application prefixes and if/guard clause arrows, preserved longer @ operators, binder order and scope, erased argument timing, and v0 higher-rank rejection. Reject excess/interleaved type arguments and concrete type patterns.
- **M2:** Selective ADT constructor imports, whole-record imports, invalid record member selections, `pub`, primitive spellings as local module names/aliases, dotted qualification before projection, declaration identity through aliases/re-exports, and `NO_IMPLICIT_PRELUDE`. Resolve `BUILTIN` targets independently of adjacency, obtain types/kinds from ordinary declarations, and check duplicate/conflicting definitions, ordinary name scope, and retained Prelude. Keep sequential `do` `=` bindings distinct from immediately applied lambdas.
- **M3–M5:** Cover kind-annotated alias parameters, reject type-matching parameters, and enforce single-target signatures without parameter lists.
- **M3–M5:** Cover annotated patterns in function/lambda arguments, constructor arguments, nested patterns, matches, local declarations, and `do`; include negative unbound named-type-variable annotations, positive @-scoped variables, and inference holes. Preserve declaration-head restrictions; use type-directed coverage for refutability, with positive single-constructor and negative nested-refutable cases.
- **M3–M5:** Add positive top-level literals/aggregates/functions and negative acyclic calls, signed expansive definitions, reference allocation, and immediate expansive `where` groups. Cover selected entries with missing/invalid main, library modules without main, and unused main functions in other modules.
- **M3–M5:** Non-expansive top-level initialization (including immediate `where` work), lambda-protected recursive initialization, dependency/source order, written-parameter `where` timing, signed polymorphic recursion, value and monomorphism restrictions, weak variables, method-level predicates, visible implementation closure, and orphan checks after alias expansion.
- **M6:** Left-to-right arguments and fields, curried intermediate work, wrapper erasure without loss of nominal identity, partial application, and source locations for generated nodes and runtime errors.

Core remains unary and typed; Runtime raises arity only across intermediate application points without observable work. `if` stays distinct through Core. Runtime performs no string-based lookup. The implementation algorithms live in IMPL.md, not in the spec or this milestone table.

M6 work may use validated Core fixtures once M3 stabilizes its interfaces, while M4–M5 extend inference. The formatter can develop alongside parser hardening. The v0 parser suite in `test/Ficus/Parser/Spec.hs` executes `test/fixtures/parsing/`, including record-with cases, and checks semantic fixture sources for parser acceptance. Add semantic/evaluation assertions when those stages exist; canonical formatting remains future work. Highest risks are layout/ambiguity, dictionary elaboration with strict initialization, and kinds with holes.

## 3. v1+, v2+, and v3+ roadmap

These are dependency groups, not committed minor-version releases. [SPEC.md, Section 24](SPEC.md#24-planned-v1-language-features-and-libraries) groups the source-language plans; [IMPL.md, Sections 7–10](IMPL.md#7-entry-points-and-compiler-artifacts) describes their engineering work.

| Work group | Scope | Dependencies and acceptance |
| --- | --- | --- |
| V1-T | Artifacts and tooling | Design Lisp-like interface/object schemas and compatibility rules before artifact consumers. Initial objects contain textual Runtime AST; specify integration with v2+ JavaScript artifacts. Implement the settled `compile`, `run`, `repl [FILE]`, `format [-f FILE]`, and `lsp` command surface; resolve output paths, loading, and formatter I/O first. LSP initially provides semantic highlighting, definitions, and inferred types using retained metadata |
| V1-P | Types and patterns | Empty type bodies and empty `with`; no synthetic record constructor for `type T = {}`. Empty elimination accepts any result type and is exhaustive for uninhabited scrutinees. Add positive declaration/elimination fixtures and negative `Void with {}` coverage. Replace builtin-backed Prelude `Void`/`absurd`. Add explicit-brace record patterns with type-directed refutability and optional field omission in the specified positions, including both `do` binding forms; test nested refutable fields, upper-label type RHS arrows, and witness slots without @; reject recursive pattern bindings |
| V1-S | Evaluation and state | Implement the settled `Ref`, `newRef`, `readRef`, and `modifyRef` API under the existing v0 value restriction. Lazy arrows move to V2; retain explicit thunk APIs until then |
| V1-E | Exceptions | Preserve the proposed typed `throw`/`catch` interfaces while API questions remain open. Resolve nominal runtime identity before implementing exception operations, including polymorphic uses after wrapper erasure. Settle cleanup and effects; evaluate any existential-error revision explicitly |
| V1-G | Pragmas and deriving | `PRIVATE member` hides record constructors and fields while retaining the type. Add `DEPRECATED`, module-level `OPTIONS`, and `STANDALONE` (allow acyclic expansive top-level initialization; forbid imports of the module; preserve explicit entry selection), and argument-free `DERIVE` on an empty following `impl` for structural `Show`/`Eq` deriving; reject all handwritten members, including partial implementations. Settle targeting, warning policy, compiler-option interpretation/precedence, and derivation rules; preserve required metadata in interfaces. Admit definition pragmas in impl/where/local declaration contexts and definition-local ETA expansion before non-expansiveness checks; never inherit ETA into sibling or nested definitions; arbitrary expression pragmas and arbitrary trait derivation remain outside the initial scope |
| V1-L | Interpolation and libraries | Settle expression-interpolation delimiters/escapes before extending the scanner. Expand Prelude and define JSON/regex APIs, module organization, and re-exports, retaining the fine-grained control traits |
| Research | Existential type abstraction | Existential record members remain a v1+ proposal: implement named with-only explicit type-member supply/opening, uppercase labels selecting types without @, value-only positional slots and anonymous unpacking; review witness inference/non-escape and possible exception API changes. Higher-rank checking remains future work |
| V2 | Lazy evaluation, JavaScript, and packages | Lazy arrows, a simple JavaScript backend, tail-call optimization, a simple build system, libraries beyond Prelude, dependency resolution, and FFI. Preserve call-by-name evaluation without sharing, distinct non-subtyping arrow modes, and repeated effects; specify thunk representation, and tail-call coverage without assuming host TCO. Settle package/configuration formats, resolution, the proposed targeted `FOREIGN` annotations, accepted backends, conversions, and calling conventions; generated code must remain equivalent to the reference evaluator |
| V2-C | Concurrency primitives | Preserve the proposed `Fiber e a`/`join` and typed channel interfaces. Settle scheduler, buffering, cancellation, and reference interactions; retain nominal exception evidence and evaluate any existential-error revision explicitly |
| V3 | Native/WebAssembly backend | Choose WebAssembly GC or LLVM; specify closure/runtime representation, memory management, and integration. Validate equivalence against the reference evaluator |

References are not blocked on existential errors: their API is settled. V1 exceptions and V2 fibers retain their proposed status. LSP can use stage metadata independently of whether artifact serialization is finished; any cross-module artifact dependency must be specified when its interface is designed.

## 4. Decision register

### A. Open language and tooling decisions

Existing IDs are retained for traceability. “Before” is the last implementation point at which an unresolved choice can avoid blocking its dependent work.

| ID | Decision | Owner | Before / proposed next step |
| --- | --- | --- | --- |
| A1 | Entry-point arguments, error reporting, and exit status (module selection and required main settled) | SPEC §22; IMPL §7 | M7 invocation contract. Explicitly select the entry module and require its own main; cover missing/invalid main and unselected modules. Specify remaining conventions; no exit codes or argument defaults are selected here |
| A2 | Ordinary record updates settled; existential-record updates open | SPEC §7.2/27; IMPL §2 | M1/M4/M6 implement postfix updates with type preservation and receiver-once/source-order evaluation; defer existential updates |
| A3 | Record punning excluded | SPEC §7.2/24.1 | M1 and V1-P reject punned construction, update, and pattern fields; explicit field bindings required |
| A4 | Higher-rank checking | SPEC §7.3; IMPL §2 | Future work; v0 accepts only outermost quantification, with settled @ binders/applications |
| A5 | Uninhabited types inside other patterns and diagnostic policy | SPEC §24.1 | V1-P exhaustiveness extension; preserve the settled empty-type/empty-match case |
| A6 | Artifact schemas, extensions, versioning, compatibility, linking, paths | IMPL §7 | V1-T serialization and artifact consumers; document a concrete schema rather than assuming an ABI hash |
| A7 | REPL optional-file loading and formatter I/O | IMPL §8 | V1-T commands; `-f FILE` does not yet imply in-place editing |
| A8 | `DEPRECATED` targeting, placement, and warning policy | SPEC §24.4; IMPL §9 | V1-G metadata and diagnostics; preserve identifier targets and message |
| A9 | `OPTIONS` argument interpretation, accepted options, CLI precedence | SPEC §24.4; IMPL §9 | V1-G semantic option handling; use the uniform pragma parser and preserve source metadata from M1 |
| A10 | Private-pragma targeting details and inline pragmas | SPEC §24.4 | V1-G; retain the selected `PRIVATE`/`PRIVATE member` distinction, including hiding record constructors and fields, with v1+ definition-context pragmas admitted and per-directive targeting still open |
| A11 | Exception nominal identity and potential existential-error API | SPEC §24.3/24.6; IMPL §10.4/10.5 | V1-E exception implementation; select surviving evidence/type tokens before runtime matching |
| A12 | Reference atomicity, fiber scheduling, channel buffering/cancellation | SPEC §24.2/25.4; IMPL §10.2/10.4 | V2-C concurrency; ordinary V1-S references need not wait for a scheduler choice |
| A13 | Call-by-name thunk/Core representation | SPEC §25.1; IMPL §10.3 | V2 lazy-arrow implementation; no memoization or implicit strict/lazy coercion. Do not reserve `~>` in v0; type punctuation is introduced with the later feature |
| A14 | v0 library inventory and frozen Prelude exports; expanded JSON/regex APIs | SPEC §24.5; IMPL §9 | V1-L library interfaces; review v0 exports, Debug/Default and remaining instance contracts, Result/Either naming, numeric/Void scope, module availability, bootstrap dependencies, and trait/type ownership |
| A15 | Build configuration, packages, dependencies, and proposed `FOREIGN` annotations | SPEC §25; IMPL §6/9 | V2 design |
| A16 | Structural deriving rules | SPEC §24.4 | V1-G; preserve `{-# DERIVE #-}` attachment to the following empty `impl`, explicit contexts, rejection of nonempty bodies, and generic highlighting; initial scope is structural `Show`/`Eq` |
| A17 | Expression interpolation delimiters and escaping | SPEC §24.5 | V1-L scanner extension |
| A18 | Exception cleanup, nesting, effects, and standard instances | SPEC §24.3 | V1-E operational semantics; runtime identity alone does not settle these |
| A19 | Settled: shared module qualifiers | SPEC §2/6; IMPL §1 | Repeated qualifiers warn; requested exports filter candidates and canonical identities deduplicate at use sites |

### B. v0 conformance work and remaining gaps

Settled entries require implementation and fixtures, not new language decisions.

| ID | Status | Work / remaining question | Before |
| --- | --- | --- | --- |
| B1 | Settled | Parser-driven layout; test scrutinee boundaries and nested delimiter lookahead per IMPL §1.3 | M1 |
| B2 | Settled in v0 | Scan bare/module-qualified interpolation names; expression interpolation is A17 | M1 |
| B3 | Open lexical details | Specify identifier Unicode classes, remaining operator characters, numeric literal forms, tabs, BOM handling, and Unicode escapes; keep settled comment/dot/brace rules | M1 affected lexer paths |
| B4 | Settled rule; invocation setup open | Every module path component is uppercase. Do not exempt an entry file or silently rename it `Main`; choose source-root/entry discovery compatible with the rule, or propose a SPEC change | M2 module loading; A1/A7 invocation |
| B5 | Namespaces and deferred import ambiguity settled | Shared type/trait namespace, separate module/constructor namespaces, primitive spellings allowed as module bindings, use-site import ambiguity, identity deduplication, pub export conflict checks, specified import/member selections; module qualifiers follow the same deferred-use principle with warnings | M2 fixture coverage |
| B6 | Concatenation identity settled | Prelude.stringAppend has STRING_APPEND and String -> String -> String; sugar registries are injected separately from resolver configuration | M2 sugar integration |
| B7 | Settled | `Show String` is identity for interpolation | M7 |
| B8 | Settled | `<-` requires total coverage of the inferred bound type, checked semantically; no parser whitelist, including for single-constructor/infix patterns | M3/M4 |
| B9 | Representations settled; numeric edges open | Signed 64-bit wrapping `Int`, binary64 `Float`; specify literal ranges, division including zero, conversions, and float display | M3 affected primitives/literals; M7 display |
| B10 | Settled guarantee | No v0 constant-stack tail-call promise; v2+ JavaScript TCO coverage remains to be specified | M6 |
| B11 | Settled | Value restriction at every binding boundary; signatures cannot override it | M3 generalization |
| B12 | Settled | Monomorphism restriction for unsigned constrained bindings without parameters/outer lambda; complete signatures may override only this restriction | M5 |
| B13 | Settled | Signed polymorphic recursive uses, unsigned monotypes, non-expansive and lambda-protected cyclic initialization | M3; enforce non-expansiveness for acyclic top-level definitions too, including immediate `where` work; extend for dictionaries in M5 |
| B14 | Settled | Pending projection variables remain weak through nested groups; resolve receivers by module end | M4 |
| B15 | Settled | Kind defaulting with warnings, fully applied acyclic aliases, regular recursive ADTs; literals excluded from type/kind expressions | M4 |
| B16 | Settled | Method-level constraints and trait parameter occurrence in each method value type | M5 |
| B17 | Engineering choice open | Select stdlib source-root/distribution strategy. Bootstrap compiler primitives and sugar-free dependencies before implicit Prelude; builtin declarations do not disable Prelude, so bootstrap modules explicitly use `NO_IMPLICIT_PRELUDE` where needed to avoid cycles | M2 loading; M7 library integration |
| B18 | Settled warning expectation | Detect non-exhaustive/redundant matches without making them static errors; choose warning algorithm in IMPL | M7; V1-P extension |
| B19 | Library contract open | Define minimal impure IO primitives, ordinary declaration signatures, and builtin-key contracts; no IO type is introduced by the plan | M3 primitive slice; M7 Prelude |

## 5. Critical path and validation

1. **M0–M1:** Introduce diagnostics and Concrete validation; settle affected B3 lexical gaps. B1/B2 are fixture work. A9/A13 do not authorize future syntax in v0.
2. **M2:** Complete imports, namespaces, identity, and safe dependency analysis. Use B6's stringAppend contract and explicit configurable providers for B17; follow uppercase module naming from B4.
3. **M3:** Implement B11/B13 and strict evaluation through every stage. Settle only the numeric and primitive contracts needed by the slice (B9/B19), then complete them before release.
4. **M4–M5:** Implement B14/B15 kind/field/alias rules before dependent trait checks. Cover B12/B16, dictionaries, visibility, and initialization.
5. **M6–M7:** Verify arity raising and erasure against the oracle; finish Prelude, warnings, entry-point conventions (A1), and the conformance matrix. Run `stack build` and `stack test`, plus existing formatter/linter checks where applicable; do not accept changed diagnostics or goldens solely to pass checks.
6. **Post-v0:** Resolve each A decision before its dependent work group. Keep draft syntax and proposed effect APIs out of the v0 grammar and runtime. Record decisions in SPEC.md or IMPL.md, then update this plan and associated fixtures.

## Implemented resolution slice

The frontend now has independent provider, header/pragma, graph discovery,
interface/scope, and pure Concrete-to-Abstract translation APIs. The existing
name-resolution negative, positive, and isolated graph fixtures execute in the
resolver runner; successful outputs run the Abstract validator. Additional stage
contract tests cover recovery, canonical sugar, lexical IDs, parameter matching,
short module qualifiers, and source-ordered non-adjacent function clauses.
Typed coverage, initialization safety, signature/primitive contracts, and
inference-facing checked interfaces remain later milestones.
