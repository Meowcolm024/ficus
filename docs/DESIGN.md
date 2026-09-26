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

All top-level declarations are public in v0. `PRIVATE` and `PRIVATE members` pragmas are deferred. Type import lists may select constructors and fields, for example `Maybe(..)`, `Either(Left)`, and `Complex(real,imaginary)`; a bare type import imports only the type.

## 4. Pragmas and Prelude

Pragmas are accepted only at global declaration level. Inline expression and local declaration pragmas are deferred. Module pragmas appear before imports:

```text
{-# NO_IMPLICIT_PRELUDE #-}
{-# MAGIC #-}
```

`NO_IMPLICIT_PRELUDE` removes the implicit Prelude. The six primitive types remain available.

`MAGIC` enables compiler bindings and implies `NO_IMPLICIT_PRELUDE`.

```text
{-# DERIVE Show #-}
```

is reserved for future deriving support.

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

Each block independently chooses layout or explicit braces.

## 7. Built-in types

The reserved primitive types are:

```text
Int Float Bool Char String Unit
```

They are available in every module, even without Prelude. `Type` is the reserved kind of ordinary types.

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

Lists and binary products expose first-class type constructors:

```text
[]  : Type -> Type
(*) : Type -> Type -> Type

impl Functor [] = ...
impl Bifunctor (*) = ...
```

`[a]` and `a * b` are the applied surface forms of `[]` and `(*)` respectively. The constructor names are reserved in the type namespace and cannot be rebound; value-level multiplication remains an ordinary operator.

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

Signatures and annotations constrain inference:

```text
twice : (a -> a) -> a -> a
twice f x = f (f x)

answer = (read "42" : Int)

double : Int -> _
double x = x + x

foo : _ -> _ _ Int
foo x = (1, x)
```

Each `_` in a value signature or expression annotation is an independent type inference hole and may stand in constructor position. The examples complete to `Int -> Int` and `Int -> (Int * Int)`. Kind signatures on aliases and type parameters may also contain independent kind holes, inferred from the declaration. A standalone `_` in a non-binder, non-pattern expression position is a hard compilation error whose diagnostic shows the inferred type of the hole.

There is no visible type application at value call sites.

An ADT with one constructor and one field, including a single-field record, has the runtime representation of its field without a wrapper tag or boxing. It remains nominal, retains strict Ficus semantics, and keeps its own trait ownership.

Type aliases may have optional top-level kind signatures, but their parameters are bare names without annotations. ADT, record, and trait parameters may have optional parenthesized kind annotations. For example:

```text
Parser : Type -> Type
Parser a = String -> [a * String]

trait Functor (f : Type -> Type) =
    map : (a -> b) -> f a -> f b
```

Kinds of bare parameters are inferred, and `_` may appear in a kind signature to request inference. `Type` is parsed as an ordinary uppercase name in kind syntax and recognized as the reserved kind during semantic checking, not hardcoded by the parser.

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

Postfix `with` on a bare uppercase identifier introduces a named-construction block, which may use layout or braces. Prefix `with` remains pattern matching, so token position distinguishes the two forms. A field initializer may have its own `where` clause, scoped to that field. Record patterns are deferred to v1+ with explicit braces and restricted use; punning and record update remain undecided. Updates may later reuse postfix `with` with a broader receiver.

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

An infix pattern cannot head a declaration at top level, in a local block, in `where`, or on the left of `do` `=`. Parenthesized infix patterns remain valid as function arguments; `do` `<-` accepts full patterns because it is a match bind, not a declaration.

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

A recursive cycle is accepted only when every reference within that cycle is protected by a lambda after parameter desugaring. This permits recursive functions without permitting a strict value to read itself during initialization.

An explicit type signature also permits polymorphic recursion within the group: each recursive use can instantiate the signed binding's scheme. Unsigned bindings retain a shared monotype during group inference. Signatures do not change the lambda-protection requirement.

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

Supertraits use the same syntax:

