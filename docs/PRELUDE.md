# Intended Prelude

This document sketches a small v0 Prelude. It is non-normative and intentionally incomplete. v1+ expands it in the style of Haskell and adds JSON and regex facilities, potentially backed by `MAGIC` modules. The expanded APIs, module organization, and implicit re-export policy remain to be specified.

The control hierarchy follows Lean's fine-grained approach: operations such as `map`, `pure`, application, and `bind` have separate traits. Conventional `Applicative` and `Monad` names remain available as composite marker traits.

## 1. Organization

The implicit `Prelude` module may re-export smaller modules:

```text
use Prelude.Core (..) pub
use Prelude.Control (..) pub
use Prelude.Numeric (..) pub
use Prelude.List (..) pub
use Prelude.String (..) pub
```

Modules marked `NO_IMPLICIT_PRELUDE` or `MAGIC` receive none of these declarations. The reserved types `Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` remain available.

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

The initial Prelude also re-exports the empty type `Void` and its eliminator `absurd : Void -> a`. Until empty data declarations and empty matching are supported, an explicit `MAGIC` module supplies:

```text
Void : Type
Void = magic "void"

absurd : Void -> a
absurd = magic "absurd"
```

`Void` has no values; `absurd` eliminates an impossible value. These are library declarations, not additional reserved primitive types.

In v1+, empty type bodies and empty matching replace those magic bindings with ordinary source definitions:

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

In v0, string interpolation introduces a `Show a` requirement for each embedded variable.

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
trait Apply f =
    ap : f (a -> b) -> f a -> f b
```

Useful aliases can remain ordinary functions:

```text
(<*>) : Apply f => f (a -> b) -> f a -> f b
(<*>) = ap
```

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
trait (Functor f, Pure f, Apply f) => Applicative f = {}

trait (Applicative f, Bind f) => Monad f = {}
```

These marker traits add no operations. They provide conventional vocabulary and bundle the fine-grained capabilities through supertrait dictionaries. Code should still request `Functor`, `Pure`, `Apply`, or `Bind` when that is all it needs.

### Failure and choice

```text
trait Fail f =
    fail : String -> f a

trait OrElse f =
    orElse : f a -> (() -> f a) -> f a
```

The second `orElse` argument is delayed because Ficus is strict. Refutable patterns in `do` require an appropriate `Fail` operation.

### Why these traits stay separate

A function that only maps should require `Functor f`, not `Monad f`. A parser may support `Pure`, `Apply`, and `OrElse` without supporting dependent sequencing. Keeping these capabilities separate avoids unnecessary instances and constraints.

## 7. Initial control instances

The intended minimum instance matrix is:

| Type | Functor | Pure | Apply | Bind | Applicative | Monad | Fail | OrElse |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `Maybe` | yes | yes | yes | yes | yes | yes | yes | yes |
| `Result e` | yes | yes | yes | yes | yes | yes | no | no |
| `[]` | yes | yes | yes | yes | yes | yes | no | yes |

`Maybe.fail` discards the message and returns `Nothing`. List `orElse` uses its second argument only when the first list is empty.

The exact behavior of list `Apply` must be chosen explicitly. A Cartesian implementation is conventional; a zip implementation should instead use a distinct wrapper type.

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

Lazy arrows are deferred. Their reserved syntax is `~>`, replacing the earlier prefix-`~` proposal:

```text
and : Bool ~> Bool ~> Bool
or : Bool ~> Bool ~> Bool
```

Once supported, these signatures can provide short-circuiting without exposing explicit thunks.

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

Opaque handles, `Vec a`, `Byte`, and low-level operations live in explicit library modules backed by `MAGIC` declarations. They are not automatically re-exported by Prelude.

The same applies to the finalized initial v1+ fibers and channels: `Fiber`, `Chan`, `fork`, `join`, `newChan`, `send`, and `recv` belong in an explicit magic-backed concurrency module, not Prelude.

The initial v1+ Prelude provides the marker:

```text
trait Exception e = {}
```

The corresponding `throw` and `catch` operations are magic-backed explicit imports:

```text
throw : Exception e => e -> a
catch : Exception e => (Unit -> a) -> (e -> a) -> a
```

`Exception` is a memberless proof trait. Its unit dictionary may be erased after checking; magic lowering supplies any required runtime type token separately. It does not make exception effects implicit in unrelated Prelude functions.

The settled v1+ mutable-reference API likewise belongs to an explicit magic-backed module:

```text
newRef : a -> Ref a
modifyRef : Ref a -> (a -> a) -> Unit
readRef : Ref a -> a
```

They require an ML-style value restriction and are not re-exported by Prelude.

## 15. Open decisions

Before stabilization, decide:

- whether `Apply` should be named `Seq` to match Lean more closely;
- whether `Fail` should carry `String` or use a separate error type;
- exact numeric overflow and conversion behavior;
- the minimum instances imported by default.
