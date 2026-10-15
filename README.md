# ficus

A minimal functional scripting language.

The v0 Megaparsec frontend exposes `Ficus.Syntax.Parser.parseModule`, returning either a
structured diagnostic or an Agda-style typed Concrete AST with source spans,
provenance, comments, and explicit/layout block metadata. Names and dotted chains
remain unresolved. See [SPEC](docs/SPEC.md) for the language and
[parsing fixtures](test/fixtures/parsing/README.md) for test coverage.

Build and run the fixture suite with `stack build` and `stack test`.
