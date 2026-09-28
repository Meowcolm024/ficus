# Ficus Implementation Notes

This document records non-normative implementation choices. Language behavior is defined by `SPEC.md`.

## 1. Pipeline

Ficus uses four AST stages:

```text
source
→ lexing and parsing with parser-driven layout
→ Concrete AST
→ desugaring and name resolution
→ Abstract AST
→ type inference and elaboration
→ Core AST
→ erasure and runtime lowering
→ Runtime AST
→ evaluator compilation or code generation
```

`Runtime AST` is untyped in the sense that static types and schemes are erased, but it remains a validated runtime IR rather than an unchecked source language.

This split is intentional:

- Concrete AST faithfully preserves parsed source structure, comments, pragmas, and explicit versus indentation-based blocks for diagnostics and layout-aware pretty printing as a naive formatter.
- Abstract AST has surface sugar removed and every name resolved.
- Core AST is the small, typed, explicit result of inference and elaboration.
- Runtime AST is optimized for simple and efficient interpretation.

The reference implementation is written in Haskell. Each boundary should have a validator, focused tests, and a source map back to Concrete AST locations.

Before name resolution, every module receives the six reserved primitive types. The frontend additionally imports Prelude unless the module has `NO_IMPLICIT_PRELUDE` or `MAGIC`. It rejects `do` and string interpolation when that import is disabled rather than attempting ordinary name resolution for their dependencies.

Keep type and trait declarations in one namespace. A bare or aliased import may bind a local module name, but reject `Int`, `Float`, `Bool`, `Char`, `String`, `Unit`, or `Type` as that binding. A selective import that binds only members of `Data.Int` is valid. Store compiler-known library entities by their defining module and declared name after name resolution; aliases and re-exports must not change the registry key.

The Concrete AST stores a dotted expression as an unresolved base-and-segments chain. For an uppercase-only chain, name resolution treats all but the last component as a module path and the last as a constructor; with a lowercase segment, it treats the whole uppercase prefix as a module path and that first lowercase segment as a value. Later lowercase segments become field projections. Reject direct projection from a constructor. Preserve the unresolved Concrete form until this step, and reject a missing module or export rather than reinterpreting the chain as constructor projection.

### 1.1 Source spans and provenance

Concrete, Abstract, and Core AST nodes retain source spans and provenance. A source span records the file and start/end positions; provenance connects transformed or generated nodes to the source nodes and declarations that produced them. Combining clauses must retain the individual clause spans as well as the binding origin. Generated lambdas, matches, and dictionary evidence must retain their originating locations rather than borrowing arbitrary neighboring spans.

Core metadata should connect inferred types and resolved references to source occurrences and declaration identities. This supports later LSP features such as showing types, jumping to definitions, and semantic highlighting. Runtime lowering retains the relevant source mappings for errors even when static metadata is erased.

### 1.2 Abstract declarations

Desugaring normalizes value and type declarations to `ident = <abstract expression>`, with associated signatures, pragmas, and provenance kept as declaration metadata. Type-level expressions remain distinct from value expressions. Multiple clauses defining one value are grouped in source order into one binding: parameters become lambdas over fresh binders, with a single `with` expression matching their arguments. This grouping precedes duplicate-binding checks; independent duplicate declarations remain errors. Preserve clause ordering, patterns, guards, and evaluation behavior.

### 1.3 Parsing and formatter checks

Use Megaparsec for parsing. The set of operator spellings is open, so operator grouping cannot rely on a static enumeration of operator names. Build grouping dynamically from encountered operators using the specification's spelling-based precedence and associativity rules; this does not introduce fixity declarations. Apply the same rules to expressions, types, and infix constructor patterns, rejecting mixed associativity within a precedence group.

Lex `--` as a line comment only when the following character is not another operator character, so `-->` remains an operator; `{-` always starts a block comment outside literals, so an unterminated `{-x}` is a lexical error. A dot is a separator only without adjacent whitespace in qualification/projection, may occur inside an operator only between non-dot operator characters, and `..` is reserved to import lists. Parse module-qualified constructors in patterns and named record construction, plus parenthesized qualified operator references; reject operator sections.

