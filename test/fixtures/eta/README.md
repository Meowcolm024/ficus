# ETA and definition pragma fixtures (v1+)

These source fixtures are not wired into the scaffold test suite and have not
been executed. DefinitionScopes.ficus is a positive v1+ parsing/attachment case,
covering top level, impl members, where, expression blocks, and do declarations.
In v0 it must fail semantic validation of pragma support/placement, not use a
special directive parser production. The ordinary syntax of all pragmas remains
shared.

Negative semantic categories and designated one-based primary spans:

| File | Category | Primary span |
| --- | --- | --- |
| NonFunction.ficus | InvalidPragmaTarget | 1:5–7 (ETA) |
| Arguments.ficus | InvalidPragmaArguments | 1:9–15 (printer) |
| Bodyless.ficus | MissingPragmaTarget | 2:5–7 (ETA) |

Wire these categories to the implementation's diagnostic kinds when the runner
exists; assert the kind and primary span, not diagnostic prose. A signature alone
is not an initializer that ETA can expand.

Additional type/elaboration/runtime cases must verify:

- ETA affects only its attached definition, never sibling or nested definitions or
  a whole module/scope. Unannotated expansive bindings retain their usual checks.
- One outer lambda is generated, with fresh binder and original provenance.
- Complete initializer work, including immediate where groups, is inside it.
- Non-expansiveness and generalization eligibility are checked after expansion.
- Original initializer effects occur on application and repeat across calls.
- Curried intermediate work is not delayed until all result arrows are applied.
- Recursive references are checked after expansion for lambda protection.
- Source-based monomorphism checks remain; ETA does not silently remove constraints.
- Unnamed pattern targets, module pragmas in local scopes, and arbitrary expression
  pragma placement are rejected.
- Existing written-parameter where timing inside the expanded initializer survives.
