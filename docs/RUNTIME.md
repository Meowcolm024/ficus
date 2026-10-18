# Runtime AST and closure-threaded interpreter plan

This is a proposed implementation plan, not an implemented API or a language
specification. [SPEC.md](SPEC.md) remains normative. The design follows
[IMPL.md sections 4–5](IMPL.md#4-runtime-ast), including strict evaluation,
runtime erasure, lexical addressing, and compositional evaluator compilation.

## 1. Module boundaries

Use `FicusBackend.Runtime` as the public facade, with runtime syntax and
execution underneath it:

```text
FicusBackend.Runtime
FicusBackend.Runtime.AST
FicusBackend.Runtime.Validate
FicusBackend.Runtime.Value
FicusBackend.Runtime.Error
FicusBackend.Runtime.Compile
FicusBackend.Runtime.Primitive

FicusBackend.Lower.Runtime
```

- `Runtime` exposes validated programs, evaluator compilation, and execution.
- `AST` owns runtime syntax, addresses, numeric IDs, layouts, and debug metadata.
- `Validate` constructs an opaque `ValidatedProgram` accepted by the evaluator
  compiler.
- `Value` owns values, environments, closures, and partial applications.
- `Error` owns structured runtime errors with source locations.
- `Compile` composes runtime expressions into Haskell evaluator closures.
- `Primitive` implements primitive operations behind the evaluator's effect
  interface.
- `Lower.Runtime` imports Core and Runtime and owns representation selection,
  erasure, closure conversion, and arity raising.

Runtime modules must not import Concrete, Abstract, or Core AST types. Shared
source metadata and stage-neutral identities may be reused. In particular,
builtin key spellings remain in the compiler builtin registry; execution uses
numeric primitive IDs rather than key lookup.

Keep a direct Runtime AST interpreter under tests initially as a differential
oracle.

## 2. Proposed Runtime AST

The following declarations are schematic. Define IDs, indices, arities, and
frame sizes as distinct `newtype`s, and settle their concrete containers during
implementation.

```haskell
data Expr = Expr
  { exprSpan :: Span,
    exprOrigin :: Provenance,
    exprForm :: ExprF
  }

data Address
  = Local FrameDepth SlotIndex
  | Capture CaptureIndex

data ExprF
  = Load Address
  | Global GlobalIndex
  | Literal RuntimeLiteral
  | Closure FunctionIndex [CaptureSource]
  | Call Expr (NonEmpty Expr)
  | Let Expr Expr
  | LetRec (NonEmpty Expr) Expr
  | Construct ConstructorIndex [Expr]
  | Case Expr [Alternative] Expr
  | If (NonEmpty (Expr, Expr)) (Maybe Expr)
  | Select Expr FieldIndex
  | Primitive PrimitiveIndex [Expr]
  | MatchFailure

data Function = Function
  { functionSpan :: Span,
    functionOrigin :: Provenance,
    functionArity :: Arity,
    functionFrameSize :: FrameSize,
    functionCaptures :: CaptureLayout,
    functionBody :: Expr
  }
```

Runtime AST contains no expression holes, static types, schemes, type
applications, or unresolved source references. Runtime literals contain decoded
values rather than source spellings.

`CaptureSource` identifies an existing local, capture, or recursive slot;
capturing does not evaluate an arbitrary expression. Alternatives dispatch on
constructor tags or decoded literals and describe the frame binding the matched
fields. Dictionaries use ordinary aggregate layouts and indexed selection.

`MatchFailure` represents legitimate runtime pattern-match failure. It must never
stand in for an erased expression hole. Retaining `If` directly gives a simple
initial lowering; only the selected result expression runs.

Every AST node, including alternatives, functions, and binding groups, must carry
a span and provenance. The sketch omits some of those wrappers for brevity.
Generated nodes inherit their originating construct's span.

A program contains dense function, global, constructor, primitive, and debug
tables, plus an explicit ordered global-initialization schedule. Define frame
and capture conventions explicitly so validation and execution agree. Debug
tables retain names and declaration identities for diagnostics, without making
execution depend on them.

Keep entry selection separate from the program representation so libraries do
not require `main`. An execution entry is resolved and validated before running
and passed as an address; the evaluator never searches for a name.

## 3. Core-to-Runtime lowering

Implement the boundary in the following order:

1. Scan the entire input Core module for holes before erasure or optimization.
   Include unused bindings, delayed lambdas, dictionary methods, and unselected
   branches. Return structured errors at the holes' original spans, and produce
   no Runtime program. Expression lowering must also reject the hole constructor
   explicitly, independently of the initial scan.
2. Choose runtime representations. Erase wrappers for nominal ADTs with exactly
   one constructor and one field, including single-field records. Construction,
   matching, and projection must preserve strict evaluation while using the
   underlying field representation. Assign layouts and tags to other aggregates.
3. Erase static types, schemes, type applications, and type abstractions.
   Preserve dictionaries with operational fields. Erase proof evidence only
   when its removal is justified; retain uncertain evidence initially. Preserve
   evaluation and initialization when eliminating evidence lambdas or calls.
4. Calculate free variables, allocate compact capture slots, and replace resolved
   references with lexical addresses and numeric global IDs. Preserve the
   existing initialization schedule rather than deriving it from map order.
5. Raise arity conservatively across lambda chains that perform no intermediate
   observable work. Preserve dictionary-parameter ordering and attached `where`
   initialization boundaries.
6. Validate the result and expose it through `ValidatedProgram`.

For source `f a b`, preserve:

```text
evaluate f → evaluate a → apply f a → evaluate b → apply the result to b
```

Do not implement a general multi-argument call by evaluating every argument
before the first application. Flatten only proven-safe application spines. Extra
application must enter a saturated function before evaluating arguments for the
returned function, preserving errors and effects as well as final values.

In particular, these definitions have different initialization boundaries:

```text
f x y = body where ...       -- initialize where after x and y
f x = y -> body where ...    -- initialize where after x
```

Use the Core structure and retained binding facts; do not reconstruct written
parameter counts from the number of resulting lambdas.

## 4. Closure-threaded execution

Use an explicit runtime effect and error boundary:

```haskell
type Eval = Env -> EvalM Value

compileExpr :: Expr -> Eval
compileProgram :: ValidatedProgram -> Executable
```

`compileExpr` traverses each expression once and composes precompiled child
evaluators. Each function body is compiled before execution. Running the program
invokes those Haskell closures rather than repeatedly inspecting Runtime AST
constructors. Primitive effects remain behind a small runtime interface.

A runtime closure contains precompiled code, a compact capture environment,
arity, and already supplied arguments. A saturated call allocates an argument
frame and invokes the stored evaluator. Partial application retains supplied
values. Evaluate operands, fields, and applicable argument groups strictly from
left to right.

Recursive groups require shared recursive storage. Closures must refer to that
storage rather than copying uninitialized values. Initialize group members in
source order and prohibit premature reads through validation. Support accepted
non-expansive aggregates containing recursive closures, not just groups whose
initializers are bare functions. Select the concrete storage mechanism when
implementing the evaluator; do not rely accidentally on Haskell laziness,
especially under the project's `StrictData` policy.

Tail position is structurally apparent, but this initial interpreter does not
promise constant-stack tail calls. Bytecode, ANF, or a trampoline can be evaluated
later without replacing typed Core.

## 5. Validation and tests

The Runtime validator checks:

- numeric IDs, lexical addresses, frame bounds, and capture layouts;
- function arities, constructor field counts, and primitive operand counts;
- case-table consistency and alternative field-binding layouts;
- global initialization dependencies;
- non-expansive cyclic initializers and lambda protection of recursive reads.

Static operand-type compatibility remains a Core validation responsibility.
Runtime validation checks the invariants expressible after type erasure. The
lowering API must state its Core validation precondition while retaining its
independent hole rejection.

Add focused fixtures for closure capture, shadowing, nested frames, partial and
extra application, both `where` timing cases, recursive closures and aggregates,
dictionary method and superclass selection, and wrapper erasure. Negative
fixtures assert diagnostic kinds and primary spans. Include holes hidden in
otherwise unreachable code and malformed runtime programs rejected by the
validator.

Use deterministic primitive traces to test effect order, including a failure
that must prevent evaluation of a later argument. Compare the direct interpreter
and compiled evaluator on values, structured errors, and effect traces. Compare
function results by applying them to test arguments rather than attempting host
closure equality. Where practical, test lowering against a Core-level reference
evaluator too: two Runtime evaluators alone cannot detect a shared lowering bug.

## 6. Delivery sequence

1. Runtime AST, layouts, diagnostics, validator, and hand-built fixtures.
2. Conservative Core lowering with unary calls and explicit captures.
3. Direct test interpreter, closure-threaded evaluator, and differential tests.
4. Safe arity raising and justified evidence erasure, with evaluation-order
   regression tests.

Record concrete implementation conventions in IMPL.md as they land. Update
SPEC.md in the same change if any decision changes observable language behavior.
CLI integration, object serialization, and tail-call optimization are subsequent
work; this plan does not settle their open contracts.