Drive layout from parser expectations for `block1` and `block`. The parser supplies virtual delimiters when it enters an indented block; a standalone lexing pre-pass must not decide where blocks begin. An expression block opens only at explicit `{` or newline plus deeper indentation after an expression introducer. For prefix `with`, stop the scrutinee at the explicit clause `{` or the newline opening the indented clause block. For postfix record `with`, require the same explicit or indented field-block delimiter. Lookahead for `=` and `<-` is limited to the current layout depth; nested record fields cannot classify an outer `do` or expression-block statement. String interpolation in v0 accepts a bare or module-qualified value name only, so its scanner need not parse nested expressions. Recognize `\{` and `\}` as string escapes before trying an interpolation opener; retain `{{` and `}}` as the other literal-brace forms.

Preserve `_` as an ordinary lowercase identifier in Concrete AST, with its source span. Name resolution assigns wildcard, unconditional `if` fallback, or hole meaning to the exact spelling according to context; `_name` remains an ordinary identifier. Do not hardcode those meanings in the lexer or parser. Parse every `if` condition as `non_lambda_expr`; nested conditions need their own delimited clause blocks.

Keep positive and negative fixtures for syntax, layout, pragma placement, selective ADT constructor imports, whole-record imports, and operator grouping. Cover `_` and `_name` through all relevant syntactic contexts, both delimited nested `if` conditions and the undelimited rejection, `(->)` in type applications and instance heads, and expansive `impl` members even when signed or acyclic. A positive fixture should include prefix matching around postfix record construction with mixed braces and layout:

```text
foo = with Point with { x = 1 ; y = 2 }
    (Point x y) -> x + y
```

The first `with` starts matching; the second constructs its record scrutinee. Closing the record's explicit braces must still allow the following indented match block.

For named declarations, require a `binding_name` at the head. Expression blocks, `where`, and `do` `=` also admit a non-infix pattern declaration such as `(a, b) = pair`; top-level declarations remain named. Reject bare or parenthesized infix pattern heads in every declaration context. Keep parenthesized infix patterns in function parameters, and parse full patterns in `do` `<-` binds, which are not declarations. The v0 semantic check rejects all refutable `<-` patterns, including infix patterns. Give `do` `=` declarations ordinary strict sequential binding nodes rather than immediately applied lambdas, so definitions with parameters and generalization behave like expression-block bindings. Add negative fixtures for `x :: xs = value` in each declaration context and for `do { (x :: xs) <- action; rest }`; add positive fixtures for `uncons (x :: xs) = ...`, `(a, b) = pair`, and `do { f a = a; rest }`.

Consider property-based tests with a Concrete AST generator that renders valid combinations of indentation and explicit braces. Check that parsing pretty-printed concrete syntax preserves structure modulo formatting and spans, that comments survive, and that formatting is idempotent. Retain negative fixtures separately so invalid syntax is not normalized into an accepted form by the generator.

Diagnostics should render source excerpts and labeled spans in the style of `rustc`. A small set of humorous messages may explain attempts at dependent types, such as `foo : Int -> Type`, or suggest traits for `bar : Type -> Bool`. Suggested fixes are deferred.

## 2. Type checker

The type checker may follow *Typing Haskell in Haskell* (THIH), simplified for Ficus. Useful parts include:

- kinds, type variables, constructors, substitutions, and unification;
- predicates and qualified types;
- schemes, instantiation, and generalization;
- class environments, entailment, and ambiguity checks;
- inference over binding groups using dependency SCCs.

Ficus omits much of Haskell's complexity: it is strict, has single-parameter traits, and initially excludes higher-rank types, GADTs, type families, and unrestricted polymorphic mutation.

Inference consumes the Abstract AST and produces typed syntax and explicit evidence for every resolved trait predicate. For a recursive SCC, make explicit signature schemes available for independent instantiation at recursive use sites, then check each signed definition against its signature. Infer unsigned bindings with shared monotypes inside the SCC and generalize eligible ones at its boundary. Signature holes must be solved without using polymorphic recursion through the missing part. The separate non-expansive-initializer and lambda-protection checks still apply to cyclic SCCs.

