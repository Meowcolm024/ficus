# Ficus Design

Ficus is an opinionated, minimalist, strict functional language for scripting. It favors a small, predictable core over a broad feature set while aiming for Python-like practicality with static typing, algebraic data types, pattern matching, and a compact Haskell/ML-style core.

This document explains the design. `SPEC.md` is normative; `IMPL.md` describes the implementation.

## 1. Principles

Ficus favors:

- fast startup and predictable execution;
- global Hindley–Milner inference;
- strict, left-to-right effects;
- a small language with capable libraries;
- syntax that works for both functional and scripting styles;
- roughly Haskell 98-level type-system complexity.

The compiler should know as little as practical. Arithmetic, comparison, formatting, collections, and IO mostly belong in libraries.

Compiler-known library hooks are keyed by defining module and declared name, so imports, aliases, and re-exports do not change their identity.

## 2. Evaluation

Evaluation is strict, impure, and left-to-right:

```text
f (print "a") (print "b")
```

This evaluates `f`, prints `a`, prints `b`, then applies the function. Optimizations must preserve that order.

Effects do not require an `IO` type:

```text
main args =
    count = length args
    println "count = {count}"
```

## 3. Modules and imports

The source path determines the module name. For example:

```text
Data/Map.ficus  →  Data.Map
```

There is no `module` declaration.

```text
use Data.Map
use Data.Map as M
use Data.Map (Map, empty, insert)
use Data.Map (..)
```

Modules and types have separate namespaces, so these may coexist:

```text
use Data.Map
use Data.Map (Map)
```

Types and traits share one namespace. Primitive type names and `Type` may be local module names or aliases: `use Data.Int`, `use Data.Int (add)`, and `use Data.Int as I` are valid. Module bindings do not rebind primitive types or change their ownership. Whether two imports may share the same local module name remains open; no overwrite or collision policy is selected.

An explicit import list may be re-exported:

```text
use Data.Map (Map, empty) pub
use Data.Map (..) pub
```

`pub` is invalid on bare and aliased imports:

```text
use Data.Map pub       -- invalid
use Data.Map as M pub  -- invalid
```

All top-level declarations are public in v0. `PRIVATE` and `PRIVATE member` pragmas are deferred. The latter hides ADT constructors or a record constructor and its fields while keeping the type public. Type import lists may select ADT constructors, for example `Maybe(..)` and `Either(Left)`. Importing a record type brings its public constructor and fields into scope; record member selections are invalid.

Imported names may retain multiple candidate entities until an occurrence uses them. Unused import conflicts are valid, including implicit Prelude conflicts; different routes to the same defining entity are not ambiguous. `pub` publication requires unique exported names and reports conflicting entities at the re-export. Missing modules and invalid selections are still checked immediately. This does not settle the separate local module-alias collision policy.

## 4. Pragmas and Prelude

Pragmas are global-only in v0. v1+ admits definition pragmas inside impl bodies, where groups, and local declaration sequences; arbitrary expression pragmas remain unsupported. ETA applies only to the following definition, with no module-wide or scope-wide setting or inheritance into sibling or nested definitions. It explicitly expands a function-valued initializer into one outer lambda before non-expansiveness checks, delaying and potentially repeating its original work. Module pragmas remain module-header-only. Module pragmas appear before imports:

```text
{-# NO_IMPLICIT_PRELUDE #-}
```

`NO_IMPLICIT_PRELUDE` removes the implicit Prelude. The six primitive types remain available.

All pragmas have an ALL_CAPITAL name and identifier/string arguments, parsed uniformly. `BUILTIN` resolves an ordinary declared target and does not disable Prelude.

```text
{-# DERIVE #-}
impl Show Point = {}
```

is the planned v1+ deriving form. The pragma takes no arguments and attaches to the following `impl`; its body must be empty. Any handwritten members, including partial implementations, are errors. Generation uses the ordinary implementation header and its written constraints; it does not add default methods or silently infer a larger context.

String interpolation and `do` depend on Prelude traits. They are rejected when the implicit Prelude is disabled.

