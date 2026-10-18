# v0 standard library

`Prelude.ficus` is the reviewed, selective implicit API. `Class.*` defines traits
and instances for compiler-owned types; `Data.*` defines ordinary types, their
instances, and data operations. `System.IO` supplies the basic impure IO helpers.
`Ficus.Builtin.*` binds compiler keys and never imports the data layer. Primitive
`Bool` and `Unit` already belong to the compiler and need no builtin keys.

Every library module disables implicit Prelude and imports its dependencies
explicitly. `Handle`, `Byte`, and `Vec` require explicit imports. `Void` and
`absurd` are re-exported by Prelude while v0 lacks empty source datatypes.
See [the library design](../docs/PRELUDE.md) and [the specification](../docs/SPEC.md)
for contracts, including strict boolean functions and explicit control thunks.

The package bundles this directory as data files. `ficus compile` searches it by
default; `--library DIR` replaces the library search root, and `--prelude FILE`
overrides the canonical Prelude source. An overridden Prelude's explicit imports
still need corresponding source/library roots.

The compile command checks and elaborates these modules to validated Core.
The runtime API executes them using handle-aware effect callbacks; basic IO
helpers are source-derived from `Ficus.Builtin.Handle`.