Apply the v0 value restriction at each binding-group boundary. Generalize only non-expansive right-hand sides, using the same syntactic classifier that rejects expansive `impl` member initializers. A signature cannot bypass the restriction. Validate the irrefutable-pattern rule for `do` `<-` after parsing: variables, wildcards, unit, and products of irrefutable patterns pass; every other form fails.

Also apply the v0 monomorphism restriction before generalizing unsigned bindings: if a binding has unresolved trait predicates and no written parameters or explicit outer lambda, keep one monotype rather than abstracting those predicates into a reusable dictionary function. Resolve its remaining predicates against that monotype before accepting the binding. A complete explicit signature overrides this restriction but still must satisfy the value restriction; a signature with unresolved holes does not override it. Cover unsigned, signed, and lambda-wrapped constrained bindings with separate fixtures.

Keep weak type variables monomorphic across later uses and reject any still unresolved at the end of module inference, whether or not they carry trait predicates. A signature cannot silently generalize weak variables created by an expansive initializer.

The built-in list, binary-product, and function constructors participate in kind inference as `[] : Type -> Type`, `(*) : Type -> Type -> Type`, and `(->) : Type -> Type -> Type`. They have stable constructor identities, so implementation heads and higher-kinded holes may target them directly without aliases or spelling-based special cases in inference.

For a value signature or expression annotation, each `_` becomes a fresh type metavariable with a fresh kind metavariable. Unification may solve a hole to a proper type or a higher-kinded constructor such as `(*)`. After checking the inferred expression or binding, zonk the written skeleton, retain residual inferred predicates, and generalize only where the v0 value restriction permits. Reject type holes in alias right-hand sides, data bodies, trait member signatures, implementation heads, and other type-only locations.

Parse kind atoms as ordinary uppercase names, then resolve the reserved `Type` kind during semantic checking; do not hardcode `Type` in the parser. Kind annotations on ADT, record, and trait parameters constrain inferred kinds. Alias parameters remain unannotated; an optional top-level kind signature constrains the alias's inferred kind. Every `_` in a kind signature is a fresh kind metavariable to solve from the declaration; default any still-unconstrained kind variable to `Type` after inference and issue a warning. A standalone `_` in a non-binder, non-pattern expression position is an expression hole: infer and zonk its type, then issue a hard error showing that type and the hole's span, even if inference otherwise succeeds. Do not lower an expression hole to Core or Runtime AST.

Reject partial applications and direct or indirect cycles of transparent aliases. Check recursive ADT SCCs for regularity before kind inference accepts them: occurrences must use declared parameters unchanged and in order, including through mutual recursion.

Class-environment validation should enforce the Haskell 98 declaration forms before entailment:

- a trait head is `C a`, and every superclass predicate is `Ci a`;
- an implementation head is `C (T a1 ... an)` with distinct variables;
- every implementation-context predicate is `Ci aj` for a head variable;
- concrete, repeated, nested, and missing head variables are rejected.

These restrictions apply only to declarations. Predicates generated at use sites may contain arbitrary well-kinded monotypes, subject to ambiguity checking.

After collecting trait declarations, validate the superclass graph with an SCC pass. Every cyclic SCC, including a self-loop, is a static error. Entailment may then traverse superclasses without cycle detection in its hot path.

Integer and floating literals enter inference directly as `Int` and `Float`; they do not generate numeric trait predicates. Unary negation preserves either type and lowers to the corresponding compiler primitive.

Represent `Int` with signed 64-bit values and wrapping arithmetic, and `Float` with IEEE 754 binary64 values. Keep questions about out-of-range literals, integer division, and conversions separate from these settled representations.

Record projection may use a deferred `Field receiverType label resultType` constraint. Mark all type variables reachable from a pending field constraint weak so inner `where` or binding-group generalization cannot quantify them. Propagate those constraints to enclosing use sites, then solve once ordinary inference fixes a nominal receiver, no later than the module boundary. Unify the result with the declaration's field type. An unresolved receiver is a type error; do not generalize a field constraint. Field labels do not participate in trait lookup or choose a record type by themselves.

