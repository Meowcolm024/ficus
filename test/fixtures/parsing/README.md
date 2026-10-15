# Parsing fixtures

Source cases for SPEC §§2–5, 7–8, 14, 18–19 and IMPL §1.3; no runner exists yet.
These are authored expectations, not AST goldens. Tests have not been run.

- `positive/`: parser acceptance only; names need not resolve or type-check.
  Covers the v0 EBNF productions, layout/braces pairs, operator grouping,
  control interactions, names/literals, patterns/annotations, and shared prefixes.
- `negative/`: isolated lexical, layout, or syntax rejections.
- `expectations.json`: proposed diagnostic kinds and primary spans for rejections;
  spans are `[startLine, startColumn, endLine, endColumn]`, one-based and inclusive.
  EOF spans are zero-width. Assert kinds/spans, not full diagnostic wording.

Positive source comments specify key grouping/boundary assertions for a future
Concrete AST runner. Preserve comments, explicit/layout delimiters, ordinary
identifier/operator nodes, and unresolved dotted chains. `positive/RecordWith.ficus`
and the prefixed rejection files incorporate the previous record-with corpus.

Semantic rejections are separate in `../semantics/name-resolution/` and
`../semantics/type-checking/`.

`positive/RefutabilityIsSemantic.ficus` deliberately includes patterns whose
coverage may fail after typing. Parser acceptance must not depend on a whitelist
of supposedly irrefutable syntax. Existing v0 RecordPatternBinder/Match negatives
remain version gates, not refutability checks. V1 record/type-member parser cases
are inventoried in `../record-patterns/`; v2 lazy-arrow cases are in
`../lazy-arrows/`.
