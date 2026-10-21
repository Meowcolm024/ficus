# v0 standard library

`Prelude.ficus` is the reviewed, selective implicit API. `Class.*` defines traits
and instances for compiler-owned types; `Data.*` defines ordinary types, their
instances, and data operations. `System.IO` supplies the basic impure IO helpers.
`Ficus.Builtin.*` binds compiler keys and never imports the data layer. Primitive
`Bool` and `Unit` already belong to the compiler and need no builtin keys.

Every library module disables implicit Prelude and imports its dependencies
explicitly. `Handle`, `Byte`, `Vec`, and `Ref` require explicit imports. `Void` and
`absurd` are ordinary source definitions in `Data.Void`, re-exported by Prelude.
See [the library design](../docs/PRELUDE.md) and [the specification](../docs/SPEC.md)
for contracts, including strict boolean functions and explicit control thunks.

The package bundles this directory as data files. `ficus compile` searches it by
default; `--library DIR` replaces the library search root, and `--prelude FILE`
overrides the canonical Prelude source. An overridden Prelude's explicit imports
still need corresponding source/library roots.

The compile command checks and elaborates these modules to validated Core.
The runtime API executes them using handle-aware effect callbacks; basic IO
helpers are source-derived from `Ficus.Builtin.Handle`.

The v1 `Data.Ref` module exposes `Ref`, `newRef`, `readRef`, and `modifyRef` from
`Ficus.Builtin.Ref`. Cells remain monomorphic under the existing value restriction.
`Debug a => Debug (Ref a)` displays their current contents as `Ref (...)`.

The v1 `Control.Exception` module exports `Exception`, `throw`, and `catch`.
Prelude exports only the marker trait. `catch (_ -> action) handler` catches the
handler's exact exception type; annotate the handler when inference cannot
select it. Define `impl Exception MyError = {}` alongside a user error type.
Parameterized error types require explicit component constraints, for example
`impl Exception a => Exception (Box a) = {}`. Runtime failures are not catchable;
completed effects survive a throw. See SPEC §24.3 for the complete contract.
