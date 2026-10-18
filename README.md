# ficus

A minimal functional scripting language.

The v0 Megaparsec frontend exposes `Ficus.Syntax.Parser.parseModule`, returning either a
structured diagnostic or an Agda-style typed Concrete AST with source spans,
provenance, comments, and explicit/layout block metadata. The independent resolver
translates Concrete syntax to validated Abstract syntax with canonical names and
source provenance. The elaborator checks kinds, qualified Hindley–Milner types,
records, patterns, and initialization safety, then produces independently
validated typed Core and closed interfaces for dependent modules.
The backend lowers Core to validated, lexically addressed Runtime syntax and
executes it with a closure-threaded interpreter, including the bundled Prelude
and v0 primitives. It supports recursive closures, partial application, explicit
trait dictionaries, strict initialization, and structured runtime errors.
See [SPEC](docs/SPEC.md) for the language and
[parsing fixtures](test/fixtures/parsing/README.md) for test coverage.

Build and run the fixture suite with `stack build` and `stack test`.

The CLI supports:

```sh
stack exec ficus -- --version
stack exec ficus -- compile path/to/Main.ficus
stack exec ficus -- compile --source-root src --library library --prelude library/Prelude.ficus src/Main.ficus
stack exec ficus -- format test/fixtures/parsing/positive/LayoutBraces.ficus
stack exec ficus -- format < test/fixtures/parsing/positive/LayoutBraces.ficus
```

`compile FILE...` parses, resolves, typechecks, and elaborates modules in dependency
order. Type errors and expression holes fail compilation; successful modules
produce validated Core through the `Ficus.Compile` API. The command does not
execute a program, require `main`, or write compiled artifacts.
Diagnostics go to stderr; errors return a nonzero
exit status, while warnings permit success.

Interpreter embedding is available through `FicusBackend.Lower.Runtime` and
`FicusBackend.Runtime`: lower dependency-ordered Core modules, select a global
address, compile the evaluators, and run with supplied effects and arguments.
See [the Runtime API and scope](docs/RUNTIME.md#7-embedding-api). CLI execution
and compiled object files are subsequent work.

The package bundles the v0 standard-library [Prelude](library/Prelude.ficus),
with source modules under `Class`, `Data`, `System`, and `Ficus.Builtin`.
See [the examples](examples/README.md) for complete v0 programs. Optional discovery flags are:

- `--library DIR`: use this standard-library source root instead of the bundled
  directory; repeat to search multiple roots.
- `--prelude FILE`: use this file as the canonical Prelude module. Dependencies
  still use the configured source and library roots.
- `--source-root DIR`: set a project source root; repeat for multiple roots.
  By default, each input file's directory is a project root. Supply a common
  root explicitly when nested directories should form a module path.

These options are for early development and are **subject to change**. Source
roots must identify modules unambiguously; their order does not pick a winner.
The library layout and selected Prelude API are documented in [PRELUDE.md](docs/PRELUDE.md).

`format [FILE]` writes formatted source to stdout. Omit the file or use `-` to read
stdin. Input files are never overwritten. Syntax errors go to stderr and return
a nonzero exit status. Diagnostics include a stable code such as `P0001`, the
source line, and an underline. Source-location filenames are relative to the
working directory; module search paths remain absolute. See [error codes](docs/ERRORS.md).

`Ficus.Syntax.Concrete.Pretty.prettyModule` is a naive AST printer: it normalizes
blocks to braces with four-space indentation, keeps literal spellings and
parentheses, and retains comments in source order above their containing
top-level item. `renderSource` still returns the exact original source text.
