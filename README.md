# ficus

A minimal functional scripting language.

The v0 Megaparsec frontend exposes `Ficus.Syntax.Parser.parseModule`, returning either a
structured diagnostic or an Agda-style typed Concrete AST with source spans,
provenance, comments, and explicit/layout block metadata. Names and dotted chains
remain unresolved. See [SPEC](docs/SPEC.md) for the language and
[parsing fixtures](test/fixtures/parsing/README.md) for test coverage.

Build and run the fixture suite with `stack build` and `stack test`.

The CLI supports:

```sh
stack exec ficus -- version
stack exec ficus -- --version
stack exec ficus -- format test/fixtures/parsing/positive/LayoutBraces.ficus
stack exec ficus -- format < test/fixtures/parsing/positive/LayoutBraces.ficus
```

`format [FILE]` writes formatted source to stdout. Omit the file or use `-` to read
stdin. Input files are never overwritten. Syntax errors go to stderr and return
a nonzero exit status. Diagnostics include a stable code such as `P0001`, the
source line, and an underline. See [error codes](docs/ERRORS.md).

`Ficus.Syntax.Concrete.Pretty.prettyModule` is a naive AST printer: it normalizes
blocks to braces with four-space indentation, keeps literal spellings and
parentheses, and retains comments in source order above their containing
top-level item. `renderSource` still returns the exact original source text.