## 5. Names and operators

Lowercase names denote values, fields, and type variables. Uppercase names denote modules, types, constructors, and traits.

A symbolic name beginning with `:` belongs to the uppercase namespace and may name a constructor or type.

An operator's parenthesized form is its name:

```text
(++) : [a] -> [a] -> [a]
(++) xs ys = ...

append = (++) xs ys
joined = xs ++ ys
```

Bare operators are infix-only. This is invalid:

```text
xs ++ ys = ...
```

`.` is punctuation for module qualification and record projection. It is not a valid function or operator name.

Symbolic constructors follow the same rule:

```text
type Chain a =
    End
    (:+) a (Chain a)
```

Operator spelling determines precedence and associativity; there are no fixity declarations. Precedence follows the Scala categories and is selected by the first character. An operator associates right when its name ends in `:` and left otherwise. The reserved list constructor `::` therefore uses the normal `:` precedence group and associates right:

```text
1 :: 2 :: [] = 1 :: (2 :: [])
```

Unary `-` is compiler-defined for `Int` and `Float`. Application binds tighter than unary `-`, which binds tighter than infix operators:

```text
-f x    = -(f x)
-x * y  = (-x) * y
f (-1)  = f applied to -1
```

## 6. Layout

Indentation is the default:

```text
f x =
    y = g x
    h y
```

Braces and semicolons are equivalent:

```text
f x = {
    y = g x;
    h y
}
```

Each block independently chooses layout or explicit braces. The parser opens an indentation block when its grammar expects one; layout is parser-driven rather than a lexer pre-pass.

## 7. Built-in types

The reserved primitive types are:

```text
Int Float Bool Char String Unit
```

They are available in every module, even without Prelude. `Type` is the reserved kind of ordinary types. `Int` is signed 64-bit with wrapping arithmetic; `Float` uses IEEE 754 binary64. Unconstrained kind variables default to `Type` with a warning.

Built-in expression types are fixed rather than overloaded:

```text
1     : Int
1.0   : Float
-1    : Int
-1.0  : Float
'a'   : Char
"a"   : String
True  : Bool
()    : Unit
```

`True` and `False` parse as ordinary uppercase identifiers and nullary constructors. As with the normally parsed list constructor `::`, their built-in meanings are reserved during name resolution.

Functions, products, and lists are structural:

```text
a -> b
a * b
[a]
```

Function and product types associate right:

```text
a -> b -> c = a -> (b -> c)
A * B * C   = A * (B * C)
```

Surface products with more than two components are right-nested sugar:

```text
(a, b, c) = (a, (b, c))
```

Lists have built-in syntax but library-defined operations:

```text
[]
[1, 2, 3]
x :: xs
```

`::` is always available with type `a -> [a] -> [a]`. The parser gives it no special case: it is an ordinary colon-led constructor operator in expressions and patterns. Its name is special only semantically—it is predefined for lists and cannot be rebound.

Lists, binary products, and functions expose first-class type constructors:

```text
[]  : Type -> Type
(*) : Type -> Type -> Type
(->): Type -> Type -> Type

impl Functor [] = ...
impl Bifunctor (*) = ...
impl Functor ((->) r) = ...
```

`[a]`, `a * b`, and `a -> b` are the applied forms of `[]`, `(*)`, and `(->)` respectively. These type-constructor names cannot be rebound; value-level multiplication remains an ordinary operator.

## 8. Types and annotations

Nominal algebraic data types use `type`:

```text
type Maybe a =
    Nothing
    Just a

type Shape =
    Circle Float
    Rect Float Float
```

Transparent aliases omit `type`:

```text
Point = Int * Int
Parser a = String -> [a * String]
```

Definitions are inferred:

```text
id x = x
map f xs = ...
```

Signatures name exactly one identifier or parenthesized operator before `:`; comma-separated targets and parameter lists before `:` are unsupported. Signatures and annotations constrain inference. Patterns and binder patterns can be annotated in parentheses, for example `foo (x : Int) = x` or `(x : Int) -> x`. In v0 these annotations accept concrete types, inference holes, and type variables scoped by explicit `@a` binders. `foo (x : a) = x` still fails without such a binder; a separate signature does not put its variables in scope here. Existing pattern restrictions still apply.

