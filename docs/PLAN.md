# Ficus implementation plan

**NON NORMATIVE, REFERENCE ONLY!**

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
|M2|Resolution and desugar|Module graph and import cycles, `use` forms including `T(..)` and `pub`, namespaces, uppercase-prefix dotted resolution, dynamic operator grouping with the mixed-associativity error, clause grouping, `do` and interpolation sugar, Prelude-disabled errors, binding-group SCCs with non-expansive initializer and lambda-protection checks|Abstract AST validator passes. Unresolved or ambiguous names, duplicate groups and unsafe recursion are diagnosed; sequential shadowing warns|L|
|M3|Walking skeleton|Monomorphic-to-let-polymorphic HM without traits, first-order ADTs, products, lists, patterns, `if`, `where`, generalization, Core AST + validator, minimal Runtime AST, closure-compiled evaluator, minimal `MAGIC` registry (`addInt`, printing)|A non-trivial program (list functions, mutual recursion via `where`) runs end to end|L|
|M4|Types complete|Kind inference and kind annotations, aliases (expansion, kind signatures), type/kind holes, records, `Field` constraints, expression holes, ambiguity check, type-literal admission|Kind, hole, record and alias fixtures pass, including the `_ -> _ _ Int` example|M|
|M5|Traits|Trait/impl validation (Haskell 98 heads), superclass SCC check, coherence, orphan rule after alias expansion, entailment, dictionary elaboration, non-expansive `impl` check, proof-dictionary erasure, derived functions such as `(/=)`|`Functor []`, `Bifunctor (*)`, and `Monad` via marker traits all work. Overlap, orphan and cycle diagnostics work|L|
|M6|Runtime completeness|Arity raising, newtype erasure, lexical addressing, Runtime AST validator, a direct interpreter as test oracle, differential tests, optional backend-specific tail-call optimization, runtime error provenance|Compiled and oracle evaluators agree on values, errors and effect order across the fixture corpus|M|
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
| A11 | Runtime nominal identity for typed `catch`, plus existential errors vs. `Fiber e a` / `join` | Decide whether exception evidence or another runtime token carries identity; keep the API provisional | Before v1+ exception implementation |
| A12 | Atomicity of `Ref` under fibers, channel buffering, cancellation | Depends on the scheduler. Pick host green threads or CPS first                                      | Start of V1.2 fiber work                 |
| A13 | Lazy-arrow Core representation                                   | Reserve `~>` in the M1 lexer now so v0 programs cannot define it. Design after Core is stable       | M1 (reservation), V1.3+ (design)         |
| A14 | JSON/regex APIs, Prelude organization                            | Defer                                                                                               | V1.4                                     |
| A15 | Build configuration, dependencies, FFI                           | Defer                                                                                               | v2                                       |

### B. Gaps and tensions found in the specs

