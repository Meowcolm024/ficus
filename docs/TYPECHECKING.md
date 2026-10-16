# Staged type inference, elaboration, and Core proposal

This is a non-normative engineering proposal refining M3–M5 in [PLAN.md](PLAN.md)
and Sections 2–3 of [IMPL.md](IMPL.md). [SPEC.md](SPEC.md), especially Sections
7, 10–16, and 19, remains authoritative. Expression-hole diagnostic behavior is
specified in SPEC §7.4; this proposal implements it without allowing incomplete
programs to execute. All steps below are future work: the current compile driver ends
at validated Abstract syntax, and the repository has no inference or Core modules.

## 1. Reference and implementation shape

Use Mark P. Jones's [Typing Haskell in Haskell, November 2000](https://web.cecs.pdx.edu/~mpj/thih/TypingHaskellInHaskell.html)
as an algorithmic guide. Its useful sequence is kinds/types, substitutions,
unification and matching, qualified types, schemes, inference state, then
expression and binding-group inference. Its `tiExpl`, `tiImpls`, and
`tiBindGroup` distinguish checked signatures from inferred recursive groups;
its entailment separates superclass and implementation reasoning. THIH explicitly
leaves frontend diagnostics and backend overloading translation outside its scope.

Adapt that structure to Ficus with canonical IDs, source-labeled constraints,
rigid signature variables, weak-variable tracking, deferred fields, and evidence
production. Do not copy Haskell numeric overloading/defaulting, lazy execution,
or its binding restriction algorithm. Ficus literals have fixed types; only
unconstrained kinds default, with warnings. Signed recursion and incomplete
signatures need separate paths. Dictionary elaboration and strict initialization
are additional compiler responsibilities, not supplied by THIH.

Start with immutable substitutions and explicit state using existing `containers`
and `mtl` dependencies. Measure before adopting mutable unification cells. Keep
unification, one-way implementation matching, and signature checking separate:
matching must not specialize a wanted's metavariables merely to select an impl.

The public pipeline stays Concrete → Abstract → Core → Runtime. Share a
parameterized Core expression structure between inference and finalized output,
using different type representations. Do not duplicate its constructors in a
separate checked expression datatype. Within Abstract-to-Core elaboration, retain
private work structures only for unresolved patterns, clause groups, field plans,
and evidence obligations. Those structures may refer to Abstract; Core's shared
syntax definition and Runtime may not. They are working data, not another public
language stage or serialized artifact.

## 2. Contracts and module ownership

Proposed modules, introduced only when their milestone needs them:

| Module family | Responsibility |
| --- | --- |
| `Ficus.Type.{Kind,Type,Scheme,Substitution,Unify}` | Semantic kinds/types, variables, capture-free substitution, occurs check, one-way matching |
| `Ficus.Infer.{Monad,Constraint,Work}` | Fresh IDs, solver state, constraint origins, pending pattern/field/evidence plans with shared typed expressions |
| `Ficus.Infer.{Declaration,Expression,Pattern,Binding}` | Declaration/kind preparation, expression/pattern inference, recursive/sequential binding boundaries |
| `Ficus.Infer.{Restriction,Field,Coverage,Trait,Evidence,Initialization}` | Generalization policy, nominal selection, typed coverage, visible implementations, proof terms, strict dependency checks |
| `Ficus.Elaborate` | Resolves pending plans and evidence into shared Core forms; finalizes inference types into Core types |
| `Ficus.Syntax.Core`, `Ficus.Syntax.Core.Validate` | Typed Core with diagnostic holes, structural validation and acceptance checks |
| `Ficus.Error.Type` | Explicit T-code mapping into the existing diagnostic envelope |

Use a minimal shared semantic type vocabulary that imports stage-neutral IDs and
source metadata only. Solver metavariables live in inference-owned types; closed
types and schemes used by accepted Core/interfaces contain none. Diagnostic Core
may retain Core-owned placeholders for unresolved goal types, with a zonked goal
snapshot; its syntax definition never imports inference types or mutable solver
state. Inference instantiates the shared expression type with its own `InferType`
from an inference-owned module. Distinguish type metas,
kind metas, rigid skolems, and bound scheme variables with separate ID types.
Do not reuse source `TypeVarId` as a unification variable. A meta entry records
its kind, creation scope, origin, and reasons it cannot be generalized.

