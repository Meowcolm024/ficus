# Semantic fixtures

- `name-resolution/negative/`: import, reserved-name, pragma, and Prelude-sugar checks.
- `type-checking/negative/`: type, annotation, pattern, hole, and initializer checks.

Each phase has an `expectations.json` with proposed diagnostic kinds and one-based
inclusive `[startLine, startColumn, endLine, endColumn]` primary spans. Each negative
file is a separate resolver/checker input module, not a selected executable entry. `sourceRoots` are relative to its phase directory;
record-selection cases load `name-resolution/support/Data/Complex.ficus`, which
actually defines the imported record. Support files are dependencies, not tests.
Use the single shared ../support/Prelude.ficus (relative to semantics/) in the
default provider roots; see ../support/README.md for contracts. Per-case graph
source roots override this and never inherit a fallback library.
The parser suite checks semantic negatives for syntax acceptance. The dedicated
name-resolution suite executes its own fixtures. Type-checker fixture execution
remains future work; the new type-checking sources have additionally been checked
for successful resolution and Abstract validation. Their
[type-checking inventory](type-checking/README.md) includes reproducible GHC and
OCaml translations and records the language differences explicitly.

The positive type-checking MiniPrelude.ficus smoke case exercises arithmetic,
booleans, String operations, interpolation, Maybe/Bind do notation, product
patterns, Eq/Show instances and @ application using the shared library.

Typed do coverage cases return Just values in their final statement so ordinary
Bind typing can succeed before the intended RefutablePattern check. Existing
pattern primary spans are preserved. Syntax-only parser fixtures need not type-check.
