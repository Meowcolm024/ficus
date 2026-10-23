# v0 standard library

`Prelude.ficus` is the reviewed, selective implicit API. `Class.*` defines traits
and instances for compiler-owned types; `Data.*` defines ordinary types, their
instances, and data operations. `System.IO` supplies the basic impure IO helpers.
`Ficus.Builtin.*` binds compiler keys. Self-contained builtin modules are preferred;
imports are permitted provided dependencies remain acyclic. Primitive
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

The v1 `Control.Exception` module exports `Exception`, `SomeException`, `throw`, and `catch`.
Prelude exports the trait and `SomeException`. `catch (_ -> action) handler` catches the
handler's exact exception type, or all typed exceptions for `SomeException`; annotate the handler when inference cannot
select it. Define `Show MyError` and `impl Exception MyError = {}` alongside a user error type; `Exception` requires `Show`.
Parameterized error types require explicit component constraints, for example
`impl Exception a => Exception (Box a) = {}`. Runtime failures are not catchable;
completed effects survive a throw. See SPEC §24.3 for the complete contract.

`Control.Exception` also exports `ArithmeticError(..)`, `IOError(..)`, and
`MatchError(..)`. Integer division/remainder by zero throws `DivisionByZero`;
invalid float-to-int conversion throws `InvalidConversion message`; handle and
host IO failures throw `IOError operation message`; failed patterns and unmatched
conditionals throw `MatchError message`. These are source-defined types and
primitive constructors in `Ficus.Builtin.Errors` with compiler-key associations.

The v1 `System.IO` extension exports `openFile`, `close`, and `IOMode(..)`
(`ReadMode`, `WriteMode`, `AppendMode`, `ReadWriteMode`). Use existing `read`,
`write`, and `readLineFrom` with file handles. Files use UTF-8 and preserve line
endings; close files explicitly. Failed file operations throw `IOError`.
Standard streams remain owned by the runtime and cannot be closed through this
API. These declarations are explicit imports.

A handler annotated as `SomeException` catches every typed exception:

```text
catch (_ -> throw 42) ((error : SomeException) -> println (show error))
```

The package exposes `Err : Type`, `err : Err`, and `showErr : Err -> String`
through ordinary existential unpacking. It retains the hidden `Exception`
dictionary. Rethrowing it preserves the original exception type, so an enclosing
`Int` handler can catch the value above.