A scheme records ordered explicit binders separately from implicit binders,
predicates, and its monotype. Preserve written order for `@` application; internal
implicit order and evidence order must be deterministic too. Ordinary value
parameters are monomorphic. A generic substitution never rewrites scheme-bound
variables or rigid skolems.

Each wanted equality, trait predicate, field obligation, coverage obligation,
and hole report carries its originating span/provenance and contextual expected
type location. Evidence slots additionally identify the exact use being solved.
Zonking means following the final substitution throughout a type or expression tree;
do this before diagnostics, generalization, and final boundary validation.

The inference entry point takes validated Abstract plus a separate
`CheckedSignatureSummary` for each checked dependency: closed value schemes,
kinds, nominal constructors/fields, trait descriptors, implementation signatures,
and builtin contracts. Preserve the resolver's visibility closure; do not load
implementations from unrelated build modules. Check dependencies before importers.
Export only closed schemes and descriptors, including metadata needed by
re-exported signatures even when its defining names are not opened locally.

Successful output is validated Core, a checked interface, occurrence/type
information for tooling, and warnings. Any error prevents publishing that module's
Core/interface. Recovery may continue independent declarations using private
diagnostic-linked poison, but no poisoned tree crosses a successful boundary.

## 3. Smaller implementation milestones

These steps refine rather than replace the M3–M5 release scopes. T0–T6 provide
the M3 path; T7–T8 finish M4; T9–T12 finish M5. Implement concrete kinds for the
initial slice, while keeping the full kind solver/interface extensible. Every
step includes focused tests and its relevant boundary validator.

| Step | Deliverable | Dependencies and acceptance evidence |
| --- | --- | --- |
| T0 (M3a) | Semantic types, origins, T diagnostics, checked dependency contract, Core skeleton | Existing Abstract validator. IDs cannot alias across modules/scopes; Core imports no earlier-stage syntax; diagnostic kind/code/primary span tests |
| T1 (M3b) | Substitution, kind-aware unification, instantiation, zonking | T0. Occurs check, composition law, fresh instantiations, rigid-variable rejection, free-variable and capture tests; no traits/defaulting yet |
| T2 (M3c) | Declaration preparation and expression/pattern HM slice | T1. Fixed primitive literals, unary application/lambda, ordinary annotations, products/lists, first-order ADTs, distinct conditionals; branches/guards checked consistently; typed hole goals permit continued elaboration, remain representable in Core, and receive contextual errors |
| T3 (M3d) | Sequential bindings, syntactic restriction, weak-variable lifecycle | T2. Local expansive results share metas across uses, non-expansive identity generalizes, signatures cannot bypass restriction, unused unresolved weak metas fail at module completion |
| T4 (M3e) | Mutually visible groups, signed/unsigned recursion, initialization scheduling | T3. Complete signed recursive schemes instantiate independently, unsigned recursion shares monotypes, holes do not invent polymorphic recursion; unsafe cycles and expansive top-level/where initialization fail |
| T5 (M3f) | Typed coverage and pattern/clause lowering | T4. Required do-bind totality, ordinary match warnings/failure, clause order, guards, lambda-parameter match timing, written-parameter where timing |
| T6 (M3g) | Trait-free Core elaboration/validation and minimal execution slice | T5. Validated Core → Runtime and direct/compiled differential evaluation of lists and mutual functions; argument/aggregate/where effect-order fixtures. Enforce builtin contracts used by the slice |
| T7 (M4a) | Full declaration kinds, aliases/regular ADTs, type/kind holes and explicit @ | T6. Higher-kinded structural constructors, alias cycles/saturation, mutual regularity, kind default warnings, binder alignment and erasure, expression holes rejected |
| T8 (M4b) | Nominal records and deferred fields | T7. Delayed receiver inference, weak variables through inner groups, unresolved receiver at module end, one receiver evaluation and source-ordered updates |
| T9 (M5a) | Validated trait/implementation environment | T8. H98 heads, superclass SCCs, trait-parameter occurrence, ownership after alias expansion, visible-set overlap/cycles, all members supplied; no fallback/default methods |
| T10 (M5b) | Qualified inference, evidence-producing entailment, monomorphism restriction | T9. Signed/unsigned/lambda constrained bindings, ambiguous predicates, superclass selection, method-level predicates, no numeric defaulting; evidence slots solved or abstracted |
| T11 (M5c) | Dictionary layout/construction, evidence-aware initialization and Core validation | T10. Shared impl evidence, polymorphic method fields, constrained recursion, generated initialization cycles; strict dictionary construction preserves source work |
| T12 (M5d) | Complete module handoff and conformance | T11. Closed interfaces consumed across imports/re-exports; final field/weak/hole/evidence checks; relevant Prelude examples and differential execution pass |