In a `MAGIC` module, name resolution supplies the compiler-provided `magic` identifier in type and value contexts. The parser treats it as an ordinary lowercase identifier: `magic "key"` is a type application in a type alias and an expression application in a value binding. During elaboration, the checker requires an explicit signature for every binding initialized from that identifier and validates its placement, single string-literal argument, key, and type against a compiler registry keyed by the binding's defining module and name. Any other use is rejected at this stage. Magic type bindings introduce opaque type constructors with compiler-assigned representations. Magic value bindings elaborate directly to typed primitive nodes. The application itself does not survive into the Core AST.

Validate orphan implementations against nominal ownership after alias expansion. An implementation must belong to the trait owner or the outer type constructor's owner. The built-in constructors `[]`, `(*)`, and `(->)` and primitive types `Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` have no module owner, so their implementations must belong to the trait owner. Erasing a single-field ADT's representation must not change its ownership or instance identity.

Trait bodies contain signatures only and an `impl` must supply every declared member. Derived operations such as `(/=) : Eq a => a -> a -> Bool` and `(<) : Ord a => a -> a -> Bool` are ordinary top-level functions, not trait members or dictionary fields. Elaborate their constraints and calls normally; instances need no forwarding members for these operations. Reject default member bodies and fallback instance implementations.

Method signatures may introduce additional qualified constraints on method-level variables, as `Traversable.traverse` does for `Applicative f`. Elaborate those predicates into method evidence at use sites; they are not new trait parameters. Reject a method whose unconstrained value type omits its trait parameter, such as `trait C a = { foo : Int }`.

Collect visible implementations from the current module and the transitive closure of its explicit and implicit imports. Do not consult unrelated modules in the build. Perform overlap and resolution-cycle checks within the visible set, independent of import order.

Before elaborating an `impl`, the checker classifies every member initializer as non-expansive or expansive, including acyclic members and members with complete signatures. Only non-expansive initializers are accepted. Written parameters count as surrounding lambdas, so the body of a method such as `show x = effect x` is not evaluated during dictionary construction. Include dictionary construction and member-to-top-level references in the same initialization dependency graph; a variable initializer may read an already initialized dependency but cannot bypass the cyclic-SCC checks.

For v1+, extend parsing to accept empty type bodies and empty `with` blocks. Empty record and empty ADT bodies share `type T = {}`: both grammar alternatives can accept the same empty braces, and there is no field or constructor token to distinguish them. Handle this shared empty-body case explicitly so parser alternative ordering does not assign different meanings or synthesize a nullary record constructor. An empty type body is uninhabited and introduces no constructor at either source or runtime level. Reject `Void with {}` during constructor resolution/elaboration because `type Void = {}` provides no record constructor. Include positive fixtures for the declaration and `with x {}` elimination and a negative semantic fixture for `Void with {}`. Exhaustiveness checking must recognize an empty match on such a type as exhaustive and distinguish it from an empty match on a potentially inhabited type. Core validation and runtime lowering must support elimination with no alternatives; do not introduce a synthetic value or constructor for `Void`. This replaces the v0 magic bindings for `Void` and `absurd`.

An optional warning for an empty type body may explain that it has no values and suggest `type Token = { Token }` if a unit-like type was intended. Keep this advisory; do not reject intentional empty types or replace them automatically.

The v1+ mutable-reference API is settled as specified in `SPEC.md`. Continue enforcing the v0 value restriction so expansive bindings such as `ref = newRef []` are not generalized. Atomicity and interaction with fibers remain unspecified.

For v1+ record patterns, parse explicit-brace field patterns contextually, distinct from record construction. Permit them in `with` clauses, lambda/function arguments, non-recursive bindings, and both `do` binding forms (`<-` and `=`). Reject them in recursive `let` groups. During SCC analysis, reject top-level or `where` record-pattern bindings that participate in a cycle and suggest a named function with an internal `with` match. Record punning remains undecided.

## 3. Core AST

A compact Core AST should stay close to the type-checker's elaboration result. Functions and applications are unary and curried; trait evidence is explicit. One possible grammar is:

```ebnf
module  = { data_decl | dict_decl | bind } ;

bind    = name ":" type "=" expr ;
expr    = variable
        | literal
        | fun binder "->" expr
        | app expr expr
        | let bind in expr
        | letrec "{" rec_bind { ";" rec_bind } "}" in expr
        | con constructor type_args value_args
        | case expr of "{" alt { ";" alt } "}"
        | if "{" if_alt { ";" if_alt } "}"
        | dict dict_constructor type_args value_args
        | select expr field
        | prim primitive type_args value_args ;

rec_bind = name ":" type "=" expr ;
if_alt  = expr "->" expr | "_" "->" expr ;
alt      = constructor binders "->" expr
         | literal "->" expr
         | "_" "->" expr ;
```

Every binder and expression carries its inferred Core type, even where the notation above omits it. HM type variables and type arguments may be retained for validation and specialization, then erased when the backend does not need them.

### 3.1 Functions and calls

Core AST functions are unary. A multi-parameter source definition becomes nested lambdas, and a multi-argument call becomes nested applications. For example:

```text
f : (Eq a, Show a) => a -> Int -> String
f x n = ...
```

is represented schematically as:

```text
f = fun eqA ->
    fun showA ->
        fun x ->
            fun n ->
                ...
```

An elaborated call is:

```text
app (app (app (app f eqInt) showInt) x) n
```

Dictionary evidence is an ordinary explicit parameter, conventionally placed before value parameters. Binder metadata may distinguish evidence from source parameters for diagnostics and later erasure, but Core AST application has only one mechanism.

### 3.2 Dictionaries

Each trait becomes a dictionary type containing:

- one field for each superclass dictionary;
- one function field for each method.

An `impl` becomes a dictionary constructor or a top-level dictionary value. A constrained binding receives required dictionaries explicitly. A method reference becomes `select dictionary method`; superclass entailment becomes selection of the superclass field.

Dictionary construction is explicit and strict. Reusing a dictionary value is preferable to reconstructing it at each call. Resolution is complete before Core AST generation: the Core AST contains no implicit trait lookup.

A trait with no members and only proof meaning has a unit dictionary. When no runtime operation consumes that evidence, lowering may erase both its dictionary value and its lambda/application pair. `Exception e` cannot currently be assumed to qualify: typed `catch` needs nominal runtime identity, and its evidence or another type token must survive erasure. The choice of representation remains open.

### 3.3 Other translations

Suggested translations are:

- source parameters and applications become nested unary lambdas and applications;
- sequential blocks become nested strict lets;
- non-expansive, lambda-protected recursive SCCs become `letrec`;
- patterns and `with` become `case`;
- binary products, lists, ADTs, and records become constructors and projections;
- n-component surface products become right-nested binary constructors;
- unary `-` becomes the `Int` or `Float` negation primitive;
- `do` and interpolation use the desugarings in the specification.

Keep `if` as a distinct Core AST conditional node, as shown schematically above. Desugaring must not turn it into `with`, and Core generation must not route it through a pattern-match node. The exact Runtime AST branch representation remains an implementation choice.

`let` is strict, including `do` `=` declarations and local pattern bindings. `letrec` accepts only SCCs whose initializers are non-expansive and whose recursive references are protected by lambdas. It allocates all slots first, then evaluates right-hand sides in source order. Constructor, dictionary, call, and primitive arguments evaluate left-to-right. Place an attached `where` group after every written parameter and before the declaration's right-hand side; arity raising must preserve any work at that intermediate application point.

Elaboration must preserve the specification's evaluation order. The Core AST validator should reject unbound variables, type mismatches, unsaturated dictionaries, invalid constructor arities, expansive cyclic initializers, unprotected recursive references, and malformed case alternatives. Keeping the Core AST typed makes the evaluator, optimizer, and future backends easier to validate.

## 4. Runtime AST

Runtime AST erases static types, type arguments, schemes, trait predicates, and source names not needed for diagnostics. Dictionaries remain only when their fields are used at runtime.

A compact form is:

```ebnf
program = globals, functions, entry ;
fun     = arity, frame_size, expr ;
expr    = local lexical_address
        | global global_id
        | literal
        | closure function_id captures
        | call expr args
        | let expr expr
        | letrec recursive_slots expr
        | con tag args
        | case expr alternatives
        | select expr field_index
        | prim primitive_id args ;
```

