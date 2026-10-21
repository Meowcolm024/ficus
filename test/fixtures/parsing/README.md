# Parsing fixtures

Executable source cases for SPEC §§2–5, 7–8, 14, 18–19 and IMPL §1.3.
Run `stack test` or target a case with
`stack test --test-arguments='-p NamesLiterals'`.
The Haskell runner lives in `test/Ficus/Parser/Spec.hs`.

- `positive/`: parser acceptance only; names need not resolve or type-check.
  Covers the v0 EBNF productions, layout/braces pairs, operator grouping,
  control interactions, names/literals, patterns/annotations, shared prefixes,
  explicit type binders/arguments, and expression introducer boundaries.
- `negative/`: isolated lexical, layout, or syntax rejections.
- `expectations.json`: authored diagnostic kinds and primary spans for rejections;
  spans are `[startLine, startColumn, endLine, endColumn]`, one-based and inclusive.
  EOF spans are zero-width. Tests assert kinds/spans, not diagnostic wording.
  The runner checks that the negative files and manifest entries match exactly.

Positive source comments specify grouping/boundary assertions. The runner also
checks typed Concrete structure, comments, explicit/layout delimiters, ordinary
names/operators, unresolved dotted chains, source preservation, and the Concrete
boundary validator. Every accepted fixture is also pretty-printed and reparsed;
the full typed syntax and comment text must match after ignoring source maps and
normalizing block delimiters to braces. Formatting must be idempotent. QuickCheck
checks these properties on generated expressions as well as lossless source
rendering (`renderSource`). Pretty-printer tests are in
`test/Ficus/Parser/PrettySpec.hs`. Evaluator differential properties need the later
evaluator stages.

Semantic rejections are separate in `../semantics/name-resolution/` and
`../semantics/type-checking/`. This suite checks that those sources parse, without
claiming to implement their semantic diagnostics.

`positive/RefutabilityIsSemantic.ficus` deliberately includes patterns whose
coverage may fail after typing. Parser acceptance does not depend on a whitelist
of supposedly irrefutable syntax. `positive/RecordPatternBinder.ficus`,
`positive/RecordPatternMatch.ficus`, and `positive/RecordPatterns.ficus` cover
explicit named record patterns. Negative cases reject layout blocks, punning,
commas, and unsupported type-member labels. Executed semantic cases are in
`../compile/record-patterns/`; existential type-member proposals remain in
`../record-patterns/`. V2 lazy-arrow cases are in `../lazy-arrows/`.