For each step, first add positive and negative fixtures for its spec rules; a bug
fix starts with a failing fixture. Extend `test/Ficus/Infer/*` and
`test/Ficus/Core/*` as needed. Existing semantic fixture files currently checked
only for parser/resolver behavior must gain typed assertions, not just a new
runner that repeats parser acceptance. Reference-only future syntax stays outside
the v0 suite. Existing goldens require individual diff review.

## 4. Inference and generalization schedule

### Declaration preparation

Collect nominal identities, type parameters, constructor signatures, record
descriptors, and ordinary value signatures before checking bodies. Expand
transparent aliases for comparison/ownership while retaining their source names
for diagnostics. Reject alias cycles, unsaturated aliases, and non-regular
recursive ADTs, including mutual occurrences. Solve declaration kinds and apply
the specified `Type` default/warning only after the declaration constraints have
been collected. Do not default value-type metas.

Distinguish complete signatures from skeletons with holes. Complete signatures
give recursive uses a closed scheme. For skeletons, allocate shared holes and
check declared information without treating any missing part as an assumed
polymorphic recursive scheme. Recursive uses share unknown parts; any known
quantified structure must be handled without quantifying those shared holes or
allowing an instantiation's rigid variables to escape. Pin down that representation
with mixed known/unknown recursion fixtures in T4 rather than treating a skeleton
as complete or rejecting all recursion with holes. Expression/pattern annotations
unify with the annotated whole type and do not create implicit lexical type binders.

### Each binding boundary

1. Establish visibility: process sequential statements one at a time; for
   mutually visible declarations, preallocate names/signatures, calculate value
   SCCs, and process dependencies before their consumers with source-order ties.
   Keep a stable scheduler rather than relying on incidental graph-library order.
2. Within a recursive SCC, put complete signed schemes and shared unsigned or
   incomplete-signature placeholders in scope. Infer bodies with one solver state;
   each polymorphic use gets fresh instantiation. Check a signed body against
   rigidly skolemized declared quantifiers and its given predicates, rejecting
   escapes into outer environments. A declared specialization is valid; a body
   requiring extra predicates or a more specialized type is not. Check signature
   quantification against restriction eligibility separately: successful skolem
   checking alone cannot authorize a polymorphic expansive initializer.
3. Solve ordinary equalities and any field obligations whose receiver is known;
   reduce trait obligations using givens and the validated visible environment.
   Retry obligations when substitutions change. Do not choose a nominal record
   from its field labels or choose a type to make an implementation match.
4. Zonk body types, predicates, and the outer environment. Compute candidate
   variables from the result and residual predicates minus free variables of the
   zonked outer environment. Exclude reachable weak metas, pending-field metas,
   and escaping rigid variables. For an unsigned recursive group, discharge
   obligations and generalize at the SCC boundary, never after its first member.
5. Apply the value and monomorphism decisions below, check ambiguity for each
   proposed scheme, and partition evidence into solved expressions, generalized
   dictionary parameters, or deferred obligations tied to shared monotypes.
   A predicate involving only outer variables remains an outer obligation rather
   than becoming an accidental local quantifier. Track shared SCC predicates
   explicitly so one member cannot silently acquire an ambiguous scheme.
6. Retain eligible quantifiers and stable explicit-binder order; leave every
   excluded meta shared with later uses. Record why a variable stayed weak.
   Export schemes into subsequent inference environments without copying weak
   metas. Generalization and restriction classification happen before dictionary
   lambdas or match compilation can change the apparent term shape.

An explicit unsigned `@a` binder is checked abstractly and becomes a scheme
binder only at an eligible rank-1 binding boundary. Static abstractions are not
value lambdas and cannot provide runtime protection or generalization eligibility.

### Separate decisions, shared classifier