Examples:

```text
twice : (a -> a) -> a -> a
twice f x = f (f x)

answer = (read "42" : Int)

double : Int -> _
double x = x + x

foo : _ -> _ _ Int
foo x = (1, x)
```

Each `_` in a value signature, expression annotation, or pattern annotation is an independent type inference hole and may stand in constructor position. The examples complete to `Int -> Int` and `Int -> (Int * Int)`. Kind signatures on aliases and type parameters may also contain independent kind holes, inferred from the declaration. A standalone `_` in a non-binder, non-pattern expression position is a hard compilation error whose diagnostic shows the inferred type of the hole.

There is no visible type application at value call sites.

An ADT with one constructor and one field, including a single-field record, has the runtime representation of its field without a wrapper tag or boxing. It remains nominal, retains strict Ficus semantics, and keeps its own trait ownership.

Type aliases may have optional top-level kind signatures. Alias, ADT, record, and trait parameters may have optional parenthesized kind annotations. These parameters bind lowercase names rather than matching types; concrete type patterns such as `Alias Int = ...` are invalid. For example:

```text
Parser : Type -> Type
Parser a = String -> [a * String]

trait Functor (f : Type -> Type) =
    map : (a -> b) -> f a -> f b
```

Kinds of bare parameters are inferred, and `_` may appear in a kind signature to request inference. Any unconstrained kind defaults to `Type` with a warning. `Type` is parsed as an ordinary uppercase name in kind syntax and recognized as the reserved kind during semantic checking, not hardcoded by the parser.

v0 value signatures support outermost `{a}`/`{a : Kind}` quantifiers. Definitions and lambdas bind those variables with `@a` or `@(a : Kind)`, before value parameters: `id @a (x : a) = x` and `@a (x : a) -> (x, x)`. Applications supply types positionally with `foo @Int` or `foo @(List Int)`, before value arguments. Explicit binder order is retained in schemes and interfaces; other signature variables remain implicitly quantified. These are static binders and arguments, not runtime parameters or protection against expansive initialization. Term braces retain their block meaning. Nested quantifiers, such as `({a} -> a -> a)` in a function argument type, are rejected in v0; higher-rank checking remains future work.

## 9. Records

Records are nominal:

```text
type Person =
    name : String
    address : Address
```

Construction may be positional or named:

```text
alice = Person "Alice" home

bob =
    Person with
        name = "Bob"
        address = office
```

Projection chains associate left:

```text
person.address.city
= (person.address).city
```

Fields are resolved from the receiver's independently known nominal type. Labels may be reused by different records, but a label alone does not infer the receiver type.

Module qualification is resolved before projection:

```text
Data.People.default.address.city
```

Here `Data.People` is the longest module prefix, `default` is its exported value, and `address.city` is a projection chain.

Postfix `with` constructs a bare or qualified record constructor, or updates an existing nominal record value. Projection and with suffixes associate left and bind tighter than application; updating a call result requires parentheses. Updates preserve the complete receiver type, evaluate the receiver once and replacement fields in source order, and create a new record with omitted fields retained. They are expansive for initialization and inference. Prefix `with` remains matching, with separately delimited field/clause blocks for nested forms. Each field initializer may have its own scoped `where` group. Record patterns remain v1+; punning is unsupported. Updates of existential records remain open.

## 10. Functions and matching

Named and anonymous functions are concise and curried:

```text
add x y = x + y
inc = x -> x + 1
sum = x y -> x + y
```

Parameters may be patterns. Compound constructor and infix patterns are parenthesized so they cannot be confused with adjacent parameters:

```text
fromMaybe fallback (Just value) = value
uncons (x :: xs) = (x, xs)
mapPair f (x, y) = (f x, f y)
```

