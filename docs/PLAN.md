# Ficus implementation plan

## 1. Approach

- **Thin slice early.** A walking skeleton (monomorphic HM → Core → Runtime → evaluator) exercises every stage boundary before the hard parts (kinds, traits) are built.
- **Validators before features.** Each AST boundary gets its validator, fixtures and span/provenance plumbing when it is introduced.
- **A decision log.** Every open item below gets an ID, a status and a provisional default, so work proceeds on the default and a reversal has a known blast radius. Tests are tagged with decision IDs. "Settle by" means the last point at which the decision can stay open without blocking or forcing rework.
- **A spec conformance matrix.** Every normative sentence in `SPEC.md` maps to at least one positive or negative fixture.

## 2. v0 milestones

|#|Milestone|Scope|Exit criteria|Size|
|---|---|---|---|---|
|M0|Foundations|Haskell project, CI, source spans and provenance types, `rustc`-style diagnostic renderer, fixture harness (golden files, decision-ID tags)|A diagnostic with labeled multi-span excerpts renders in tests|S|
|M1|Syntax|Lexer, layout, Megaparsec parser, Concrete AST (explicit vs layout blocks, comments, pragmas, unresolved dotted chains, flat operator chains), naive formatter|All grammar productions parse. Positive and negative fixtures cover layout, pragma placement, import forms, the `with`/record fixture, and `x :: xs = v` in all four contexts. Round-trip and idempotence properties pass|L|
|M2|Resolution and desugar|Module graph and import cycles, `use` forms including `T(..)` and `pub`, namespaces, longest-prefix dotted resolution, dynamic operator grouping with the mixed-associativity error, clause grouping, `do` and interpolation sugar, Prelude-disabled errors, binding-group SCCs with the lambda-protection check|Abstract AST validator passes. Unresolved or ambiguous names, duplicates and unprotected recursion are all diagnosed|L|
|M3|Walking skeleton|Monomorphic-to-let-polymorphic HM without traits, first-order ADTs, products, lists, patterns, `if`, `where`, generalization, Core AST + validator, minimal Runtime AST, closure-compiled evaluator, minimal `MAGIC` registry (`addInt`, printing)|A non-trivial program (list functions, mutual recursion via `where`) runs end to end|L|
|M4|Types complete|Kind inference and kind annotations, aliases (expansion, kind signatures), type/kind holes, records, `Field` constraints, expression holes, ambiguity check, type-literal admission|Kind, hole, record and alias fixtures pass, including the `_ -> _ _ Int` example|M|
|M5|Traits|Trait/impl validation (Haskell 98 heads), superclass SCC check, coherence, orphan rule after alias expansion, entailment, dictionary elaboration, non-expansive `impl` check, proof-dictionary erasure, derived functions such as `(/=)`|`Functor []`, `Bifunctor (*)`, and `Monad` via marker traits all work. Overlap, orphan and cycle diagnostics work|L|
|M6|Runtime completeness|Arity raising, newtype erasure, lexical addressing, Runtime AST validator, a direct interpreter as test oracle, differential tests, tail calls, runtime error provenance|Compiled and oracle evaluators agree on values, errors and effect order across the fixture corpus|M|
|M7|Prelude and release|Prelude (built from `MAGIC` modules without sugar), entry-point validation for both `main` forms, minimal `run`, exhaustiveness/redundancy warnings, humorous diagnostics, conformance matrix complete|Conformance matrix green, sample scripts run, v0 tagged|L|

**Parallelism.** Freeze the Core AST grammar at the end of M3. M6 (runtime lowering and the oracle) can then proceed against hand-written Core while M4 and M5 are in progress. Pretty-printer and formatter work in M1 can run alongside lexer/layout hardening.

**Risk order.** Layout and parser ambiguity (M1) > trait elaboration and evaluation-order preservation (M5) > kind inference with holes (M4) > everything else.

## 3. Post-v0 roadmap

Ordering follows dependencies:

1. **V1.0 Tooling.** Interface and object artifacts (s-expression, textual Runtime AST), `compile`/`run`/`repl`/`format`. Design the artifact schema first, since LSP and incremental compilation depend on it.
2. **V1.1 Language additions.** Empty types and empty `with`, structural `Show`/`Eq` deriving, record patterns, private pragmas, `DEPRECATED`, `OPTIONS`.
3. **V1.2 Effects.** Value restriction plus `Ref`, then exceptions, then fibers and channels. Keep these marked experimental until the existential-error question is settled.
4. **V1.3 LSP.** Semantic highlighting, go-to-definition and types, built on the provenance retained since M0.
5. **V1.4 Libraries.** Larger Prelude, JSON, regex.
6. **Research track.** Explicit type application and existential record members, which need a parsing-ambiguity study before they touch the grammar.
7. **v2.** WebAssembly GC backend, build system, FFI.

## 4. Open decisions

### A. Declared open or deferred in the spec

| ID  | Decision                                                         | Recommendation                                                                                      | Settle by                                |
| --- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| A1  | Entry-point args, error reporting, exit status                   | Args exclude program name. `Err s` prints `error: s` to stderr and exits 1. A runtime error exits 2 | M7                                       |
| A2  | Record update syntax and receivers                               | Keep the postfix-`with` receiver restriction isolated in one parser rule                            | V1.1 grammar freeze (non-blocking)       |
| A3  | Record punning                                                   | Decide jointly with A4. Recommend no punning at first                                               | Start of V1.1 record patterns            |
| A4  | Explicit type-variable syntax `{a}`                              | Record patterns and blocks already use braces. Settle before the grammar freeze                     | Start of V1.1                            |
| A5  | Uninhabited-type exhaustiveness beyond an empty top-level match  | Ship only "empty match on an empty type is exhaustive"                                              | V1.1                                     |
| A6  | Artifact schema, versioning, linking                             | Start with a versioned s-expression format that includes an ABI hash                                | Start of V1.0                            |
| A7  | CLI output paths, REPL loading, formatter I/O                    | Formatter reads stdin and writes stdout by default. `-f` edits the file in place                    | V1.0                                     |
| A8  | `DEPRECATED` targeting and warning policy                        | Attach to top-level entities and keep the message in the interface file                             | V1.1                                     |
| A9  | `OPTIONS` argument grammar                                       | M1 should lex pragma bodies so raw text can be recovered later                                      | V1.1, with the M1 accommodation          |
| A10 | Private pragma targeting, inline pragmas                         | Keep inline pragmas unsupported                                                                     | V1.1                                     |
| A11 | Existential errors vs. the current `Fiber e a` / `join` API      | Ship exceptions and fibers as experimental until this is decided                                    | Before V1.2 exceptions are marked stable |
| A12 | Atomicity of `Ref` under fibers, channel buffering, cancellation | Depends on the scheduler. Pick host green threads or CPS first                                      | Start of V1.2 fiber work                 |
| A13 | Lazy-arrow Core representation                                   | Reserve `~>` in the M1 lexer now so v0 programs cannot define it. Design after Core is stable       | M1 (reservation), V1.3+ (design)         |
| A14 | JSON/regex APIs, Prelude organization                            | Defer                                                                                               | V1.4                                     |
| A15 | Build configuration, dependencies, FFI                           | Defer                                                                                               | v2                                       |

### B. Gaps and tensions found in the specs