| Check | Where and when | Result |
| --- | --- | --- |
| Non-expansive initialization | Every v0 top-level and impl member; all immediate attached where work | Expansive initializer is rejected, including complete signed/acyclic definitions |
| Recursive initialization protection | Each cyclic value SCC, then again after evidence insertion | Every initializer non-expansive and every intra-cycle reference beneath a value lambda |
| Value restriction | Every sequential binding or mutually recursive binding boundary | Only non-expansive initializers may generalize; signatures cannot override |
| Monomorphism restriction | Residual constrained binding with no written parameters/outer value lambda | Keep one monotype unless a complete signature overrides this check; holes do not override |
| Weak-variable completion | Whole module, including unused/nested bindings | Later uses may solve shared variables; any unresolved weak variable is an error |

Use one exhaustive classifier over checked source structure, returning a reason
and origin rather than only a Boolean. Non-expansive: references, literals,
constructors, value lambdas, and constructors/aggregates with non-expansive
components. Annotations and static type abstraction/application are transparent.
Recognize direct constructor applications by canonical identity; ordinary calls
through a constructor-valued variable still use the function-application rule.
General calls (including partial applications), primitives, projections, updates,
matches, conditionals, blocks, and do work are expansive, regardless of purity.

For named definitions, classify the actual initialization schedule: written value
parameters protect the attached where group and body. With zero written value
parameters, inspect immediately initialized where declarations as well as the
RHS, even if that RHS is a lambda. Keep source outer-lambda/parameter facts
separate from resolver-generated pattern matches. An evidence lambda must not
turn a source expansive initializer into an eligible value or protect a source
cycle that was already unsafe. Do not add relaxed/covariant generalization.

Weakness propagates through substitution and sharing: a non-expansive alias of
a weak value cannot generalize its variables. Track weak roots for the entire
module even if their lexical scope ends, so unused allocations are still checked.
Variables reachable from a pending field constraint remain monomorphic across
inner boundaries. Solving the field later may fix them; it does not retroactively
generalize a previously checked binding.

### Expression-hole goals and continuing elaboration

Treat each expression `_` as an outstanding term goal, not an exception thrown by
the expression checker. In checking mode, record the expected type; in inference
mode, allocate a fresh result-type meta and let surrounding uses constrain it.
Return a typed `Hole HoleId` in `Expr InferType` to the parent so applications,
branch checking, annotations, subsequent statements, and independent declarations
can continue.
Unification may solve the goal's type, but must never mark the missing term solved.
This is distinct from a type hole, whose missing type can be inferred successfully.

Keep a goal store keyed by the original `HoleId`, with occurrence span/provenance,
expected/inferred type, enclosing declaration, lexical binder identities and their
schemes/monotypes, scoped type variables, available dictionary givens, and related
unsolved constraints/evidence obligations. Store references to shared solver types
and zonk them when presenting the goal; do not freeze an early approximation.
Capture scope at the occurrence: later bindings and shadowed names are not local
candidates. Relevant context includes in-scope local values and type variables;
filter unrelated globals rather than dumping every import.

Continue type and evidence elaboration as far as the available information permits.
Defer field, trait, or coverage obligations whose needed information is missing,
and attach them to the relevant goal instead of immediately issuing repetitive
failures. A hole is not permission to skip an independently known mismatch,
invalid declaration, or unsafe initialization elsewhere. Retain diagnostic causes
so recovery can distinguish consequences of an incomplete goal from independent
errors; a hole itself is not error poison. Restriction/safety results that depend
on the missing term remain provisional and cannot certify a successful program.

At module completion, solve the available constraints to quiescence and emit one
T0101 per source occurrence, with its zonked goal type, relevant local context and
blocking constraints with origins. Emit goals even when other errors occurred;
label unavailable information rather than inventing a type after failed recovery.
For example, checking `f : Int -> Int; f x = _` reports goal `Int` with `x : Int`;
an independent bad declaration still receives its own diagnostic. Two `_`
occurrences are separate goals even if their types unify. Successful elaboration
of the surrounding expression does not suppress either diagnostic.

Return these structured goals with partial elaboration/type information and
diagnostic Core when available, separately from the successful Core/interface result.
Do not add runtime stubs, turn goals into `Fail`, or defer errors into execution.
Named holes, automatic term synthesis, interactive refinement commands, and
dependent types are outside this proposal; the existing `_` syntax suffices for
contextual goal reporting.

The result contract uses the shared parameterized AST from Section 6 (schematic):