Runtime lowering erases constructor wrapping for every nominal ADT with exactly one constructor and one field, including single-field records. Construction evaluates the field with ordinary strict semantics and returns its representation directly, without allocating a tag or box. Matching unwraps that representation without tag dispatch, and a field projection returns the underlying representation. Keep the nominal type and constructor identities in typed Core AST and source metadata; only their runtime wrapper is erased.

Runtime AST raises arity for efficient execution. It groups only Core AST lambda chains whose intermediate application points perform no observable work into n-ary functions and flattens matching saturated application spines. Attached `where` initialization after a prefix of written parameters prevents flattening across that point. Partial applications and higher-order uses remain explicit closures.

Explicit dictionary arguments normally occupy leading runtime slots, followed by value arguments. Memberless proof dictionaries may be erased only when no runtime operation consumes their evidence; the unresolved `Exception e` representation is excluded from this erasure assumption. Other dictionaries lower to constructor-like records, method selection to indexed field selection, and dictionary methods to ordinary closures.

### 4.1 Variables and environments

Runtime AST must not perform string-based name lookup. Bound variables use lexical addresses:

```text
(frame depth, slot index)
```

This is a De Bruijn-style representation adapted to n-ary frames. It avoids alpha-renaming and gives direct slot lookup. A scalar De Bruijn index is simpler, but makes frame lookup and IR rewriting less clear.

Globals, functions, constructors, fields, and primitives use dense numeric IDs. After closure conversion, captures use compact closure-slot indices. Separate debug tables map IDs and source locations back to names.

### 4.2 Evaluator-oriented design

Runtime AST favors a small evaluator:

- constructor and field names become numeric tags and indices;
- pattern matching becomes tag or literal dispatch;
- argument and field vectors evaluate left-to-right;
- function metadata records arity and frame size;
- partial application stores the callee and supplied arguments;
- saturated calls allocate one frame and enter the body;
- tail position is explicit or structurally apparent;
- a validator rejects impossible states before execution.

Tail position may support a backend-specific tail-call optimization, but Runtime AST and source semantics do not require every backend to provide constant-stack tail calls.

Runtime AST is compiled compositionally before execution, so the hot path does not inspect AST constructors. ANF or compact bytecode may still be added if host-closure execution becomes the bottleneck. It should be derived from the Runtime AST, not replace the Core AST.

### 4.3 Erasure and validation

Lowering from Core AST must:

- erase types and memberless proof dictionaries while retaining dictionaries used at runtime;
- erase single-constructor, single-field wrappers without allocating tags or boxes; assign tags and field indices for other data representations, plus function IDs and lexical addresses;
- perform arity analysis and flatten eligible unary lambda/application chains into the calling convention;
- erase memberless proof dictionaries when runtime code does not consume them;
- preserve strict left-to-right evaluation;
- preserve partial and extra application behavior;
- retain source mappings for runtime errors.

The Runtime AST validator checks indices, arities, tags, case tables, capture layouts, primitive operands, non-expansive cyclic initializers, and lambda protection in recursive groups. The interpreter may rely on these invariants.

## 5. Evaluator compilation

Runtime AST compiles to host-language evaluator functions:

```haskell
type Eval = Env -> EvalResult Value
compile :: RTExpr -> Eval
```

`EvalResult` accounts for runtime errors and effects; a pure presentation may simplify it to `Value`. `compile` traverses each Runtime AST expression once and returns a host closure that performs only its runtime work.

```haskell
compile (Local address) =
    \env -> lookupLocal address env

compile (Let rhs body) =
    let rhsEval  = compile rhs
        bodyEval = compile body
    in \env -> do
        value <- rhsEval env
        bodyEval (push value env)

compile (Fun arity body) =
    let bodyEval = compile body
    in \env -> pure (VClosure arity bodyEval env [])
```

A lambda body is compiled to an `Eval` closure before any runtime function value is created. Evaluating the lambda packages that code closure with the current lexical environment. A partial application also stores supplied arguments; a saturated call creates the n-ary frame and invokes the stored evaluator directly.

