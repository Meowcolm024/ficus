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
- [ ] Explicit record patterns, optional fields, and type-directed refutability; reject recursive pattern bindings.
- [ ] Mutable `Ref`, `newRef`, `readRef`, and `modifyRef` with the existing value restriction.
- [ ] Typed exceptions: settle runtime type identity, cleanup, and `throw`/`catch` contracts before implementation.
- [ ] Definition pragmas in implementation, `where`, local, and `do` declaration contexts.
- [ ] Definition-local `ETA` expansion with preserved initializer timing.
- [ ] `PRIVATE` / `PRIVATE member`, including constructor and field visibility.
- [ ] `DEPRECATED` targets, placement, and warning policy.
- [ ] Module `OPTIONS` interpretation and CLI precedence.
- [ ] Structural `DERIVE` for empty `Show`/`Eq` implementations.
- [ ] Expression interpolation: settle delimiters and escapes.
- [ ] Expanded libraries: `System.Environment`, `Data.Map`, `Control.Exception`, JSON, and regular expressions.
- [ ] Existential record members: settle witness inference, escape checks, updates, and exception API interaction (proposal).
- [ ] Coverage through uninhabited fields and subpatterns beyond direct empty nominal types.

## v1 tooling and artifacts

- [ ] Interface/object serialization, schemas, version compatibility, linking, and output paths.
- [ ] Loading compiled artifacts in command-line and interactive execution.
- [ ] Canonical formatter policy beyond the current Concrete pretty-printer.

## v2

- [ ] Call-by-name `~>` arrows, distinct arrow types, and explicit non-memoizing thunks.
- [ ] JavaScript backend with evaluator-equivalence checks.
- [ ] Tail-call optimization and a specified constant-stack guarantee.
- [ ] Build system, package configuration, dependency resolution, and libraries beyond Prelude.
- [ ] `FOREIGN` declarations, backend support, conversions, and calling conventions.
- [ ] Fibers and typed channels: settle scheduling, buffering, cancellation, and reference interactions.

## v3 and later

- [ ] Select and implement a WebAssembly GC or LLVM backend, runtime representation, and memory management.
- [ ] Higher-rank polymorphism; other excluded extensions need designs before implementation.

For acceptance evidence for the two initial v1 additions, see
[test/Ficus/V1Spec.hs](../test/Ficus/V1Spec.hs), the parser fixtures, and the
runtime differential tests. Update this checklist with each feature change.