```text
InferExpr = Expr InferType -- alias defined in inference, not in Core's module
HoleGoal = { id, span, provenance, enclosingDeclaration,
             goalType : InferType, lexicalContext, givens,
             blockers : [ConstraintId] }
PartialElaboration = { declarationWork, inProgressCore : Maybe (CoreModule InferType),
                       diagnosticCore : Maybe (CoreModule CoreType),
                       goals : Map HoleId HoleGoal,
                       pendingConstraints, diagnostics, occurrenceTypes }
ElaborationResult = Complete { core : ValidatedCore, interface, tooling, warnings }
                  | Incomplete PartialElaboration
```

Shared `CoreNode` wrappers and all nested context entries retain spans/provenance.
`InferType` may contain scoped solver metas, unlike accepted Core's closed semantic
types. An incomplete result also retains enough solver information, or a zonked snapshot, to interpret
its types and blockers; raw meta IDs without that context are not a tooling API.
Recovery placeholders for actual failures stay in private work structures and
remain distinct from Core `Hole` nodes.
Multiple uses of the same checked node refer to one goal, not duplicate reports.
`Incomplete` also covers errors without expression holes; diagnostic Core may be
available even though compilation failed. Lowering must reject its holes even if
a consumer ignores its diagnostic list. Successful dependencies can
still be checked and cached independently of an incomplete importer.

### Module completion

Run equality/field/trait solving to quiescence. Report unresolved field receivers,
weak variables, ambiguous/unsatisfied predicates, and every expression hole with
its zonked type. Type holes may be completed and generalized only under the same
binding policy; kind holes follow kind defaulting. Reject escaping skolems.
Expression holes may survive in diagnostic Core, with Core-owned goal metadata;
unresolved solver information stays in the accompanying partial result or a
Core-owned diagnostic snapshot. No unresolved wanted, hole, weak meta, or recovery
poison survives into accepted Core or a published interface. Publish interfaces
only after evidence-aware initialization and acceptance validation succeed.
Diagnostic recovery must not produce a successful compilation artifact.

## 5. Evidence and strict initialization

Use an inference-private evidence tree with given dictionary variables,
superclass selections, and application of a particular implementation builder
to its type/context arguments. Predicate solving returns this proof, not merely
success. Preserve origin information at every generated evidence operation.
Entailment simplifies givens through the acyclic superclass graph; implementation
selection uses fresh head variables and one-way matching, detects multiple
matches/cycles, and never depends on import order.

Each trait descriptor assigns stable slots to superclass dictionaries and
declared methods. A method field retains its own scheme: specialize the owning
trait parameter, then instantiate method-level variables and supply method-level
dictionaries at the use. Such variables are not extra trait parameters. Derived
ordinary functions are absent from dictionary layouts. For example, a dictionary
for `Traversable t` contains a polymorphic `traverse` field rather than one fixed
choice of `f`; selection instantiates that field before passing `Applicative f`.

Generate one reusable dictionary value for a context-free implementation and a
builder over context evidence for a contextual implementation. Track dependencies
among builders, constructed dictionaries, member initializers, and ordinary
values. Validate supplied superclass evidence and all member schemes.

Keep the source inference graph and initialization graph distinct. The existing
`Abstract.Dependencies` graph has structural value/type edges; it proves neither
lambda protection nor dictionary safety. Extend initialization analysis with
edge origins and whether an edge is delayed under a value lambda. Before Core
emission, insert evidence dependencies, recompute SCCs and the stable schedule,
and reject newly unsafe cycles. Type abstractions do not delay reads. Dictionary
fields are initialized strictly and in a deterministic layout order; preserve
the source dependency/source-order schedule for member initializers using lets
before packing fields.

Evidence abstraction is allowed only after source generalization eligibility is
settled. Keep immediate where initialization outside generated evidence lambdas
if moving it would delay or duplicate work; store shared results explicitly.
Do not hoist dictionary construction, method initialization, or evidence builder
calls across a source value application without a checked justification. The
post-evidence safety checker understands generated evidence operations and their
proofs; blindly reapplying the source ban on all applications would reject
legitimate contextual dictionary construction.

## 6. Proposed Core calculus and AST

Use a typed, explicitly instantiated rank-1 let calculus with nominal data,
strict unary functions, and dictionary records. A schematic type vocabulary is:

```text
kind    k ::= Type | k -> k
type    t ::= bound-type-variable | type-constructor-id | t t
scheme  s ::= forall ordered-binders. t
```

