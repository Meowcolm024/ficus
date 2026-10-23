# Feature checklist

This is the implementation tracker. [SPEC.md](SPEC.md) defines behavior;
[PLAN.md](PLAN.md) records dependencies and open decisions; [IMPL.md](IMPL.md)
records architecture. Checked items are implemented and covered by tests.
Unchecked items are pending; a settled design is not a completed feature.

## Implemented baseline

- [x] Unicode lexer, parser-driven layout, uniform pragma syntax, spelling-based operator grouping.
- [x] Concrete, Abstract, Core, and Runtime stages with boundary validators and source diagnostics.
- [x] Namespaces, lexical scope, imports, aliases, selective imports, re-exports, implicit Prelude, and import-cycle checks.
- [x] ADTs, records, aliases, products, lists, nominal fields, and record construction/update.
- [x] Hindley–Milner inference, kinds, explicit type binders/applications, rank-1 signatures, and type/kind holes.
- [x] Expression-hole diagnostics and independent rejection before execution.
- [x] Traits, supertraits, implementation visibility, overlap/orphan checks, dictionaries, and qualified inference.
- [x] Strict evaluation, recursion, ordered initialization, value/monomorphism restrictions, blocks, `where`, `if`, and `do`.
- [x] Pattern coverage, redundancy warnings, and type-directed `do` bind refutability.
- [x] Runtime lowering, compiled evaluator, direct interpreter, arity raising, and wrapper erasure.
- [x] Primitive operations, standard library, selective Prelude, and explicit entry-point validation.
- [x] `compile` checking, `run`, `repl [FILE]`, source formatting, and LSP highlighting/definitions/types.

## v1 language

- [x] Empty types and empty matches, including constructor-free `Data.Void` and source-defined `absurd` ([SPEC §24.1](SPEC.md#241-types-and-patterns)).
- [x] `STANDALONE`: acyclic expansive initializers, ordinary restrictions for cycles/members, and rejection of every incoming import ([SPEC §24.4](SPEC.md#244-pragmas)).
- [x] Explicit record patterns with constructor-style grouping, optional fields, type-directed refutability, and recursive-pattern binding rejection; parser/formatter, evaluator, diagnostic-span, and highlighting coverage ([tests](../test/FicusBackend/RecordPatternSpec.hs)).
- [x] Mutable `Ref`, `newRef`, `readRef`, and `modifyRef` in `Ficus.Builtin.Ref` / `Data.Ref`, shared `REF_*` registry contracts, and `Debug (Ref a)`, preserving the existing value restriction.
- [x] Typed exceptions: trait-targeted `BUILTIN EXCEPTION`, nominal component tokens, constrained primitives, dynamically scoped catches, library/driver integration, and differential/REPL fixtures ([tests](../test/FicusBackend/ExceptionSpec.hs)).
- [x] Catch-all `SomeException` in Prelude: `Show` superclass, source record/member builtin associations, bundled dictionaries, unpacking evidence, and rethrowing with the original nominal identity; primitive-error, renamed-member, contract, and differential fixtures ([SPEC §24.3](SPEC.md#243-exceptions)).
- [x] Source-defined builtin data types and primitive constructors (`DataBuiltin` / `ConstrBuiltin`), with typed arithmetic/conversion/IO/match failures, removal of Runtime `Raise Text`, validated runtime layouts, and contract/differential fixtures.
- [x] File IO: `openFile`, `close`, source-defined builtin `IOMode` constructors, typed failures, and compiled/direct temporary-file tests ([tests](../test/FicusBackend/FileIOSpec.hs)).
- [ ] Exception cleanup combinators and higher-kinded exception heads.
- [ ] Definition pragmas in implementation, `where`, local, and `do` declaration contexts.
- [ ] Definition-local `ETA` expansion with preserved initializer timing.
- [ ] `PRIVATE` / `PRIVATE member`, including constructor and field visibility.
- [ ] `DEPRECATED` targets, placement, and warning policy.
- [ ] Module `OPTIONS` interpretation and CLI precedence.
- [ ] Structural `DERIVE` for empty `Show`/`Eq` implementations.
- [ ] Expression interpolation: settle delimiters and escapes.
- [ ] Expanded libraries: `System.Environment`, `Data.Map`, JSON, and regular expressions.
- [x] Existential record members: parsing, kinds, witness inference, named and anonymous unpacking, non-escape checks, dependent projection rejection, captured trait dictionaries, Core/Runtime lowering, and an [example with traits](../examples/Existentials.ficus) ([tests](../test/FicusBackend/RecordPatternSpec.hs)).
- [ ] Existential record updates and records containing only type members.
- [ ] Coverage through uninhabited fields and subpatterns beyond direct empty nominal types.

## v1 tooling and artifacts

- [ ] Interface/object serialization, schemas, version compatibility, linking, and output paths.
- [ ] Loading compiled artifacts in command-line and interactive execution.
- [ ] Canonical formatter policy beyond the current Concrete pretty-printer.

## v2

- [x] Call-by-name `~>` arrows, distinct arrow types, and explicit non-memoizing thunks.
- [ ] JavaScript backend with evaluator-equivalence checks.
- [ ] Tail-call optimization and a specified constant-stack guarantee.
- [ ] Build system, package configuration, dependency resolution, and libraries beyond Prelude.
- [ ] `FOREIGN` declarations, backend support, conversions, and calling conventions.
- [ ] Fibers and typed channels: settle scheduling, buffering, cancellation, and reference interactions.

## v3 and later

- [ ] Select and implement a WebAssembly GC or LLVM backend, runtime representation, and memory management.
- [ ] Higher-rank polymorphism; other excluded extensions need designs before implementation.

For v1 acceptance evidence, see [test/FicusBackend/V1Spec.hs](../test/FicusBackend/V1Spec.hs),
[test/FicusBackend/RefSpec.hs](../test/FicusBackend/RefSpec.hs), the parser
fixtures, and the runtime differential tests. Reference tests cover aliasing,
updater order and failure, debug output, builtin contracts, and unsafe
generalization. Update this checklist with each feature change.
