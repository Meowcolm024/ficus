# Intended Prelude

This document sketches a small v0 Prelude. It is non-normative and intentionally incomplete. v1+ expands it in the style of Haskell and adds JSON and regex facilities, potentially supplied by builtin-backed modules. The proposed module organization is recorded below; expanded APIs and the exact implicit re-export list remain to be frozen.

The control hierarchy follows Lean's fine-grained approach: operations such as `map`, `pure`, application, and `bind` have separate traits. Conventional `Applicative` and `Monad` names remain available as composite marker traits.

## 1. Organization

The proposed public layout is:

```text
Prelude                  -- selected re-exports
Ficus.Builtin
    Int                  -- primitive operations, not a redeclaration of Int
    Handle               -- builtin-backed library type and operations
    ...
Class
    Show
    Bind
    ...
System
    IO
    Environment
    ...
Data
    List
    Map
    Function
    ...
Control
    Exception
    ...
```

Indented entries denote modules such as `Ficus.Builtin.Int` and `Class.Show`. This is a proposed organization, not a commitment that every module is available in v0. `System.IO` names an operations module; it does not introduce an `IO` type.

`Ficus.Builtin.*` holds declarations backed by `BUILTIN` and their minimal support definitions. The six reserved primitive types are already in scope and are not redeclared there. Ordinary library types such as `Handle`, `Byte`, and `Vec` retain their defining module identity. Public operations and wrappers may be exposed through `Data.*`, `System.*`, or `Control.*` without changing that identity.

`Class.*` defines the basic traits and associated constrained functions. Under the existing ownership rule, implementations for primitive types and built-in list/product/function constructors must live in the module defining the trait: for example, `Show Int` belongs in `Class.Show`. Implementations for ordinary library types may instead live with their type. Keep this distinction when selecting module dependencies.

The proposed bootstrap policy is to put `{-# NO_IMPLICIT_PRELUDE #-}` before imports in every standard-library module, including `Prelude` itself. All library dependencies are then explicit; application modules retain implicit Prelude unless they opt out. This avoids an accidental dependency back to Prelude when an internal module is added or moved into its dependency graph. Bootstrap from builtin declarations and basic data definitions, then build traits and higher-level operations according to their actual dependencies, with Prelude last. Basic types such as Ordering may be needed by trait contracts, so the module roots are not strict dependency layers. Keep constructor-only data dependencies independent of trait modules where needed; place implementations according to ownership without introducing imports back into their dependencies. Actual dependencies must remain acyclic. `BUILTIN` alone does not disable implicit Prelude. Primitive-named modules may be imported directly, for example `use Ficus.Builtin.Int`; a distinct alias such as `as BInt` is optional. Whether this may coexist with `use Data.Int` under the same local module name remains open. Under the current v0 rules, disabling implicit Prelude also forbids `do` and string interpolation even when their supporting definitions are imported explicitly; standard-library bootstrap code uses ordinary function calls instead. Changing that sugar rule would require a separate spec revision.

Prelude should use explicit selective re-exports. Freeze a reviewed list of values, operators, types, constructors, and traits before treating the implicit API as stable; adding a definition to a source module must not silently expand Prelude. Candidate categories are the existing basic traits, common data types, list/string operations, function combinators, and selected IO helpers. Environment access, specialized collections, exception/concurrency APIs, and low-level builtin operations should require explicit imports unless individually selected. The exact selections remain open, including which basic type constructors and trait implementations are visible through those imports.

Modules marked `NO_IMPLICIT_PRELUDE` receive none of these declarations. The reserved types `Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` remain available.

### Proposed v0 scope

| Area | Modules or traits |
| --- | --- |
| Builtin-backed declarations | `Ficus.Builtin.Int`, `.Float`, `.Bool`, `.Char`, `.String`, `.Unit`, `.Handle`, `.Vec`, `.Byte` |
| Basic classes | `Debug`, `Show`, `Eq`, `Ord`, `Pure`, `Seq`, `Bind`, `Functor`, `Applicative`, `Monad`, `Alternative`, `Semigroup`, `Monoid`, `Default`, `Bifunctor`, `Foldable`, `Traversable`, each under `Class` |
| System | `System.IO` |
| Data | `Data.List`, `.Function`, `.Product`, `.Ordering`, `.Maybe`, `.Result` or `.Either`, `.Const`, `.Int`, `.Float`, `.Bool`, `.Char`, `.String`, `.Unit`, `.Vec`, `.Byte` |
| Control | No v0 modules; exceptions and concurrency remain later work |

`Handle` stays out of the proposed `Data` layer; its public IO operations belong in `System.IO`. Primitive data modules expose operations on the already-reserved types rather than defining replacement types. `Data.Const` denotes the constant type constructor, distinct from the ordinary `const` function in `Data.Function`.