An infix pattern cannot head a declaration at top level, in a local block, in `where`, or on the left of `do` `=`. Local and `do` `=` declarations may bind non-infix patterns such as `(a, b)`. Parenthesized infix patterns remain valid as function arguments; `do` `<-` parses full patterns, though v0 accepts only irrefutable ones after checking.

Pattern matching uses `with`:

```text
area shape = with shape
    Circle r -> pi * r * r
    Rect w h -> w * h
```

Symbolic uppercase constructors may be used in prefix or infix patterns:

```text
with chain
    End -> ...
    (:+) x xs -> ...
    x :+ xs -> ...
    x :: xs -> ...
```

Clauses may have guards:

```text
describe shape = with shape
    Circle r if r <= 0 -> "invalid"
    Circle _ -> "circle"
    Rect w h if w == h -> "square"
    Rect _ _ -> "rectangle"
```

Multi-way `if` is the only conditional:

```text
sign x = if
    x < 0 -> -1
    x > 0 -> 1
    _ -> 0
```

Conditions and guards must have type `Bool`.

An unparenthesized lambda cannot be an `if` condition or pattern guard because `->` terminates the clause. Parentheses make the intent explicit when a lambda is needed there.

## 11. Blocks and recursion

Ordinary block bindings are strict, sequential, and non-recursive:

```text
f x =
    a = first x
    b = second a
    combine a b
```

`where` introduces mutually visible declarations. Before the body runs, declarations initialize in dependency order with source order as the tie-breaker.

```text
parity n = (odd n, even n)
    where
        odd x = if
            x == 0 -> False
            _ -> even (x - 1)

        even x = if
            x == 0 -> True
            _ -> odd (x - 1)
```

By default, every top-level value initializer must be non-expansive, even outside a cycle or under a complete signature. In v1+, `STANDALONE` permits expansive acyclic top-level definitions while making the module unimportable; recursive groups and implementation members retain their restrictions. Written value parameters defer the body and its attached `where` group until application; immediately evaluated `where` groups must also pass the check. Local bindings can still compute or allocate references during function execution.

A recursive cycle is accepted only when its initializers are non-expansive and every intra-cycle reference is protected by a lambda after parameter desugaring. This prevents a closure from being called or a strict value from being read during initialization.

An explicit type signature also permits polymorphic recursion within the group: each recursive use can instantiate the signed binding's scheme. Unsigned bindings retain a shared monotype during group inference. Signatures do not relax recursive-initializer safety.

The v0 value restriction generalizes only non-expansive bindings. Local function calls and other expansive initializers remain monomorphic even if they are immutable; a written signature cannot override this rule.

The v0 monomorphism restriction also prevents generalizing an unsigned constrained binding with no lambda parameters, even when its right-hand side is non-expansive. A complete explicit signature may override this restriction, subject to the value restriction.

## 12. Traits

Traits are single-parameter type classes:

```text
trait Show a =
    show : a -> String

impl Show Person =
    show person = person.name
```

Qualified types carry requirements:

```text
showAll : Show a => [a] -> String
```

A method can constrain a variable other than the trait parameter. `Traversable t` can declare `traverse : Applicative f => (a -> f b) -> t a -> f (t b)`, where `Applicative f` is a method-level requirement.

Supertraits use the same syntax:

```text
trait Functor f =
    map : (a -> b) -> f a -> f b

trait Pure f =
    pure : a -> f a

trait Seq f =
    seq : f (a -> b) -> (Unit -> f a) -> f b

trait (Functor f, Pure f, Seq f) => Applicative f = {}

trait Bind f =
    bind : f a -> (a -> f b) -> f b

trait (Applicative f, Bind f) => Monad f = {}
```

Declaration heads follow Haskell 98 restrictions:

```text
trait (C1 a, C2 a) => C a = {}                 -- valid
impl (C1 a1, C2 a2) => C (T a1 a2) = ...      -- valid
impl C (T Int a) = ...                         -- invalid
impl C (T a a) = ...                           -- invalid
```

Trait heads use one bare variable. Implementation heads use one outer constructor applied to distinct bare variables. By contrast, use-site predicates may mention arbitrary types:

```text
foo : C [a] => a -> b
```

The superclass graph must be acyclic; direct and indirect superclass cycles are rejected.

Trait bodies contain signatures only and every `impl` supplies every declared member. Operations that would be default instance methods in Haskell are ordinary constrained functions outside the trait: `(/=)` derives from `(==)` under an `Eq` constraint, and `(<)` derives from `compare` under an `Ord` constraint. Callers use these functions directly; instances do not declare them or provide forwarding definitions. Default member bodies and fallback instance implementations are unsupported. The initial design also excludes overlapping implementations, multiparameter traits, associated types, and type families.

An implementation must be defined in the module that owns its trait or its outer type constructor. No module owns `[]`, `(*)`, `(->)`, `Int`, `Float`, `Bool`, `Char`, `String`, or `Unit`, so implementations for these belong to the trait owner.

Top-level definitions require non-expansive initializers by default, with the v1+ acyclic standalone exception; implementation members always retain this requirement. Lambdas, literals, variables, constructors, and aggregates of such values are allowed; effectful applications are allowed only inside a lambda body. This prevents observable effects while trait dictionaries initialize.

Projection constraints cannot be generalized. Their type variables remain monomorphic while surrounding uses may determine the receiver; an unresolved receiver is an error.

## 13. Prelude-dependent sugar

Interpolation uses Prelude's `Show` and string concatenation. v0 permits a variable or module-qualified variable inside the braces:

```text
"name: {name}"
"name: {Data.Person.name}"
```

It behaves roughly like:

```text
"name: " ++ show name
```

`do` uses Prelude's `Bind` abstraction:

```text
decode input = do
    value <- parse input
    name <- field "name" value
    pure name
```

`do` is not needed for ordinary effects.

In v0, `<-` accepts only patterns proved irrefutable by type-directed coverage checking after resolution and inference. Parsing admits every supported pattern form. A single-constructor pattern can pass when its fields cover their types; notation and annotations do not decide refutability. Refutable patterns fail semantic validation, not parsing.

Prelude re-exports the source-defined `Void` and `absurd` from `Data.Void`:

```text
type Void = {}

absurd : Void -> a
absurd x = with x {}
```

The byte and vector types are named `Byte` and `Vec a`, replacing `U8` and `Array a`.

See `PRELUDE.md` for the intended fine-grained control traits and initial library surface.

## 14. Builtin declarations

Compiler implementations are associated with ordinary top-level declarations:

```text
{-# BUILTIN HANDLE Handle #-}
Handle : Type

{-# BUILTIN BYTE Byte #-}
Byte : Type

{-# BUILTIN VEC Vec #-}
Vec : Type -> Type

{-# BUILTIN INT_ADD addInt #-}
addInt : Int -> Int -> Int
```

The target resolves under ordinary scope rules, independently of adjacency. Its type/kind comes from a normal declaration; the pragma contains no signature. Bodyless targets require complete declaration signatures. Types are opaque and nominal; values are primitive bindings. Unknown keys, unresolved targets, incompatible declarations, conflicting associations, and additional source definitions are errors. Namespace, scope, imports, exports, and ownership remain ordinary. Builtin declarations retain implicit Prelude unless the module explicitly uses `NO_IMPLICIT_PRELUDE`.

Future v2+ FFI follows the same style:

```text
{-# FOREIGN JS "console.log" log #-}
log : String -> Unit
```

Backends, marshalling, calling conventions, and exception behavior remain open. See SPEC.md for language rules and IMPL.md for annotation handling and lowering.

## 15. Implementation shape

The implementation uses four AST stages:

```text
Concrete AST
→ Abstract AST
→ Core AST
→ Runtime AST
```

The Concrete AST preserves source structure, comments, and layout for a naive formatter. The Abstract AST is the result of desugaring and name resolution, with repeated definition clauses combined into a single `with` expression per binding. Spans and provenance survive through Core AST for diagnostics and future LSP features. `if` remains a distinct conditional in Abstract and Core AST and is never desugared to `with` there. The Core AST is the unary, curried result of type inference and elaboration. The Runtime AST performs arity raising, erases static types and unused proof dictionaries, uses compact lexical addresses, and targets efficient evaluation.