Arrows, products and lists use canonical constructor IDs in the type vocabulary.
Source qualified schemes elaborate to schemes whose monotype has dictionary
arrows before its value arrows. Preserve the source qualified scheme separately
for interfaces/tooling. Predicates are resolved before executable Core; dictionary
types are nominal types parameterized by the corresponding trait argument.

Proposed constructors (schematic, not a file ready to compile):

```text
CoreModule ty = nominal descriptors ty + dictionary layouts ty + scheduled bindings ty
           + Core-owned goal snapshots
ValidatedCore = CoreModule CoreType accepted by structural and completeness validation
CoreType   = bound variable | constructor ID | type application
           | DiagnosticTypeMeta CoreTypeMetaId -- incomplete diagnostic Core only
CoreNode a = { nodeId, span, provenance, value : a }
Expr ty    = CoreNode { type : ty, form : ExprF (Expr ty) (Binder ty) ty }
Binder ty  = CoreNode { id : LocalId, type : ty, role : Value | Evidence }
Binding expr ty = CoreNode { reference, scheme : Scheme ty,
                            rhs : PolyRhs expr, sourceBindingFacts }
PolyRhs expr = CoreNode { typeBinders, body : expr }

ExprF expr binder ty = Var Reference [ty]
      | Literal Literal
      | Hole HoleId
      | Lambda binder expr
      | Apply expr expr
      | Let (Binding expr ty) expr
      | LetRec (NonEmpty (Binding expr ty)) expr
      | Construct ConstructorId [ty] [expr]
      | Case expr [Alternative expr binder] (Failure ty)
      | If [ConditionalArm expr] (Maybe expr) (Failure ty)
      | Dictionary DictionaryId [ty] [PolyRhs expr]
      | SelectRecord expr FieldId
      | SelectMethod expr MethodSlot [ty]
      | SelectSuperclass expr SuperclassSlot
      | Primitive PrimitiveId [ty] [expr]
      | Fail (Failure ty)

Alternative expr binder = CoreNode (ConstructorId [binder] expr
                                 | Literal expr
                                 | Default expr)
ConditionalArm expr = CoreNode (expr, expr)
Failure ty = CoreNode { kind : MatchFailure, resultType : ty }
```

The parameters are ordinary Haskell type parameters, not a phase-indexed GADT or
a family of phase-dependent constructors. `ExprF` shares expression shape;
`expr` supplies recursion, `binder` supplies typed binders, and `ty` supplies
explicit type arguments and binding/failure types. Propagate `ty` consistently
through schemes, declarations, descriptors, and goal snapshots. Inference uses
`Expr InferType`; final output uses `Expr CoreType`. The shared syntax module
imports neither `InferType` nor Abstract syntax: inference owns its specialization
and the traversal that finalizes types, binders, schemes, and nested expressions.
That traversal zonks solved metas and converts any remaining diagnostic types to
Core-owned placeholders; it preserves node IDs, source origins, and `HoleId`s.

There is no separate checked expression constructor family. Keep unresolved
pattern matrices, source clause groups, nominal field-selection plans, and
evidence slots in private work records referring to shared expressions. If an
operation cannot yet become a valid Core form, retain that pending operation
there rather than inventing an unbound Core variable or a new Core sugar node.
Only form-ready portions become Core expressions. This avoids duplicating the
expression AST while retaining the information needed for typed lowering.

Shared ID names are illustrative. `Var` contains explicit instantiation arguments
for all quantified binders, including inferred ones. Core validation checks their
count/kinds; only source-written explicit binders are addressable by `@` in the
surface language. `PolyRhs` represents erased outer type abstraction, not a
runtime thunk. Bindings may quantify; ordinary expression arguments and lambda
binders may not. A monomorphic binding has no type binders. Recursive `Var` uses
instantiate signed schemes but carry no fresh polymorphism for unsigned members
until their checked generalization boundary.

`Hole HoleId` is a first-class Core expression for continued elaboration and
diagnostics. Its enclosing Core node carries the inferred/expected type and the
source occurrence's span/provenance. Core-owned goal metadata links its ID to a
zonked context/blocker snapshot; the shared Core syntax module never imports
Abstract or inference-owned types. If the goal type remains unknown, diagnostic Core uses an explicit
Core-owned type placeholder rather than inventing a concrete type. These
placeholders are forbidden in accepted Core/interfaces.