| ID  | Issue                                                                                                                                                                                                   | Recommendation                                                                                                            | Settle by                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| B1  | **Layout algorithm.** Parser-driven layout is settled; expression blocks require explicit braces or newline plus indentation after an expression introducer | Add fixtures for `with` scrutinee boundaries and nested `=`/`<-` lookahead | Start of M1 |
| B2  | **Interpolation lexing.** v0 accepts bare or module-qualified variables only; expression interpolation is v1+                                                                                           | Scan names without nested expression parsing in v0; defer expression-interpolation lexing rules                         | M1 / v1+                        |
| B3  | **Lexical details.** Dot separation, embedded operator dots, `--` versus `-->`, and brace escapes are settled; identifier Unicode classes, the remaining operator characters, numeric literal forms, tabs, BOM handling, and Unicode escapes are open | Define remaining rules in a lexical appendix | M1 |
| B4  | **Entry module naming.** Every path component must be uppercase, so `hello.ficus` cannot be a module, yet `run FILE` runs scripts                                                                       | Exempt the entry file, which becomes `Main`                                                                               | M2                               |
| B5  | **Bare uppercase imports.** Types and traits share one namespace; a bare `Z` resolves to the single entity in that namespace                                                                           | Implement one type/trait namespace; constructors remain explicitly selected through `T(...)`                            | M2                               |
| B6  | **Compiler-known entities.** Identity must survive aliases, selective imports, and re-exports                                                                                                           | Key the registry by defining module and declared name; exact string-concatenation API remains open                       | M2                               |
| B7  | **`Show String` vs. interpolation.** Interpolation calls `show`                                                                                                                                        | Implement `Show String` as the identity                                                                                   | M7 (instances)                  |
| B8  | **Refutable patterns.** v0 `<-` has no failure mechanism                                                                                                                                                 | Accept only variables, wildcards, unit, and products of irrefutable patterns                                             | M2                               |
| B9  | **Numeric edge cases.** `Int` is signed 64-bit with wrapping arithmetic; `Float` is binary64                                                                                                              | Decide division by zero, literal range, conversions, and float display separately                                        | M3 (before primitives)           |
| B10 | **Tail calls.** Tail-call optimization is backend-dependent                                                                                                                                               | Keep tail-position metadata where useful; do not promise constant-stack recursion                                      | M6                               |
| B11 | **Value restriction.** v0 uses the non-expansive classifier already needed for `impl` members                                                                                                             | Enforce at every binding-group generalization boundary                                                                   | Before M3 generalization         |
| B12 | **Monomorphism restriction.** Unsigned constrained non-lambda bindings retain one monotype; a complete signature overrides this restriction | Check the signature against the definition and the value restriction | Start of M5 |
| B13 | **Signatures inside recursive groups.** Signed bindings admit polymorphic recursive uses; unsigned bindings stay monomorphic | Require non-expansive cyclic initializers and lambda-protected intra-SCC references | M3 |
| B14 | **`Field` constraint timing.** Pending field variables stay weak across nested groups and use sites | Solve once the receiver is fixed; reject unresolved receivers by module end | M4 |
| B15 | **Kind defaulting and aliases.** Unconstrained kinds default to `Type` with a warning; aliases require full application and acyclic definitions | Implement these rules; the kind of type-level literals remains open | M4 |
| B16 | **Constrained trait methods.** Methods may constrain other variables but must mention the trait parameter in their value type | Elaborate method predicates and reject missing trait-parameter occurrences | Start of M5 |
| B17 | **Prelude bootstrap.** The Prelude cannot use `do` or interpolation, and stdlib location and embedding are unspecified                                                                                  | Ship the stdlib as an embedded source root. Layer it as `MAGIC` primitives → sugar-free core modules → Prelude re-exports | M2 (location), M7 (layering)     |
| B18 | **Exhaustiveness warnings.** Spec says "should"                                                                                                                                                         | Implement the standard usefulness algorithm with basic support, extend for empty types in V1.1                            | M7                               |
| B19 | **Prelude IO surface.** There is no IO type, so the primitive set and effect conventions must be listed                                                                                                 | Define a small primitive set before the Prelude is written                                                                | M5–M7                            |

## 5. Critical path

1. **Before writing any parser code:** B1, B2, B3, and the A13 lexer reservation.
2. **Before M2 closes:** B4–B8. These change desugaring output and the Prelude contract, so late changes ripple into M3 onward.
3. **Before M3:** the remaining B9 numeric edge cases, plus implementation of settled B11 and B13. The evaluator skeleton and generalization strategy are both built here.
4. **Before M5:** implement settled B12 and B14, and resolve the remaining parts of B15–B16. These shape dictionary elaboration.
5. **Everything in section A** is off the v0 critical path except A1. Its dependents (V1.x) need a decision at the start of their own milestone, apart from the two early accommodations in M1 (A9, A13).

The parser-driven layout architecture and v0 value restriction are settled. Fixtures still need to exercise layout boundaries, shadowing, recursive initialization, weak variables, and signed versus unsigned constrained bindings once the parser and checker exist.