The requested composites are `Applicative = Functor + Pure + Seq` and `Monad = Applicative + Bind`. `Functor` remains independently usable and is also an `Applicative` supertrait. Following Lean, `Seq` takes a thunked second operand and `Alternative` extends `Applicative` with `failure` and thunked `orElse`; the earlier eager `Apply` sketch is superseded. `Debug` and `Default` still need concrete operation contracts before freezing their interfaces. The earlier `Fail`/`OrElse` sketches are not additional v0 commitments.

This inventory defines proposed v0 library scope, not a blanket Prelude export list. `Data.Map` is outside Prelude and outside this initial inventory; its release availability remains open. `System.Environment`, exceptions, and concurrency are outside the proposed v0 scope. `Data.Ordering` is included because the current `Ord.compare` contract returns `Ordering`. The naming choice between `Result` and `Either` remains open; existing examples and the current entry-point contract still use `Result`. Numeric traits (`Add`, `Sub`, `Mul`, `Div`, `Rem`) and the existing `Void`/`absurd` bootstrap must be reconciled with this inventory before freezing it; their current contracts are not silently removed.

## 2. Basic data types

```text
type Maybe a =
    Nothing
    Just a

type Result e a =
    Err e
    Ok a

type Ordering =
    Less
    Equal
    Greater
```

`Bool`, `Unit`, products, and lists are built in and are not redeclared by Prelude.

The initial Prelude also re-exports the empty type `Void` and its eliminator `absurd : Void -> a`. Until empty data declarations and empty matching are supported, an explicit builtin-backed module supplies:

```text
{-# BUILTIN VOID Void #-}
Void : Type

{-# BUILTIN ABSURD absurd #-}
absurd : Void -> a
```

`Void` has no values; `absurd` eliminates an impossible value. These are library declarations, not additional reserved primitive types.

In v1+, empty type bodies and empty matching replace those builtin bindings with ordinary source definitions:

```text
type Void = {}

absurd : Void -> a
absurd x = with x {}
```

Empty records and empty ADTs share the form `type T = {}`. The empty body declares an uninhabited type and introduces no constructor, so `Void with {}` is invalid. The Prelude API stays the same.

The byte and vector types are named `Byte` and `Vec a`, replacing `U8` and `Array a`. Their compiler-backed declarations live in explicit library modules.

## 3. Core functions

```text
id : a -> a
id x = x

const : a -> b -> a
const x _ = x

compose : (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)

flip : (a -> b -> c) -> b -> a -> c
flip f y x = f x y

apply : (a -> b) -> a -> b
apply f x = f x

pipe : a -> (a -> b) -> b
pipe x f = f x
```

Possible operator aliases:

```text
($) : (a -> b) -> a -> b
($) = apply

(|>) : a -> (a -> b) -> b
(|>) = pipe
```

`.` is not an operator name; it is reserved for module qualification and record projection. Composition uses the named function `compose`.

## 4. Equality, ordering, and display

```text
trait Eq a =
    (==) : a -> a -> Bool

trait Eq a => Ord a =
    compare : a -> a -> Ordering

trait Show a =
    show : a -> String
```

Derived operations are ordinary constrained top-level functions outside the traits. `Eq` instances implement `(==)` and `Ord` instances implement `compare`; they do not implement the derived functions or supply forwarding definitions:

```text
(/=) : Eq a => a -> a -> Bool
(/=) x y = not (x == y)

(<) : Ord a => a -> a -> Bool
(<) x y = with compare x y
    Less -> True
    _ -> False

(<=) : Ord a => a -> a -> Bool
(>) : Ord a => a -> a -> Bool
(>=) : Ord a => a -> a -> Bool

min : Ord a => a -> a -> a
max : Ord a => a -> a -> a
```

Initial implementations should include the primitive scalar types and structural lists and products where their components satisfy the required traits. Because no module owns the primitive types or `[]` and `(*)`, these implementations must be declared in the module that defines the corresponding trait.

In v0, string interpolation introduces a `Show a` requirement for each embedded bare or qualified variable. The `Show String` instance is the identity: `show s = s`, so interpolation does not add quotes around strings.

## 5. Numeric capabilities

Numeric operations remain fine-grained:

```text
trait Add a =
    (+) : a -> a -> a

trait Sub a =
    (-) : a -> a -> a

trait Mul a =
    (*) : a -> a -> a

trait Div a =
    (/) : a -> a -> a

trait Rem a =
    (%) : a -> a -> a
```

The compiler handles unary `-` directly for `Int` and `Float`. Binary numeric traits should initially have implementations for those two types where meaningful.