The Runtime AST is compiled compositionally:

```haskell
type Eval = Env -> EvalResult Value
compile :: RTExpr -> Eval
```

Lambda bodies are compiled once into host functions. Evaluating a lambda packages its compiled body with the current environment, avoiding repeated AST dispatch.

Tail-call optimization is backend-dependent; the language does not guarantee constant stack use for tail recursion.

See `IMPL.md` for details.

## 16. Deferred features

The initial language excludes:

- record patterns and record punning;
- empty type bodies and empty `with` matches;
- the `forall` keyword and higher-rank quantified signatures;
- deriving, including the argument-free `DERIVE` pragma on an empty implementation;
- lazy arrows `~>`, replacing the earlier prefix-`~` proposal;
- private pragmas, including `PRIVATE member`;
- advanced trait machinery;
- GADTs, higher-rank types, and dependent types;
- unrestricted mutable references;
- effect systems, concurrency, and async syntax;
- macros, ownership types, and custom memory management.

Private/definition pragmas, ETA, exceptions, empty type bodies and matches, and mutable references are planned for v1+ with the existing designs. Initial deriving is limited to structural traits such as `Show` and `Eq`. The v1+ module pragma `{-# STANDALONE #-}` permits expansive acyclic top-level initializers and prevents imports of that module. It may import ordinary modules, retains Prelude, and neither selects an entry nor requires main; ordinary main validation applies if explicitly selected for execution.

Lazy arrows move to v2+ and must be explicit; inference continues to default to strict `->`. The reserved `~>` token will be right-associative type punctuation, not an ordinary symbolic operator:

```text
and : Bool ~> Bool ~> Bool
```

They use call-by-name thunks: each demanded variable use re-evaluates the captured argument, without memoization; unused arguments do not run. Non-variable/non-wildcard parameter patterns demand once per matching attempt. Effects and failures repeat with demands. Neither lazy nor strict arrows are subtypes of each other, and no implicit coercion is inserted. Concrete Core representation remains open.

The initial v2+ builtin-backed concurrency module provides:

```text
fork : Exception e => (Unit -> a) -> Fiber e a
join : Fiber e a -> Result e a
newChan : Unit -> Chan a
send : Chan a -> a -> Unit
recv : Chan a -> a
```

These are explicit imports, not Prelude declarations. The v0 value restriction prevents generalization of expansive channel allocations. Scheduling, buffering, cancellation, and exception propagation need operational detail.

The initial v1+ typed-exception design uses a Prelude marker trait and builtin-backed operations:

```text
trait Exception e = {}

throw : Exception e => e -> a
catch : Exception e => (Unit -> a) -> (e -> a) -> a
```

`catch` handles only the selected exception type and propagates others. The proposed v2+ interface keeps the exception type in `Fiber e a`, and `join` returns `Result e a`. An existential `SomeException` package may later change those signatures.

`Exception e` has no source-level methods. Its runtime representation remains open because typed `catch` must distinguish nominal exception types even when their values have the same erased representation.

v1+ replaces the builtin-backed empty type and eliminator with:

```text
type Void = {}

absurd : Void -> a
absurd x = with x {}
```

Empty records and empty ADTs share the syntax `type T = {}` and require care when parsing the two body alternatives. Both introduce no constructor, so `Void with {}` is invalid. `Void` is uninhabited, so this empty match is exhaustive. The exhaustiveness checker must account for uninhabited types; its detailed treatment within other patterns remains open.

The mutable-reference design is settled for v1+ and remains builtin-backed:

```text
newRef : a -> Ref a
modifyRef : Ref a -> (a -> a) -> Unit
readRef : Ref a -> a
```

The v0 value restriction continues to apply to `Ref`; it prevents generalizing expansive allocations. Atomicity with respect to fibers remains undecided.

## 17. Entry points and v1+ artifacts

