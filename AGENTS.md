# AGENTS.md

## Source of truth

SPEC.md is normative for language behavior. IMPL.md is non-normative.
If they conflict, SPEC wins. If code and SPEC conflict, stop and ask
which is wrong rather than picking one.
Never change language behavior without updating SPEC.md in the same change.

## Architecture invariants (easy to break)

- Stages: Concrete → Abstract → Core → Runtime. No stage reaches back into an earlier one's types. Each boundary has a validator; run it in tests.
- Every AST node carries a source span and provenance. Generated nodes (lambdas, matches, dictionary evidence) get their origin's span, never a neighbor's.
- The parser has no special cases for `::`, `Type`, `magic`, `True`, `False`. These are ordinary identifiers, resolved later. All pragmas share an ALL_CAPITAL name and identifier/string arguments; no directive has a special parser production. `BUILTIN` keys are metadata; targets follow ordinary namespace and scope rules.
- Operator grouping is dynamic and spelling-based. Do not enumerate operators and do not add fixity declarations. 
- Dotted chains stay uncommitted in the Concrete AST. Only name resolution decides module prefix vs. field projection. 
- `if` stays a distinct node through Core. Do not desugar it to `with`.
- Runtime AST does no string-based name lookup.
- Evaluation order is strict and left-to-right everywhere. Preserve it in any optimization.
- Expression holes are hard errors after inference and never reach Core.

## Testing

- Every spec rule gets a fixture. Negative fixtures assert the diagnostic kind and primary span, not the full wording.
- Property tests: parse/pretty-print round trip, formatter idempotence, compiled evaluator == direct interpreter (differential).
- Never edit golden files by hand or bulk-accept. Review the diff of each.
- A bug fix starts with a failing fixture.

## Haskell conventions

This is a Stack project. Follow the existing project structure and style.

- Use `stack build`, `stack test`, and `stack repl` for building, testing,
  and interactive exploration.
- Run project executables through `stack exec <name> -- ...`; do not invoke
  binaries from `.stack-work` directly.
- Prefer targeted builds/tests during iteration, then run the relevant full
  checks before finishing.
- Treat `.stack-work/`, `*.cabal` and other generated directories as opaque; do not
  search, inspect, or edit them.
- Make small, reviewable changes. Do not refactor unrelated code.

### Code style

- Prefer `newtype` over a single-field `data` declaration when their
  semantics are appropriate.
- Prefer `Text` over `String` for application data. Convert at external API
  boundaries when necessary.
- Prefer total functions and exhaustive pattern matching.
- Avoid `undefined`, `error`, `fromJust`, `head`, and similar partial
  functions unless an existing invariant clearly justifies them.
- Prefer explicit, readable code over clever abstractions.
- Avoid complicated point-free expressions; name intermediate operations
  when that improves readability.
- Do not introduce unnecessary type classes, transformer layers, or
  type-level machinery.
- Follow existing conventions for records, strictness, effects, and error
  handling.

### Language extensions

Before adding a `{-# LANGUAGE ... #-}` pragma to a source file, inspect
`package.yaml` for project/component-wide `default-extensions`.

- Do not duplicate an extension already enabled by `package.yaml`.
- Prefer the existing project-wide extension policy.
- Add a file-local extension only when it is genuinely local to that module.
- Do not add extensions merely to work around a type/design problem.

### Types and refactoring

- Preserve public APIs and behavior unless the task explicitly changes them.
- Treat type errors as useful design feedback; understand them before adding
  constraints, coercions, or weakening types.
- Do not perform unrelated cleanup during a focused change.
- Do not add dependencies without checking `package.yaml` and existing
  dependencies first.

### Exploration

- Use `rg` for textual search and `fd` for files.
- Use `stack repl` to inspect types and test small expressions when useful.
- Do not recursively search `.stack-work/`, `.git/`, or generated output.
- When uncertain about a Haskell type, instance, or imported API, prefer
  checking it with `stack repl` (`:t`, `:i`, `:kind!`) rather than guessing.

### Before finishing

- Inspect the diff for accidental or unrelated changes.
- Run the relevant formatter/linter if the project already uses one.
- Run `stack build` and the relevant tests.
- Do not suppress warnings or change expected test results merely to make
  checks pass.