Core construction and compilation acceptance are separate: an incomplete module
may have diagnostic Core containing holes, but elaboration must emit T0101 for
every source hole and cannot return `Complete`. Structural validation recognizes
well-formed hole nodes; completeness validation rejects them. Runtime lowering
normally consumes `ValidatedCore`, but independently checks its input for holes
and returns an error if one is present. Do not rely solely on an earlier validator
or diagnostic list. Editors may inspect diagnostic Core via `PartialElaboration`.

Dictionary method fields are the controlled exception requiring stored schemes:
their `PolyRhs` values can quantify method-local variables. `SelectMethod`
instantiates these fields directly and yields a monotype. This is internal
dictionary representation, not source higher-rank function arguments. Constructor
and primitive references used as partial function values elaborate through unary
lambdas/applications or typed reference descriptors; `Construct` and `Primitive`
nodes themselves are saturated. Dictionary fields must match their layout and
schemes exactly. Record selection is monomorphic; superclass selection returns
the instantiated superclass dictionary type.

Every listed node, descriptor, binder, alternative, field initializer, and failure
site has its own Core metadata; do not reuse Abstract's `Node`. Finalized Core expressions
carry monotypes; scheme bodies may reference their enclosing bound type variables,
but never inference-owned solver metas. In-progress `Expr InferType` values may
contain solver metas in their type parameter; those are finalized before external
Core output or validation for acceptance. Diagnostic type placeholders are the
explicit incomplete-output exception described above. Generated IDs are fresh;
generated nodes keep the actual source binding, clause, field, or predicate origin.

### Operational contract and lowering

- `Apply` evaluates the function and then its argument; `Lambda` forms a closure.
  Functions/applications remain unary, including evidence arguments.
- `Let` evaluates its RHS once before its body, even when the binder is unused.
  Erasing outer type binders exposes that strict RHS evaluation without a delay.
- `LetRec` preallocates slots and evaluates initializers in source order, accepting
  only checked safe SCCs. Acyclic dependencies become ordered strict lets/bindings.
- `Construct`, dictionary packing and primitives evaluate value operands
  left-to-right. Polymorphic field abstraction erases before evaluating its field
  body. Saturation and fixed layout make operand ordering explicit.
- `Case` evaluates its scrutinee once and uses shallow constructor/literal tests.
  Compile nested patterns to nested cases with an explicit failure continuation;
  false guards continue with the next source clause. Retain non-exhaustive runtime
  failure and warning behavior rather than treating all matching as total.
- `If` evaluates conditions in order and only the chosen body. Its optional
  fallback represents the final `_`; no successful arm/fallback raises its own
  match failure. Source conditionals always produce `If`, never `Case`.
- Place where groups at their written value-parameter boundary. In particular,
  `f x = y -> body where ...` becomes `Lambda x (lets (Lambda y body))`.
  Lambda parameter-pattern cases stay at their existing per-parameter positions;
  named clause lowering preserves the specified clause selection schedule.
- Evaluate record fields into source-ordered temporaries, then pack in layout
  order. For updates bind the receiver once, then replacements in source order,
  then rebuild with unchanged field references. Erase explicit type operations
  without adding runtime applications or moving these initialization points.

`Fail` and failure continuations make partial matches expressible without
inventing a value of arbitrary type. They are typed terminal runtime errors,
carrying the source match origin. Do not use expression-hole nodes for failure.

Before Runtime lowering performs erasure, optimization, or dead-code removal,
scan the entire Core module for `Hole` nodes, including unused bindings, lambda
bodies, dictionary methods, and branches that will not execute. Also handle
`Hole` explicitly in the lowering traversal, returning a structured lowering
error with its ID, span, and available goal type. Never use Haskell `error`, an
unchecked pattern, or a runtime failure stub for this case. Return no Runtime
module on failure. This second check is required even if elaboration already
reported T0101 or the caller supplied supposedly validated Core.

### Independent Core validator

Validate binding/reference closure and dominance; distinct IDs and provenance;
kinds and explicit instantiations; lambda/application/let types; closed schemes
and valid type-variable scopes; constructor/primitive saturation; record/dictionary
identity, slot and field types; case binder types and common result type; Boolean
conditions and final fallback placement. Structural validation permits Core hole
nodes with valid goal IDs, types/context snapshots and origins; completeness
validation rejects holes and diagnostic type placeholders, and requires absence
of unresolved metas, wanteds, poison, raw labels, or source sugar. Dictionary slots
may contain polymorphic methods only as declared by their layout, never arbitrary
polymorphic expressions.