Execution explicitly selects one entry module, which must define its own `main`; an imported `main` is insufficient. Library modules need not define it, and other modules' `main` functions are not automatically invoked. v0 supports `main : [String] -> Unit` and `main : [String] -> Result String Unit`. The entry function receives command-line arguments; argument conventions, error reporting, and exit-status details remain to be specified. Entry-point exception handling belongs to v1+.

v1+ compiler-generated interface and object files both use Lisp-like syntax. Initial object files serialize Runtime AST as text; their integration with v2+ JavaScript artifacts remains open. The concrete schemas remain to be specified. See `SPEC.md` for the settled entry points and v1+ private-pragma examples.

Ordinary record update syntax, type preservation, and evaluation are settled for v0. Updates of existential records and concrete compiler artifact schemas remain open. Record punning is unsupported.

The initial v1+ CLI is:

```text
ficus compile FILES
ficus run FILE
ficus repl [FILE]
ficus format [-f FILE]
ficus lsp
```

`compile` initially emits only interfaces and Runtime AST text object files. `run` executes a file; `repl` optionally loads one. `format` uses the Concrete AST as a naive formatter. The initial LSP supports semantic highlighting, jumping to definitions, and showing types. Command input/output details remain open.

## 18. Further versioned plans

v1+ adds `{-# DEPRECATED ident+ "<message>" #-}` for one or more deprecated identifiers with an message, and the module-level `{-# OPTIONS "<compiler options>" #-}` pragma. Actual compiler options, flags, and warnings remain to be specified. Deprecation targeting and warning-policy details also remain open.

v1+ expands Prelude in the style of Haskell and adds JSON and regex facilities, potentially supplied by builtin-backed modules. The proposed roots are `Ficus.Builtin`, `Class`, `System`, `Data`, and `Control`, with selected definitions re-exported by `Prelude`. APIs, module availability, and the exact implicit export list remain open; see `PRELUDE.md` for bootstrap and ownership considerations.

v2+ adds concurrency primitives, lazy arrows, a simple JavaScript backend with tail-call optimization, a simple build system supporting libraries beyond Prelude and dependency resolution, and FFI. v3+ considers WebAssembly GC or LLVM. Concrete build, dependency, and FFI designs remain open.

## 19. Additional v1+ directions

Record patterns mirror named construction with explicit braces, such as `Point with { x = px }`; omitted fields are ignored, including all fields in `Point with {}`. They are permitted in matches, lambdas/function arguments, non-recursive bindings, and both `do` binding forms (`<-` and `=`), but not in recursive `let` groups. A top-level or `where` record-pattern binding in a recursive SCC is rejected with a suggestion to match inside a named function using `with`. Refutability is computed from the resolved record and supplied subpatterns; omitted fields are ignored, and refutable fields prevent use in `<-`. Record punning is unsupported.

Existential record type members, inspired by *Types and Programming Languages*, are targeted for v1+. The proposed declaration `type SomeException = { Err : Type; showErr : Err -> String }` puts an uppercase abstract type member and a lowercase runtime operation in one record body. It packages a hidden type with operations, not a path-dependent type. The proposed unpacking pattern `SomeException with { Err = e; showErr = se } = ...` introduces `e` as a local type variable and `se` as a value binder. `Err = e` does not match against a concrete type; the hidden type must not escape its scope, and calling `se` requires runtime dispatch through the package. An existential `SomeException` could change the proposed v1+ exception and v2+ concurrency signatures. Type members can be supplied or opened explicitly only by named `with` fields: construction uses `SomeException with { Err = String; showErr = (e : String) -> e }`, and patterns use `SomeException with { Err = e; showErr = se }`. Uppercase labels identify type-member slots; no `@` is used inside them. `Err = e` opens a fresh witness rather than testing a concrete type. Ordinary `@` type application cannot supply existential record members. Positional slots contain only value fields; positional construction infers the witness, and positional matching opens it anonymously. Named patterns can omit fields and type members, with the same witness non-escape checks. Witness inference, records with only type members, and existential updates remain open; see `SPEC.md`.