Conversions are explicit:

```text
intToFloat : Int -> Float
floatToInt : Float -> Int
```

The rounding and overflow behavior of conversions must be specified before stabilization.

## 6. Fine-grained control traits

### Mapping

```text
trait Functor f =
    map : (a -> b) -> f a -> f b
```

`Functor` is the minimum requirement for transforming an existing context.

### Injection

```text
trait Pure f =
    pure : a -> f a
```

`Pure` injects a value without implying mapping, application, or sequencing.

### Contextual application

```text
trait Seq f =
    seq : f (a -> b) -> (Unit -> f a) -> f b
```

An operator alias retains the explicit thunk argument:

```text
(<*>) : Seq f => f (a -> b) -> (Unit -> f a) -> f b
(<*>) = seq
```

Use `seq mf (_ -> mx)` or `mf <*> (_ -> mx)` to delay `mx`. These are ordinary calls: no parser or elaborator automatically wraps the second argument. Creating a thunk does not evaluate its body; invoking it evaluates the body using the ordinary strict semantics. The instance controls whether and how often it is invoked; there is no automatic memoization. For `Maybe`, a missing function skips the argument thunk.

### Dependent sequencing

```text
trait Bind f =
    bind : f a -> (a -> f b) -> f b
```

`do` notation requires only `Bind` for sequencing. It does not require a combined `Monad` trait.

```text
(>>=) : Bind f => f a -> (a -> f b) -> f b
(>>=) = bind
```

### Composite traits

```text
trait (Functor f, Pure f, Seq f) => Applicative f = {}

trait (Applicative f, Bind f) => Monad f = {}
```

These marker traits add no operations. They provide conventional vocabulary and bundle the fine-grained capabilities through supertrait dictionaries. Code should still request `Functor`, `Pure`, `Seq`, or `Bind` when that is all it needs.

### Choice