Calls, alternatives, constructor fields, primitive operands, and dictionary operations follow the same pattern: compile their subexpressions once, then combine the evaluator closures. Recursive function groups tie the knot over precompiled bodies and their shared environment.

This is compositional evaluator compilation, staged interpretation, or closure threading. It resembles specializing an interpreter with respect to a program, but it is not general partial evaluation and requires neither binding-time analysis nor a Futamura projection.

Runtime AST is a good input because type checking, trait search, source names, and complex patterns have already been removed. Primitive effects remain behind a small evaluator interface.

A direct AST interpreter may remain as a simple test oracle. The compiled evaluator must produce the same values, errors, and effect order.

## 6. Future backends

The v2+ backend may closure-convert the Runtime AST and target WebAssembly GC for closures, ADTs, lists, dictionaries, and strings.

Optimized or generated code must remain observationally equivalent to the reference evaluator.

## 7. Entry points and compiler artifacts

Entry-point validation accepts exactly `main : [String] -> Unit` and `main : [String] -> Result String Unit` in v0. Runtime invocation passes command-line arguments and handles the chosen return form; argument conventions, error reporting, and exit-status details still need specification. Entry-point exception handling belongs to v1+.

v1+ compilation produces both module interface files and object files, each using Lisp-like syntax. Until the v2+ WebAssembly GC backend is available, object files serialize Runtime AST as text. The concrete schemas, compatibility/versioning rules, and linking details remain to be specified.

## 8. Initial v1+ CLI

```text
ficus compile FILES
ficus run FILE
ficus repl [FILE]
ficus format [-f FILE]
ficus lsp
```

`compile` runs the frontend and runtime lowering and emits only interface files and textual Runtime AST object files before the v2+ WebAssembly GC backend. `run` executes a file with the evaluator. `repl` starts an interactive evaluator session and optionally loads a file. `format` parses to Concrete AST and pretty-prints it with layout as a naive formatter. `lsp` initially exposes semantic highlighting, jumping to definitions, and showing inferred types using the spans, declaration identities, and provenance retained across AST stages.

The command surface is settled; output paths, optional-file loading behavior, and formatter input/output details remain open.

## 9. Further versioned work

v1+ adds deprecation pragmas with one or more identifier targets and an optional string message. Preserve that metadata for use-site diagnostics and module interfaces; detailed targeting and warning policy remain to be specified. Module-level `OPTIONS` pragmas require compiler-option parsing separate from ordinary identifier/literal pragma arguments. The accepted options, flags, warnings, and precedence relative to CLI options remain open.

The larger v1+ Prelude and JSON/regex facilities may use existing `MAGIC` bindings where needed; their APIs and module organization are not yet specified.

v2+ adds a simple build system, libraries beyond Prelude, dependency resolution, and FFI alongside the WebAssembly GC backend. Package formats, dependency algorithms, and foreign calling conventions remain open.

## 10. Draft type application and existential packages

The tentative v1+ `{a}` and `{a : Kind}` signature binders and positional `f {T}` type applications need a parsing-ambiguity review before the grammar is fixed. Keep explicit type arguments distinct from record braces and expression blocks. Type-argument order follows binder order if this syntax is adopted.

Existential record type members are targeted for v1+ or v2+. The proposed `type SomeException = { Err : Type; showErr : Err -> String }` combines an uppercase abstract type-member declaration with a lowercase value-field declaration. Extend record-body parsing to accept both categories and distinguish `Err : Type` from an ADT constructor; `Type` itself remains an ordinary parsed name resolved during semantic checking. Represent the package with an abstract witness type and operations over it, rather than path-dependent type selection. In the proposed pattern `SomeException with { Err = e; showErr = se } = ...`, `Err = e` opens the package with a fresh local type variable, while `showErr = se` binds the runtime operation. The former does not match a concrete type. Reject attempts to treat the type member as a value or constructor, and reject any inferred or written result type that lets the witness escape its scope. Runtime packages retain the operations or dispatch table needed to call them through the abstract interface. A `SomeException` package may later revise the proposed v1+ exception and fiber APIs; keep that adaptation open.
