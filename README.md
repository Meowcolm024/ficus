# ficus

A small, strictly evaluated functional scripting language with type inference,
algebraic data types, records, traits, and a bundled standard library. Programs
execute through a closure-threaded interpreter.

## Build and test

```sh
stack build
stack test
```

## Run a program

```sh
stack exec ficus -- run examples/Main.ficus -- hello world
```

The selected file must define its own entry point with one of these types:

```text
main : [String] -> Unit
main : [String] -> Result String Unit
```

Only arguments after the filename are passed to `main`. Use `--` before program
arguments that could be interpreted as CLI options. Returning `Unit` or `Ok ()`
succeeds; `Err message` writes the message to stderr and exits with status 1.
Compilation, entry-point, and runtime errors also exit with status 1. Runtime
failures use `R0001` with an explanatory message; generated failure messages
include source context where available.

See [examples](examples/README.md) for complete programs.

## Interactive use

For editor support, run `stack exec ficus -- lsp`. The language server provides
diagnostics, inferred-type hover, go-to-definition, and semantic highlighting,
including unsaved files and their imports. See [LSP setup and behavior](docs/LSP.md).

```sh
stack exec ficus -- repl
stack exec ficus -- repl examples/Main.ficus
```

Evaluate expressions or add single-line declarations:

```text
ficus> double x = x + x
ficus> double 21
42
ficus> :type double
double : Add a => a -> a
ficus> use Data.Vec (..)
ficus> vecLength (listToVec [1, 2, 3])
3
```

| Command | Short form | Purpose |
| --- | --- | --- |
| `:load FILE` | `:l FILE` | Load or reload a file and its dependencies |
| `:type EXPR` | `:t EXPR` | Inspect a term expression's type without evaluation |
| `:kind TYPE` | `:k TYPE` | Infer a type-level expression's kind |
| `:help` | `:h` | Show commands and usage |
| `:quit` | `:q` | Exit; end of input also exits |

For example, `:k Functor` shows `Functor : (Type -> Type) -> Constraint`.
`:t 1` shows `1 : Int`; applications and lambdas also work.
`:k Maybe Int` shows `Maybe Int : Type`, and `:k Show Int` shows
`Show Int : Constraint`.

Loading a file brings its exports into scope without invoking `main`. A
successful load replaces interactive declarations and imports. Failed commands
and runtime errors, including division by zero, leave the previous session
usable. Effects already performed are not rolled back. REPL results are
formatted with `Debug`, so their types need a visible instance.

Ordinary `use` imports work interactively, including selections and aliases.
Interactive bindings may evaluate expressions immediately, and later inputs
can rebind values or types:

```text
ficus> x = 20 + 1
ficus> x = x + 1
ficus> x
22
```

Existing closures keep their earlier bindings, and previous initializers are not
rerun. Replacing a type creates a new nominal type and may reuse constructors
owned by the type being replaced. Constructor names belonging to unrelated
types cannot be overwritten. Value restrictions and recursive safety checks
still apply; ordinary source-file rules are unchanged.

## Check and format source

```sh
stack exec ficus -- compile examples/Main.ficus examples/Collections.ficus
stack exec ficus -- format examples/Main.ficus
stack exec ficus -- format < examples/Main.ficus
stack exec ficus -- --version
```

`compile FILE...` checks modules in dependency order and produces validated Core
through the compiler API. It emits no artifacts and does not execute `main`.
`format [FILE]` writes formatted source to stdout; omit FILE or use `-` to read
stdin. Input files are never overwritten.

Diagnostics go to stderr with a stable code and source location. ANSI-capable
terminals get colored diagnostics; use `--no-color` before the command to disable
colors (for example, `ficus --no-color compile Main.ficus`). Redirected diagnostics
remain plain text. Errors produce a nonzero exit status; warnings permit success.
See [error codes](docs/ERRORS.md).

## Module discovery

The standard library is bundled with the package. `run`, `repl`, and `compile`
accept these options:

- `--library DIR`: replace the bundled library root; repeat for multiple roots.
- `--prelude FILE`: override the canonical Prelude file. Its dependencies still
  use the configured source and library roots.
- `--source-root DIR`: set project roots; repeat for multiple roots. By default,
  source files use their containing directory, and an empty REPL uses the
  current directory. Set a common root for nested module paths.

Source roots must identify modules unambiguously; their order does not select a
winner. See [the standard library](docs/PRELUDE.md) for its layout and Prelude API.

## Compiler and runtime APIs

`Ficus.Compile` discovers, resolves, and elaborates source to validated typed
Core. Backend drivers in `FicusBackend.Driver.Run` and
`FicusBackend.Driver.Repl` consume those results. The REPL retains inferred
schemes, evaluated values and compiled runtime closures, with source snapshots
for reload and stable constructor layouts; Core is temporary compilation data.

For interpreter embedding, use `FicusBackend.Lower.Runtime` and
`FicusBackend.Runtime` to lower dependency-ordered Core modules, select an
address, and execute with supplied effects. See [the Runtime API](docs/RUNTIME.md#7-embedding-api).

[Specification](docs/SPEC.md) · [Implementation](docs/IMPL.md) ·
[Runtime design](docs/RUNTIME.md) · [Tests](test/fixtures/parsing/README.md)