Recheck recursive initialization with source facts and explicit evidence edges.
Store the necessary source classification facts and origins in Core-owned
metadata; do not import earlier AST types or trust a bare `safe = True` flag.
Structural validation alone cannot prove preservation of observable scheduling:
use differential execution and deliberately malformed Core tests alongside it.
Malformed Core reports T0099 as an internal boundary error. A well-formed source
hole remains T0101, not T0099. Defensive lowering rejection retains that source
location and explains that an expression hole prevents Runtime generation.

## 7. Validation and implementation checkpoints

| Risk | Required evidence |
| --- | --- |
| Generalization and mutation | Polymorphic non-expansive identity; expansive local alias sharing; incompatible later uses fail; unresolved unused weak variable fails; signatures cannot rescue it. Add real Ref examples when v1 references exist |
| Constraint restriction | Unsigned `displayMono = show` remains one monotype; later use can fix it; complete signed and lambda-wrapped forms generalize; incomplete signature does not override; ambiguous scheme fails |
| Recursive inference | Signed polymorphic recursion accepted; corresponding unsigned use rejected; mixed SCC checks; signature holes never grant polymorphic recursion through missing information |
| Initialization | Acyclic top-level call rejected; immediate expansive where rejected even with lambda RHS; direct cyclic variable read rejected; written function parameters protect work; type/evidence abstraction cannot rescue unsafe source initialization |
| Fields and kinds | Projection resolved by later receiver use; pending field prevents inner generalization; unknown receiver fails at module end; kind mismatch/default warning; alias cycle/non-regular ADT; higher-kinded @ hole |
| Coverage and provenance | Box variable field accepted for do bind, nested literal rejected; guards continue in clause order; generated match/evidence/field nodes retain actual primary origins |
| Continuing hole elaboration | Context fixes a goal's type from later constraints; expected signature and local binder types shown; separate holes all reported; unrelated type errors retained; shadowed/later names excluded; blockers retain origins; diagnostic Core retains holes; fully known goal still fails; no accepted Core/interface emitted |
| Shared expression finalization | Type conversion visits expression annotations, binders, schemes, explicit type arguments, dictionary method bodies and failure types; preserves expression shape, IDs, spans and hole identities; accepted output contains no inference metas |
| Defensive Runtime lowering | Manually constructed Core holes in unused bindings, lambda bodies, dictionary methods and unselected branches all fail lowering with the original span; no Runtime module/stub is returned even when elaboration/acceptance checks were bypassed |
| Evidence and imports | Method-local polymorphism; superclass paths; orphan/overlap and evidence cycles; import order independence; unrelated module impl ignored; constrained member/ordinary-value initialization cycle rejected |
| Strict lowering | Trace function/argument, field/update and where order; partial curried calls; receiver once; unused let initializer still runs; direct interpreter equals compiled evaluator for values, failures, and effects |

Add substitution/unification properties beyond examples: composition agrees with
successive application, a successful unifier equates its inputs, instantiations
are fresh, and zonking is idempotent. Test Core validation independently with
malformed binding, type, dictionary, and origin cases. Continue running the
existing parse/pretty round-trip and formatter-idempotence properties.

Use the proposed [T registry](ERRORS.md#type-checking-and-elaboration-diagnostics-t-proposed)
for kind/type/coverage/initialization errors, leaving lexical/scope failures in N.
The existing table lacks dedicated entries for some declaration errors (alias
cycles, ADT regularity, superclass cycles) and T0403 still groups implementation
failures. Assign explicit dedicated codes with their implementing step and
fixtures; do not repurpose a published code or hide these under T0099.

For implementation changes, inspect `package.yaml` before extensions/dependencies,
run targeted Stack tests during iteration, format changed Haskell with `ormolu`,
and run `stack build` and the relevant full tests before finishing. This proposal
adds no Haskell API, dependency, or golden expectation. The contextual hole
diagnostic contract is recorded in SPEC §7.4. Numeric
edge behavior and primitive contracts needed by T6 still require the existing
B9/B19 decisions; v1 ETA/STANDALONE, existentials, lazy arrows and representation
erasure remain in their versioned milestones.