| ID  | Issue                                                                                                                                                                                                   | Recommendation                                                                                                            | Settle by                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| B1  | **Layout algorithm.** §4 says layout is a pre-pass, but blocks begin "where the grammar requires" them, so it is parser-driven. It is also unstated which tokens open a `block_expr` (`=`, `->`, `<-`?) | Parser-driven layout. Enumerate the block-opening positions in a table in the spec                                        | Start of M1                      |
| B2  | **Interpolation lexing.** Nested strings and braces inside `{expr}`, and whether layout is allowed inside                                                                                               | Recursive lexing, brace depth counting, no layout inside interpolations                                                   | M1                               |
| B3  | **Lexical details.** Identifier Unicode classes, the operator character set (`.`, `$`, `@`, `#`, `\`), numeric literal forms, tabs, newline and BOM handling, Unicode escapes                           | Define them in a lexical appendix. Note that `$` lands in the tightest precedence group (9), unlike Haskell               | M1                               |
| B4  | **Entry module naming.** Every path component must be uppercase, so `hello.ficus` cannot be a module, yet `run FILE` runs scripts                                                                       | Exempt the entry file, which becomes `Main`                                                                               | M2                               |
| B5  | **Bare uppercase imports.** `use Foo (Z)` could mean a type, a trait, or both. Constructors have no bare import form. Whether importing `T` alone brings the trait of the same name                     | Type and trait namespace lookups both apply. Constructors only via `T(...)`                                               | M2                               |
| B6  | **Lang-items.** The compiler needs `bind`, `show`, string concatenation, `Result`, and `Ordering` from the Prelude. The spec names none of them for concatenation                                       | A registry of compiler-known entities keyed by defining module and name, not by imported spelling                         | M2                               |
| B7  | **`Show String` vs. interpolation.** Interpolation calls `show`, so `"hi {name}"` would quote `name` if `show` is Haskell-style                                                                         | Make interpolation use a non-quoting rule, or make `Show String` the identity. Amend the spec either way                  | M2 (spec freeze), M7 (instances) |
| B8  | **Refutable patterns.** The rule is referenced but not defined, and there is no failure mechanism for `<-`                                                                                              | Irrefutable means variable, wildcard, unit, or products of irrefutable. Reject all others in `<-` in v0                   | M2                               |
| B9  | **Int semantics.** Width, overflow, division by zero, Float printing                                                                                                                                    | Int64 wrapping, division by zero is a runtime error, literal range checked at elaboration                                 | M3 (before primitives)           |
| B10 | **Proper tail calls.** Not guaranteed in the spec, but scripting code without loops depends on them                                                                                                     | Make tail calls normative                                                                                                 | Start of M3                      |
| B11 | **Value restriction timing.** v0 says generalize normally, v1 introduces a value restriction, which would silently break v0 programs                                                                    | Adopt the value restriction in v0, using the same non-expansive classifier needed for `impl` members                      | Before M3 generalization         |
| B12 | **Monomorphism restriction.** A constrained non-function binding like `x = fromInt 3` becomes a dictionary function, recomputed on each use, which duplicates effects in an impure language             | Do not generalize constrained non-lambda bindings                                                                         | Start of M5                      |
| B13 | **Signatures inside recursive groups.** The spec says monomorphic within a group, which would rule out polymorphic recursion for signed bindings                                                        | Treat signed bindings separately, as THIH does                                                                            | M3                               |
| B14 | **`Field` constraint timing.** A field constraint whose receiver is still a variable at generalization cannot be generalized                                                                            | Solve at the end of each binding group. An unresolved receiver is an error                                                | M4                               |
| B15 | **Kind defaulting and aliases.** Whether unconstrained kind variables default to `Type`, whether aliases must be fully applied, and the kind of type-level literals                                     | Default to `Type`, require full application, and admit literals only as `magic` arguments                                 | M4                               |
| B16 | **Constrained trait methods.** Whether a method signature may carry constraints on other variables (needed for `foldMap`, `traverse`)                                                                   | Allow constraints on non-class variables, forbid them on the class variable                                               | Start of M5                      |
| B17 | **Prelude bootstrap.** The Prelude cannot use `do` or interpolation, and stdlib location and embedding are unspecified                                                                                  | Ship the stdlib as an embedded source root. Layer it as `MAGIC` primitives → sugar-free core modules → Prelude re-exports | M2 (location), M7 (layering)     |
| B18 | **Exhaustiveness warnings.** Spec says "should"                                                                                                                                                         | Implement the standard usefulness algorithm with basic support, extend for empty types in V1.1                            | M7                               |
| B19 | **Prelude IO surface.** There is no IO type, so the primitive set and effect conventions must be listed                                                                                                 | Define a small primitive set before the Prelude is written                                                                | M5–M7                            |

## 5. Critical path

1. **Before writing any parser code:** B1, B2, B3, and the A13 lexer reservation.
2. **Before M2 closes:** B4–B8. These change desugaring output and the Prelude contract, so late changes ripple into M3 onward.
3. **Before M3:** B9, B10, B11, B13. The evaluator skeleton and generalization strategy are both built here.
4. **Before M5:** B12, B14–B16. These shape dictionary elaboration.
5. **Everything in section A** is off the v0 critical path except A1. Its dependents (V1.x) need a decision at the start of their own milestone, apart from the two early accommodations in M1 (A9, A13).

The highest-leverage decisions to settle this week are B1 and B11: one determines the parser architecture, the other silently changes typing rules between v0 and v1.