```text
trait Functor f =
    map : (a -> b) -> f a -> f b

trait Pure f =
    pure : a -> f a

trait Apply f =
    ap : f (a -> b) -> f a -> f b

trait (Functor f, Pure f, Apply f) => Applicative f = {}

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

An implementation must be defined in the module that owns its trait or its outer nominal type constructor. No module owns `[]`, `(*)`, `Int`, `Float`, `Bool`, `Char`, `String`, or `Unit`, so implementations for these belong to the trait owner.

Implementation members must have non-expansive initializers. Lambdas, literals, variables, constructors, and aggregates of such values are allowed; effectful applications are allowed only inside a lambda body. This prevents observable effects while trait dictionaries initialize.

## 13. Prelude-dependent sugar

Interpolation uses Prelude's `Show` and string concatenation:

```text
"name: {person.name}"
```

It behaves roughly like:

```text
"name: " ++ show person.name
```

`do` uses Prelude's `Bind` abstraction:

```text
decode input = do
    value <- parse input
    name <- field "name" value
    pure name
```

`do` is not needed for ordinary effects.

The v0 Prelude re-exports `Void` and `absurd`. Until empty declarations and matches exist, an explicit magic-backed module supplies:

```text
Void : Type
Void = magic "void"

absurd : Void -> a
absurd = magic "absurd"
```

The byte and vector types are named `Byte` and `Vec a`, replacing `U8` and `Array a`.

See `PRELUDE.md` for the intended fine-grained control traits and initial library surface.

## 14. Magic modules

Opaque runtime types and primitive operations are supplied by ordinary library modules marked `MAGIC`, not by a virtual primitive package:

```text
{-# MAGIC #-}

Handle : Type
Handle = magic "handle"

Byte : Type
Byte = magic "u8"

Vec : Type -> Type
Vec = magic "array"

addInt : Int -> Int -> Int
addInt = magic "addInt"
```

Conceptually:

```text
magic : {k : Sort} -> StringLiteral -> k
```

`Sort` is compiler meta-notation covering both value types and kinds. `StringLiteral` is a compile-time key, not a runtime `String`. Type expressions admit integer, character, and string literals, but not floating-point literals. A compiler-backed type declaration therefore parses `magic "key"` as an ordinary type application; a value declaration parses it as an ordinary expression application. Its use as a compiler binding is established during name resolution. Every compiler-backed binding requires an explicit signature. Invalid uses and keys are rejected during elaboration, which also validates the signature against the selected key.

The compiler-provided `magic` binding is available only in a `MAGIC` module; the spelling itself is not reserved.

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

See `IMPL.md` for details.

## 16. Deferred features

The initial language excludes:

- record patterns, including punning, and record update;
- empty type bodies and empty `with` matches;
- visible type application and explicit `forall`;
- deriving, including the reserved `DERIVE Show` pragma;
- lazy arrows `~>`, replacing the earlier prefix-`~` proposal;
- private pragmas, including `PRIVATE members`;
- advanced trait machinery;
- GADTs, higher-rank types, and dependent types;
- unrestricted mutable references;
- effect systems, concurrency, and async syntax;
- macros, ownership types, and custom memory management.

Private pragmas, lazy arrows, concurrency, exceptions, empty type bodies and matches, and mutable references are planned for v1+ with the existing designs. Initial deriving is limited to structural traits such as `Show` and `Eq`.

Lazy arrows must be explicit; inference continues to default to strict `->`. The reserved `~>` token will be right-associative type punctuation, not an ordinary symbolic operator:

```text
and : Bool ~> Bool ~> Bool
```

They elaborate to shared thunks, with call sites wrapping lazy arguments. The exact Core representation and effect semantics remain deferred.

The initial v1+ magic-backed concurrency module provides:

```text
fork : Exception e => (Unit -> a) -> Fiber e a
join : Fiber e a -> Result e a
newChan : Unit -> Chan a
send : Chan a -> a -> Unit
recv : Chan a -> a
```

These are explicit imports, not Prelude declarations. Channels require a value restriction or equivalent generalization rule. Scheduling, buffering, cancellation, and exception propagation need operational detail within this finalized initial design.

The initial v1+ typed-exception design uses a Prelude marker trait and magic-backed operations:

```text
trait Exception e = {}

throw : Exception e => e -> a
catch : Exception e => (Unit -> a) -> (e -> a) -> a
```

`catch` handles only the selected exception type and propagates others. The finalized initial v1+ exception/concurrency interface keeps the exception type in `Fiber e a`, and `join` returns `Result e a`. An existential `SomeException` package may later change those signatures.

`Exception e` is a memberless proof trait. Its unit dictionary may be erased after checking; magic lowering supplies any runtime type token separately.

v1+ replaces the magic-backed empty type and eliminator with:

```text
type Void = {}

absurd : Void -> a
absurd x = with x {}
```

Empty records and empty ADTs share the syntax `type T = {}` and require care when parsing the two body alternatives. Both introduce no constructor, so `Void with {}` is invalid. `Void` is uninhabited, so this empty match is exhaustive. The exhaustiveness checker must account for uninhabited types; its detailed treatment within other patterns remains open.

The mutable-reference design is settled for v1+ and remains magic-backed:

```text
newRef : a -> Ref a
modifyRef : Ref a -> (a -> a) -> Unit
readRef : Ref a -> a
```

Adding `Ref` requires an ML-style value restriction. Atomicity with respect to fibers remains undecided.

## 17. Entry points and v1+ artifacts

v0 supports `main : [String] -> Unit` and `main : [String] -> Result String Unit`. The entry function receives command-line arguments; argument conventions, error reporting, and exit-status details remain to be specified. Entry-point exception handling belongs to v1+.

v1+ compiler-generated interface and object files both use Lisp-like syntax. Object files serialize Runtime AST as text until the v2+ WebAssembly GC backend is available. The concrete schemas remain to be specified. See `SPEC.md` for the settled entry points and v1+ private-pragma examples.

Record update and other previously open design choices not explicitly settled here remain open. In particular, this revision does not choose a record-update syntax or receiver form, record punning, or concrete compiler artifact schemas. Exclusion from v0 does not decide a feature's future design.

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

v1+ adds `{-# DEPRECATED ident+ ["<message>"] #-}` for one or more deprecated identifiers with an optional message, and the module-level `{-# OPTIONS [compiler options] #-}` pragma. Actual compiler options, flags, and warnings remain to be specified. Deprecation targeting and warning-policy details also remain open.

v1+ expands Prelude in the style of Haskell and adds JSON and regex facilities, potentially backed by `MAGIC` modules. APIs, module organization, and implicit re-exports remain open.

v2+ adds the WebAssembly GC backend, a simple build system supporting libraries beyond Prelude and dependency resolution, and FFI. Concrete build, dependency, and FFI designs remain open.

## 19. Additional v1+ directions

Record patterns mirror named construction with explicit braces, such as `Point with { x = px }`. They are permitted in matches, lambdas/function arguments, non-recursive bindings, and both `do` binding forms (`<-` and `=`), but not in recursive `let` groups. A top-level or `where` record-pattern binding in a recursive SCC is rejected with a suggestion to match inside a named function using `with`. Record punning remains open.

Tentative v1+ syntax binds type variables in signatures as `{a}` or `{a : Type}` and applies type arguments positionally as `foo {Int} 1`. This is draft only and may change if parsing is ambiguous.

Existential record type members, inspired by *Types and Programming Languages*, are targeted for v1+ or v2+. The proposed declaration `type SomeException = { Err : Type; showErr : Err -> String }` puts an uppercase abstract type member and a lowercase runtime operation in one record body. It packages a hidden type with operations, not a path-dependent type. The proposed unpacking pattern `SomeException with { Err = e; showErr = se } = ...` introduces `e` as a local type variable and `se` as a value binder. `Err = e` does not match against a concrete type; the hidden type must not escape its scope, and calling `se` requires runtime dispatch through the package. An existential `SomeException` could change the current v1+ exception/concurrency signatures. Package construction syntax and the version boundary remain open; see `SPEC.md`.