Following [Lean's Alternative definition](https://github.com/leanprover/lean4/blob/master/src/Init/Control/Basic.lean), use:

```text
trait Applicative f => Alternative f =
    failure : f a
    orElse : f a -> (Unit -> f a) -> f a

(<|>) : Alternative f => f a -> (Unit -> f a) -> f a
(<|>) = orElse
```

For `Maybe`, `failure` is `Nothing`; `orElse` returns a `Just` left operand without invoking the right thunk, otherwise it invokes the thunk. Other instances must specify whether choice collects results or selects a success. The earlier `Fail` and standalone `OrElse` sketches are not selected as separate v0 traits. Refutable `do` binds remain rejected in v0, independently of library choice operations.

### Sequencing helpers

[Lean's Applicative hierarchy](https://github.com/leanprover/lean4/blob/master/src/Init/Prelude.lean) additionally separates `SeqLeft` and `SeqRight`. For the initial Ficus scope, provide their operations as ordinary derived functions rather than adding required trait members or default implementations:

```text
seqLeft : (Functor f, Seq f) => f a -> (Unit -> f b) -> f a
seqLeft x next = seq (map (a -> _ -> a) x) next

seqRight : (Functor f, Seq f) => f a -> (Unit -> f b) -> f b
seqRight x next = seq (map (_ -> b -> b) x) next
```

Separate optimized `SeqLeft`/`SeqRight` traits can be considered later. Unlike Lean's default class methods, all Ficus trait members still require explicit implementations; helpers remain outside dictionaries. No proof-oriented `Lawful*` classes or dependent types are introduced by using Lean as an API reference.

### Why these traits stay separate

A function that only maps should require `Functor f`, not `Monad f`. A parser may support `Pure`, `Seq`, and choice without supporting dependent sequencing. Keeping these capabilities separate avoids unnecessary instances and constraints.

## 7. Initial control instances

The proposed initial types for `Functor`, `Pure`, `Seq`, `Bind`, `Applicative`, and `Monad` implementations are `Maybe`, `Result e`, and `[]`. The `Result`/`Either` naming decision remains open. `Alternative Maybe` uses the short-circuiting contract above; list choice and any error-bearing choice implementation still need reviewed contracts.

The exact behavior of list `Seq` must be chosen explicitly. Cartesian application and zip application are different semantics; a zip variant should use a distinct wrapper type if Cartesian application is selected.

## 8. Maybe and Result helpers

```text
maybe : b -> (a -> b) -> Maybe a -> b
result : (e -> c) -> (a -> c) -> Result e a -> c

isJust : Maybe a -> Bool
isNothing : Maybe a -> Bool

fromMaybe : a -> Maybe a -> a
mapError : (e -> f) -> Result e a -> Result f a

toResult : e -> Maybe a -> Result e a
toMaybe : Result e a -> Maybe a
```

## 9. Boolean functions

```text
not : Bool -> Bool
and : Bool -> Bool -> Bool
or : Bool -> Bool -> Bool
```

Because function arguments are strict, `and` and `or` initially evaluate both arguments. Short-circuiting control flow should use `if`.

Lazy arrows are deferred to v2+. Their reserved syntax is `~>`, replacing the earlier prefix-`~` proposal:

```text
and : Bool ~> Bool ~> Bool
or : Bool ~> Bool ~> Bool
```

Once supported, these signatures can provide short-circuiting without exposing explicit thunks. Lazy arguments use call-by-name without memoization: each demand evaluates again, and unused arguments are skipped. Lazy and strict arrows are distinct types with no subtyping or implicit coercion.

## 10. List functions

`map` comes from the list `Functor` implementation, whose head uses the built-in list type constructor directly:

```text
impl Functor [] =
    map f xs = with xs
        [] -> []
        x :: rest -> f x :: map f rest
```

Other list functions include:

```text
filter : (a -> Bool) -> [a] -> [a]

foldl : (b -> a -> b) -> b -> [a] -> b

length : [a] -> Int
reverse : [a] -> [a]
concat : [[a]] -> [a]

head : [a] -> Maybe a
tail : [a] -> Maybe [a]
last : [a] -> Maybe a

take : Int -> [a] -> [a]
drop : Int -> [a] -> [a]
zip : [a] -> [b] -> [a * b]
```

Partial list operations that raise runtime errors are intentionally omitted.

`foldr` comes from the list `Foldable` implementation, and associative append comes from its `Semigroup` implementation.

## 11. Strings and characters

```text
stringLength : String -> Int
stringAppend : String -> String -> String
stringToChars : String -> [Char]
charsToString : [Char] -> String
```

## 12. Semigroup and Monoid

Associative combination and identity use conventional traits:

```text
trait Semigroup a =
    append : a -> a -> a

trait Semigroup a => Monoid a =
    empty : a
```

```text
(<>) : Semigroup a => a -> a -> a
(<>) = append
```

Expected implementations include `Semigroup [a]`, `Monoid [a]`, `Semigroup String`, and `Monoid String`. List and string `(++)` may remain specialized aliases when clearer.

The associativity and identity laws are library contracts; the compiler does not prove them. Derived operations are ordinary constrained top-level functions outside trait dictionaries; traits never provide default member implementations.

## 13. Foldable and Traversable

```text
trait Foldable t =
    foldr : (a -> b -> b) -> b -> t a -> b

trait (Functor t, Foldable t) => Traversable t =
    traverse : Applicative f => (a -> f b) -> t a -> f (t b)
```

The `Applicative f` predicate belongs to the `traverse` method signature. It constrains the method-level variable `f`, not the trait parameter `t`.

Derived functions include:

```text
foldMap : (Foldable t, Monoid m) => (a -> m) -> t a -> m
sequence : (Traversable t, Applicative f) => t (f a) -> f (t a)
```

Initial instances should cover lists and `Maybe`; `Result e` should be `Traversable` in its successful value parameter.

## 14. IO-facing functions

Ficus is impure, so basic IO functions return `Unit` rather than an `IO` action:

```text
print : String -> Unit
println : String -> Unit
readLine : Unit -> String
```

Opaque handles, `Vec a`, `Byte`, and low-level operations live in explicit library modules backed by `BUILTIN` declarations. They are not automatically re-exported by Prelude.

The same applies to the proposed initial v2+ fibers and channels: `Fiber`, `Chan`, `fork`, `join`, `newChan`, `send`, and `recv` belong in an explicit builtin-backed concurrency module, not Prelude.

The initial v1+ Prelude provides the marker:

```text
trait Exception e = {}
```

The corresponding `throw` and `catch` operations are builtin-backed explicit imports:

```text
throw : Exception e => e -> a
catch : Exception e => (Unit -> a) -> (e -> a) -> a
```

`Exception` has no source-level methods, but typed `catch` requires a runtime nominal type identity. Whether that identity lives in exception evidence or another runtime representation remains open; it cannot simply be erased to unit. The trait does not make exception effects implicit in unrelated Prelude functions.

The settled v1+ mutable-reference API likewise belongs to an explicit builtin-backed module:

```text
newRef : a -> Ref a
modifyRef : Ref a -> (a -> a) -> Unit
readRef : Ref a -> a
```

They use the v0 value restriction and are not re-exported by Prelude.

## 15. Open decisions

Before stabilization, decide:

- whether `Apply` should be named `Seq` to match Lean more closely;
- whether `Fail` should carry `String` or use a separate error type;
- integer division, out-of-range literals, floating-point display, and numeric conversions;
- the minimum instances imported by default.
