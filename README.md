# ficus

A minimal functional scripting language.

The v0 Megaparsec frontend exposes `Ficus.Syntax.Parser.parseModule`, returning either a
structured diagnostic or an Agda-style typed Concrete AST with source spans,
provenance, comments, and explicit/layout block metadata. The independent resolver
translates Concrete syntax to validated Abstract syntax with canonical names and
source provenance. See [SPEC](docs/SPEC.md) for the language and
[parsing fixtures](test/fixtures/parsing/README.md) for test coverage.

Build and run the fixture suite with `stack build` and `stack test`.

The CLI supports:

```sh
stack exec ficus -- version
stack exec ficus -- --version
stack exec ficus -- compile path/to/Main.ficus
stack exec ficus -- compile --source-root src --library library --prelude library/Prelude.ficus src/Main.ficus
stack exec ficus -- format test/fixtures/parsing/positive/LayoutBraces.ficus
stack exec ficus -- format < test/fixtures/parsing/positive/LayoutBraces.ficus
```

`compile FILE...` currently checks parsing and name resolution and returns
success when they pass. It does not type-check, execute a program, require `main`,
or write compiled artifacts. Diagnostics go to stderr; errors return a nonzero
exit status, while warnings permit success.

The package bundles the early-development placeholder [Prelude](library/Prelude.ficus),
copied from the shared fixture. Optional discovery flags are:

- `--library DIR`: use this standard-library source root instead of the bundled
  directory; repeat to search multiple roots.
- `--prelude FILE`: use this file as the canonical Prelude module. Dependencies
  still use the configured source and library roots.
- `--source-root DIR`: set a project source root; repeat for multiple roots.
  By default, each input file's directory is a project root. Supply a common
  root explicitly when nested directories should form a module path.

These options are for early development and are **subject to change**. Source
roots must identify modules unambiguously; their order does not pick a winner.
The placeholder library's API and layout are also provisional.

`format [FILE]` writes formatted source to stdout. Omit the file or use `-` to read
stdin. Input files are never overwritten. Syntax errors go to stderr and return
a nonzero exit status. Diagnostics include a stable code such as `P0001`, the
source line, and an underline. Source-location filenames are relative to the
working directory; module search paths remain absolute. See [error codes](docs/ERRORS.md).

`Ficus.Syntax.Concrete.Pretty.prettyModule` is a naive AST printer: it normalizes
blocks to braces with four-space indentation, keeps literal spellings and
parentheses, and retains comments in source order above their containing
top-level item. `renderSource` still returns the exact original source text.
