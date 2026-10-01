# Semantic fixtures

- `name-resolution/negative/`: import, reserved-name, pragma, and Prelude-sugar checks.
- `type-checking/negative/`: type, annotation, pattern, hole, and initializer checks.

Each phase has an `expectations.json` with proposed diagnostic kinds and one-based
inclusive `[startLine, startColumn, endLine, endColumn]` primary spans. Each negative
file is a separate entry module. `sourceRoots` are relative to its phase directory;
record-selection cases load `name-resolution/support/Data/Complex.ficus`, which
actually defines the imported record. Support files are dependencies, not tests.
No implementation or fixture runner exists yet; tests were not run.
