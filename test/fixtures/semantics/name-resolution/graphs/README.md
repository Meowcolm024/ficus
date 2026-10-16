# Module graph fixture projects

Each case is a separate source-root universe under Case/src. Resolve the entry
filename relative to that root; entry files remain ordinary modules with their
filename-derived identity. These are resolver-only entry inputs, not selected
program entry modules, so no main function is required. The injected provider
must use only the listed roots, with no fallback to a real Prelude, the shared
test/fixtures/support/Prelude.ficus, or another graph case. Paths in primary/related locations
are relative to Case/src. sourceRoots paths are relative to Case/.

expectations.json is an authored future-resolver manifest, not an AST golden.
It records code, diagnostic kind, primary span, import origin, and (for cycles)
the canonical closed module path and non-closing related edges in traversal
order. Explicit primary spans select the module path of the closing edge, never
its alias/member/pub tokens. Implicit edges use the module-start/header anchor
with ImplicitPrelude provenance; the span is not a fictional import in source.
Cycle order follows a DFS from entry with imports in source order. Equivalent
implementations may rotate a cycle for presentation, but the closing edge and
all participating edges must still agree with the diagnostic contract. modules
on successful cases is a set, not a required allocation/discovery order.

| Case | Required graph behavior |
| --- | --- |
| SelfImport | Reject direct self-import |
| MutualImport | Reject A → B → A |
| LongCycle | Reject A → B → C → A and retain all edge origins |
| AliasCycle | Aliases do not create new module identities or hide a cycle |
| UnusedSelectionCycle | Unused imported members do not remove dependency edges |
| ReexportCycle | pub re-exports remain real dependency edges |
| ImplicitPreludeCycle | Reject Prelude → Helper → implicit Prelude |
| PreludeSelfCycle | Prelude without NO_IMPLICIT_PRELUDE imports itself; no automatic exemption |
| MissingImplicitPrelude | Missing implicit Prelude fails at its generated-edge anchor |
| MissingUnusedModule | An unused explicit import must still exist |
| NoPreludeNoLibrary | NO_IMPLICIT_PRELUDE removes the edge; no Prelude file is needed |
| PreludeBootstrap | Prelude and Base explicitly opt out, giving an acyclic bootstrap |
| Diamond | Shared dependency is loaded/initialized once; a revisited completed module is not a cycle |
| ValueRecursion | Local mutually recursive functions do not form a module import cycle |

Do not conflate deferred name ambiguity with deferred module loading: dependency
validation happens even when all opened names are unused. Do not turn module
alias reuse into a test expectation; A19 remains open. The diamond initialization
order is fully explicit and does not settle implicit-edge ordering. ValueRecursion
only asserts graph success; inference/initialization safety belong to later tests.

These projects are not yet executed by a resolver runner. The current parser
suite does not recursively discover this directory; future M2g must parse every
source before validating the graph expectations. No fixture execution is claimed.
