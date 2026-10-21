# Runtime AST and closure-threaded interpreter

The library implementation below is available in `FicusBackend.Runtime` and
`FicusBackend.Lower.Runtime`. This document records its design and scope;
[SPEC.md](SPEC.md) remains normative. The design follows
[IMPL.md sections 4–5](IMPL.md#4-runtime-ast), including strict evaluation,
runtime erasure, lexical addressing, and compositional evaluator compilation.

The interpreter supports the v0 primitive registry, mutable references, typed
exceptions, and the bundled Prelude.
Tests include source-to-execution fixtures, a direct Runtime interpreter, and
generated programs checked against an independent arithmetic/effect oracle.
Evidence is retained conservatively; static types and single-field nominal
wrappers are erased. Backend drivers provide `run` and `repl`; serialization
and constant-stack tail calls remain subsequent work.

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
FicusBackend.Error
```

- `Runtime` exposes validated programs, evaluator compilation, and execution.
- `AST` owns runtime syntax, addresses, numeric IDs, layouts, and explicit error payloads.
- `Validate` constructs an opaque `ValidatedProgram` accepted by the evaluator
  compiler.
- `Value` owns values, environments, closures, and partial applications.
- `Runtime.Error` owns message-only evaluation failures. `FicusBackend.Error`
  owns coded static backend diagnostics.
- `Compile` composes runtime expressions into Haskell evaluator closures.
- `Primitive` implements primitive operations behind the evaluator's effect
  interface.
- `Lower.Runtime` imports Core and Runtime and owns representation selection,
  erasure, closure conversion, and arity raising.

Runtime modules must not import Concrete, Abstract, or Core AST types.
`Ficus.Primitive.Registry` owns the shared operation definition, reserved
intrinsics, builtin keys, type templates, catalogue indices, and operand counts.
Core uses `Primitive GlobalId`, retaining ordinary nominal library identities;
Runtime uses the same `Primitive ()`, with that metadata erased. Lowering uses
the shared catalogue index rather than translating between separate operation
types. The frontend's `Ficus.Builtin.Registry` adapts catalogue entries to source
identities and semantic kinds, and Core converts neutral type templates for its
validator. Execution performs numeric table lookup, never builtin-key lookup.

Keep a direct Runtime AST interpreter under tests initially as a differential
oracle.

## 2. Runtime AST

The following declarations are schematic. The implemented AST uses distinct
`newtype`s for IDs, indices, arities, and frame sizes, metadata-free `Node`
wrappers, and vectors for dense tables. Concrete conventions are recorded in
[IMPL §4.5](IMPL.md#45-implemented-representation-and-boundary).

```haskell
newtype Expr = Expr ExprF

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
  | TypeToken ConstructorIndex [Expr]
  | Case Expr [Alternative] Expr
  | If [(Expr, Expr)] Expr
  | Select Expr FieldIndex
  | Primitive PrimitiveIndex [Expr] Text
  | Raise Text

data Function = Function
  { functionArity :: Arity,
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

`Raise` carries a generic error message, including source context generated
during lowering for failed matches and conditionals. It never stands in for an
erased expression hole. Every `If` has an explicit fallback expression; lowering
synthesizes a `Raise` when Core has no fallback. Only selected results run.

Runtime nodes, alternatives, functions, layouts, and binding groups carry no
spans or provenance. The `Node` newtype has no runtime metadata. Source spans and
provenance remain through Core. Lowering formats location text once for generated
`Raise` messages and fallible primitive operations; total primitives carry an
empty error context. Primitive failure context is applied only after operands
have evaluated successfully, so an operand failure keeps its own message.
`Binding.bindingExpansive` is a semantic Boolean for recursive validation, not a
source location.

A program contains dense function, constructor, and primitive tables, a global
cell count, and an explicit ordered initialization schedule. Source-name maps
remain in `LoweredProgram`, outside the Runtime AST. Frame and capture
conventions are validated before execution.

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

compileExpr :: Program -> Expr -> Eval
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

Implemented:

1. Runtime AST, layouts, diagnostics, validator, and hand-built fixtures.
2. Core lowering with unary calls, explicit captures, and wrapper erasure.
3. Direct test interpreter, closure-threaded evaluator, and differential tests.
4. Safe arity raising with evaluation-order regression tests. Proof-dictionary
   erasure remains optional and is deliberately conservative: all dictionaries
   and evidence applications currently survive lowering.

Record concrete implementation conventions in IMPL.md as they land. Update
SPEC.md in the same change if any decision changes observable language behavior.
CLI execution is implemented by `FicusBackend.Driver.Run` and
`FicusBackend.Driver.Repl`; see SPEC §22 and IMPL §8. Object serialization and
tail-call optimization remain subsequent work.

## 7. Embedding API

`lowerProgram :: [CoreModule CoreType] -> Either [BackendError] LoweredProgram`
accepts closed Core modules in dependency order. It independently scans for
holes and calls Core acceptance validation; callers do not need to manufacture
a validation witness. Every imported value needs a linked definition with a
compatible scheme. The result contains a `ValidatedProgram` and a map from
canonical global identities to runtime addresses.

Select an address using `selectEntry`, then call
`runProgram effects (compileProgram checked) entry arguments`. `Effects`
supplies `writeHandle :: StandardHandle -> Text -> IO ()` and
`readHandle :: StandardHandle -> Int64 -> IO Text`; `ioEffects` maps the three
standard handle identities to host streams. Runtime values include opaque
`HandleValue`s. Standard input is readable; standard output and standard error
are writable. Bounded reads preserve Unicode code points and line terminators;
non-positive counts skip the callback. Direction errors and host IO exceptions
become generic runtime messages with embedded operation context. `print`, `println`, and line reading are
ordinary source definitions built from handle primitives; no close operation is
provided.
`Value` supplies arguments and results, and `observe` inspects data values.
Host closure equality is intentionally unavailable.

For repeated calls, use `initialize` once and pass its `Instance` to
`evaluateEntry`. Each instance owns its global cells and effect interface;
separate instances may share an `Executable`. Use entries selected from the
same validated program as the executable/instance. Entry validation here checks
the numeric address; `FicusBackend.Driver.Run` owns the source `main` signature
and command-line argument contract. Library programs can have no globals or entry.

`RuntimeError` carries only message text. Its diagnostic adapter uses R0001.
Lowering, linking, entry selection, and Runtime validation return separate
`BackendError` diagnostics with specific codes and spans; see [ERRORS.md](ERRORS.md#runtime-and-lowering-diagnostics-r).

## 8. Interactive linking

The backend REPL retains closed schemes, evaluated values/closures, source and
name-scope snapshots, and Runtime layout metadata, without retaining Core.
`lowerProgramWithLayouts` extends an existing constructor/dictionary/exception-identity tag table;
old tags never shift when new nominal types are added. `loweredBindings` maps
module-owned references to current global addresses, including discarded
bindings and generated dictionary builders. `initializeWith` installs retained
values at those addresses and skips their initializers. Captured closures retain
their original environments, while calls use the current invocation's effects.
Only a successful submission commits updated snapshots, values, and layouts.
Reload starts a fresh environment. See SPEC §22.1 for rebinding and constructor
ownership rules.

## Mutable references

`REF_NEW`, `REF_READ`, and `REF_MODIFY` use a dedicated `RefValue (IORef Value)`.
Cells are fully initialized at allocation and are distinct from the optionally
uninitialized cells used for recursive lexical bindings. The updater runs through
the ordinary closure application path with the current invocation's effects;
its result is stored only after successful completion. Runtime observation is
opaque, so it neither reads mutable contents nor follows cycles. Source `Debug`
uses the library instance to read and display contents explicitly.


## 9. Typed exceptions

`ExceptionDictionary` in Core retains nominal identity independently of the
payload representation. Lowering produces Runtime `TypeToken` nodes with numeric
layout tags and component evidence; no Core types or source metadata survive.
Tokens include phantom arguments and persist across REPL linking. Both boundary
validators check token construction, and Core checks exception primitive evidence.

`THROW` takes a token and payload and produces an internal typed exception.
`CATCH` takes a token, action thunk, and handler; it invokes the action with Unit
and handles exactly matching tokens. Its handler runs outside that catch.
Generic runtime errors remain separate and cannot be caught. Effects completed
before a throw remain visible, and `modifyRef` writes its final result only on
normal return. Public execution APIs still return `Either RuntimeError a`;
`runEvaluation` reports uncaught throws with their explicit primitive context.

`test/Ficus/ExceptionSpec.hs` covers source contracts, renaming/imports, erased
wrappers, nested and polymorphic catches, phantom arguments, strict effects,
reference updates, malformed Core, and REPL identity/recovery. Execution fixtures
compare the compiled evaluator with the direct Runtime interpreter.
