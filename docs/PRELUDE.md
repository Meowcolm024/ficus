# v0 Prelude

This document describes the bundled v0 Prelude and standard library. It is non-normative; SPEC.md defines language and builtin contracts. The organization follows the small implicit surface of [Haskell Prelude](https://www.haskell.org/onlinereport/modules.html#sect5.6) and the separation between builtin bindings and public data modules in [Agda Data.Nat.Base](https://agda.github.io/agda-stdlib/master/Data.Nat.Base.html). v1+ may add JSON and regex facilities through explicit modules.

The control hierarchy follows Lean's fine-grained approach: operations such as `map`, `pure`, application, and `bind` have separate traits. Conventional `Applicative` and `Monad` names remain available as composite marker traits.

## 1. Organization

The public layout is:

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

Indented entries denote modules such as `Ficus.Builtin.Int` and `Class.Show`. Ellipses and the Map and Environment examples indicate future extensions, not shipped modules. `System.IO` names an operations module; it does not introduce an `IO` type.

`Ficus.Builtin.*` holds declarations backed by `BUILTIN` and their minimal support definitions. These modules are preferably self-contained, but imports from other library modules are permitted when the dependency graph remains acyclic. The six reserved primitive types are already in scope and are not redeclared there. Ordinary library types such as `Handle`, `Byte`, and `Vec` retain their defining module identity. Public operations and wrappers may be exposed through `Data.*`, `System.*`, or `Control.*` without changing that identity.

`Class.*` defines the basic traits and associated constrained functions. Under the existing ownership rule, implementations for primitive types and built-in list/product/function constructors must live in the module defining the trait: for example, `Show Int` belongs in `Class.Show`. Implementations for ordinary library types may instead live with their type. Keep this distinction when selecting module dependencies.

The bootstrap policy is to put `{-# NO_IMPLICIT_PRELUDE #-}` before imports in every standard-library module, including `Prelude` itself. All library dependencies are then explicit; application modules retain implicit Prelude unless they opt out. This avoids an accidental dependency back to Prelude when an internal module is added or moved into its dependency graph. Bootstrap from builtin declarations and basic data definitions, then build traits and higher-level operations according to their actual dependencies, with Prelude last. Basic types such as Ordering may be needed by trait contracts, so the module roots are not strict dependency layers. Keep constructor-only data dependencies independent of trait modules where needed; place implementations according to ownership without introducing imports back into their dependencies. Actual dependencies must remain acyclic. `BUILTIN` alone does not disable implicit Prelude. Primitive-named modules may be imported directly, for example `use Ficus.Builtin.Int`; a distinct alias such as `as BInt` is optional. It may coexist with `use Data.Int` under the same local qualifier; ordinary use-site ambiguity rules apply. Under the current v0 rules, disabling implicit Prelude also forbids `do` and string interpolation even when their supporting definitions are imported explicitly; standard-library bootstrap code uses ordinary function calls instead. Changing that sugar rule would require a separate spec revision.

Prelude uses explicit selective re-exports. The complete implicit API is reviewed
in `library/Prelude.ficus`; adding a source definition does not expand it. The
selected exports are:

| Modules | Selected API |
| --- | --- |
| `Class.Eq`, `.Ord`, `.Show`, `.Debug`, `.Default` | All five traits, `==`, `/=`, comparison operators, `compare`, `min`, `max`, `show`, `debug`, `default` |
| `Class.Add`, `.Sub`, `.Mul`, `.Div`, `.Rem` | Numeric traits and their binary operators |
| `Class.Functor`, `.Pure`, `.Seq`, `.Bind`, `.Applicative`, `.Monad`, `.Alternative` | Traits, `map`, `pure`, `seq`, `bind`, `failure`, `orElse`, `<*>`, `<*`, `*>`, `>>=`, `<\|>`, `seqLeft`, `seqRight` |
| `Class.Semigroup`, `.Monoid`, `.Bifunctor`, `.Foldable`, `.Traversable` | Traits, `append`, `<>`, `empty`, `bimap`, `foldr`, `foldMap`, `traverse`, `sequence` |
| `Data.Function`, `.Bool`, `.Product` | Functions listed in Sections 3 and 9, `<<`, `>>`, `\|>`, `&&`, `||`, `fst`, `snd`, `curry`, `uncurry`, `swap` |
| `Data.Ordering`, `.Maybe`, `.Result`, `.Const`, `.Void` | Types and public constructors, Maybe/Result helpers, `getConst`, `absurd` |
| `Data.List` | Total list operations in Section 10 |
| `Data.String`, `.Int`, `.Float` | `stringLength`, `stringAppend`, `stringToChars`, `charsToString`, `++`, `intToFloat`, `floatToInt`, `negate : Int -> Int` |
| `System.IO` | `print`, `println`, `readLine` |

`Handle`, `Byte`, `Vec`, scalar primitive entry points such as `intEq`, and
specialized collections require explicit imports. Implementations are owned by
the defining trait module for compiler-owned types and by the defining type
module for ordinary data. The implicit import exposes the selected traits/types
and their reachable implementations under the normal instance-visibility rules.

Modules marked `NO_IMPLICIT_PRELUDE` receive none of these declarations. The reserved types `Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` remain available.

### v0 scope

| Area | Modules or traits |
| --- | --- |
| Builtin-backed declarations | `Ficus.Builtin.Int`, `.Float`, `.Char`, `.String`, `.Handle`, `.Vec`, `.Byte`; `.Bool` and `.Unit` document compiler-reserved declarations without imports or new keys |
| Basic classes | `Add`, `Sub`, `Mul`, `Div`, `Rem`, `Debug`, `Show`, `Eq`, `Ord`, `Pure`, `Seq`, `Bind`, `Functor`, `Applicative`, `Monad`, `Alternative`, `Semigroup`, `Monoid`, `Default`, `Bifunctor`, `Foldable`, `Traversable`, each under `Class` |
| System | `System.IO` |
| Data | `Data.List`, `.Function`, `.Product`, `.Ordering`, `.Maybe`, `.Result`, `.Const`, `.Int`, `.Float`, `.Bool`, `.Char`, `.String`, `.Unit`, `.Vec`, `.Byte`, `.Void`; `.Ref` is an implemented v1 extension |
| Control | No v0 modules; v1 adds Control.Exception, concurrency remains later work |

`Handle` stays out of the `Data` layer; its public IO operations belong in `System.IO`. Primitive data modules expose operations on the already-reserved types rather than defining replacement types. `Data.Const` denotes the constant type constructor, distinct from the ordinary `const` function in `Data.Function`.

The composites are `Applicative = Functor + Pure + Seq` and `Monad = Applicative + Bind`. `Functor` remains independently usable and is also an `Applicative` supertrait. Following Lean, `Seq` takes a thunked second operand and `Alternative` extends `Applicative` with `failure` and thunked `orElse`; the earlier eager `Apply` sketch is superseded. `Debug.debug : a -> String` renders diagnostic output (quoting and escaping characters/strings); `Show String` stays the identity. `Default.default : a` provides a conventional initial value. Scalar defaults are zero, false, space, the empty string, and unit; lists and Maybe default to empty/Nothing, and Result defaults to `Ok default`. The earlier `Fail`/`OrElse` sketches are not additional v0 commitments.

The inventory defines v0 scope, while the selective table defines the implicit
API. `Data.Map`, `System.Environment`, and concurrency are later work; typed
exceptions are an implemented v1 extension.
`Data.Ordering` supports `Ord.compare`. `Result` is retained for compatibility
with the entry-point contract. The numeric traits and source-defined `Void` remain
part of the library. `Data.Const` defines a separate `Const a b` type constructor.

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

Prelude re-exports the empty type `Void` and its eliminator from `Data.Void`, defined entirely in source:

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

Composition and pipe operators (there is no `$` alias):

```text
(<<) : (b -> c) -> (a -> b) -> a -> c
(<<) f g x = compose f g x

(>>) : (a -> b) -> (b -> c) -> a -> c
(>>) f g x = compose g f x

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

Initial implementations include the primitive scalar types and structural lists and products where their components satisfy the required traits. Because no module owns the primitive types or `[]` and `(*)`, these implementations must be declared in the module that defines the corresponding trait.

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

The compiler handles unary `-` directly for `Int` and `Float`. `Add`, `Sub`, `Mul`, and `Div` have Int and Float implementations; `Rem` has an Int implementation. `Ord Float` places NaNs last and compares them as Equal, while Eq retains IEEE equality.

Conversions are explicit:

```text
intToFloat : Int -> Float
floatToInt : Float -> Int
```

`intToFloat` rounds to nearest, ties to even. `floatToInt` truncates toward zero and fails for non-finite or out-of-range results. Integer arithmetic wraps; division truncates toward zero and remainder has the dividend’s sign. Division by zero fails; see SPEC.md Section 19 for the complete primitive contracts.

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

The operator aliases preserve the explicit thunk:

```text
(<*) : (Functor f, Seq f) => f a -> (Unit -> f b) -> f a
(<*) value next = seqLeft value next

(*>) : (Functor f, Seq f) => f a -> (Unit -> f b) -> f b
(*>) value next = seqRight value next
```

Separate optimized `SeqLeft`/`SeqRight` traits can be considered later. Unlike Lean's default class methods, all Ficus trait members still require explicit implementations; helpers remain outside dictionaries. No proof-oriented `Lawful*` classes or dependent types are introduced by using Lean as an API reference.

### Why these traits stay separate

A function that only maps should require `Functor f`, not `Monad f`. A parser may support `Pure`, `Seq`, and choice without supporting dependent sequencing. Keeping these capabilities separate avoids unnecessary instances and constraints.

## 7. Initial control instances

The initial types for `Functor`, `Pure`, `Seq`, `Bind`, `Applicative`, and `Monad`
are `Maybe`, `Result e`, and `[]`. `Alternative Maybe` selects the first success;
`Alternative []` concatenates and invokes its right thunk exactly once. There is
no `Alternative (Result e)` instance.

List `Seq` is Cartesian in function-major order. An empty function list skips the
argument thunk. A nonempty function list invokes it exactly once and reuses the
result for every function. A future zip application API needs a distinct wrapper.
`Maybe` and `Result` skip the argument thunk on Nothing/Err. Traversal visits
left-to-right and skips later work after a missing/error result.

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

These strict-arrow signatures make `and` and `or` evaluate both arguments. Short-circuiting control flow should use `if`.

The implemented v2+ lazy-arrow syntax is `~>`, replacing the earlier prefix-`~` proposal. User-defined functions can use these signatures:

```text
and : Bool ~> Bool ~> Bool
or : Bool ~> Bool ~> Bool
```

These signatures provide short-circuiting without exposing explicit thunks; the library exports above retain their strict types. Lazy arguments use call-by-name without memoization: each demand evaluates again, and unused arguments are skipped. Lazy and strict arrows are distinct types with no subtyping or implicit coercion.

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

Implementations include `Semigroup [a]`, `Monoid [a]`, `Semigroup String`, and `Monoid String`. `(++)` is the specialized string alias; lists use `append` or `(<>)`.

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

Instances cover lists, `Maybe`, and the successful value parameter of `Result e`.

## 14. IO-facing functions

Ficus is impure, so basic IO functions return `Unit` rather than an `IO` action:

```text
print : String -> Unit
println : String -> Unit
readLine : Unit -> String
```

These functions are ordinary source definitions in `System.IO`. Its explicit
handle API re-exports the compiler-key bindings from `Ficus.Builtin.Handle`:

```text
stdin : Handle
stdout : Handle
stderr : Handle
read : Handle -> Int -> String
write : Handle -> String -> Unit
```

`read` consumes at most the requested number of Unicode code points, including
line terminators. Non-positive counts skip IO; EOF produces the empty string.
`write` adds no newline. Standard input is readable; standard output and error
are writable. Invalid directions and host IO errors throw typed `IOError` values. Standard
handle values do not perform effects during initialization. The v0 API has no close operation; the v1 extension below adds file handles. `print` and `println` use `write stdout`; `readLine ()` uses
`readLineFrom stdin`, where `readLineFrom : Handle -> String` is a source helper
that removes LF/CRLF and preserves an unterminated final line.

Opaque handles, `Vec a`, `Byte`, and low-level operations require explicit imports
and are not automatically re-exported by Prelude. There is no longer a separate
`Ficus.Builtin.IO` module or primitive print/println/readLine key.

The same applies to the proposed initial v2+ fibers and channels: `Fiber`, `Chan`, `fork`, `join`, `newChan`, `send`, and `recv` belong in an explicit builtin-backed concurrency module, not Prelude.


The v1 `System.IO` extension also exports `openFile : String -> IOMode -> Handle`,
`close : Handle -> Unit`, and `IOMode(..)` with `ReadMode`, `WriteMode`,
`AppendMode`, and `ReadWriteMode`. The ADT and primitive constructor associations
live in `Ficus.Builtin.IOMode`; handle primitives import it explicitly. Files use
UTF-8 and preserve line endings. Closing flushes the file; subsequent operations
through aliases fail with `IOError`. Closing a standard stream is rejected.
These names require explicit imports and are not added to Prelude.

The implemented v1 extension re-exports the marker through `Class.Exception`:

```text
trait Exception e = {}
```

The corresponding `throw` and `catch` operations are builtin-backed explicit imports:

```text
throw : Exception e => e -> a
catch : Exception e => (Unit -> a) -> (e -> a) -> a
```

`Ficus.Builtin.Exception` defines the marker, standard primitive/list/product
instances, and operations without importing other library modules.
`Class.Exception` re-exports the marker; `Control.Exception` re-exports the marker
and operations, plus `ArithmeticError(..)`, `IOError(..)`, and `MatchError(..)` from
`Ficus.Builtin.Errors`. The error types and their primitive constructors are
ordinary source definitions with compiler-key associations. Integer zero division
and remainder, invalid float-to-int conversions, and handle/host IO failures throw
these catchable errors; failed patterns and unmatched conditionals throw
`MatchError message`. Dictionaries retain nominal tokens even when payload wrappers
are erased. Parameterized user instances explicitly require component exception
evidence, including phantom arguments. Catches are dynamically scoped, match only
exact types, and leave generic runtime errors untouched. No cleanup combinators
are provided yet; see SPEC §24.3 for effects and uncaught-exception behavior.

The implemented v1 mutable-reference API lives in `Ficus.Builtin.Ref` and is
selectively re-exported by `Data.Ref`:

```text
use Data.Ref (Ref, newRef, readRef, modifyRef)

newRef : a -> Ref a
modifyRef : Ref a -> (a -> a) -> Unit
readRef : Ref a -> a
```

The compiler keys are `REF`, `REF_NEW`, `REF_MODIFY`, and `REF_READ`. Allocation
creates a fresh cell; aliases share it. Modification reads, calls the updater
once, and writes only after it returns successfully. Updater effects are not
rolled back on failure, and the operation has no atomicity guarantee.

The existing value restriction applies without exceptions: allocated cells stay
monomorphic, captured cells do not become polymorphic through a lambda, explicit
signatures cannot generalize allocations, and unresolved weak types are errors.
Fresh factories such as `make () = newRef []` can be polymorphic.

`Class.Debug` supplies `Debug a => Debug (Ref a)` and renders the current contents
as `Ref (...)`, reading the cell once. This placement satisfies instance
ownership and avoids an unnecessary builtin dependency on the Debug trait.
These declarations require explicit imports and are not re-exported by Prelude.

## 15. Validation and later work

Every bundled module and representative clients pass module resolution,
inference, elaboration, and independent Core validation. Negative fixtures cover
scalar, nominal, and polymorphic builtin contract mismatches. The runtime API
executes the library through compiled closures and a direct interpreter used for differential tests. Derived IO is tested for output order,
Unicode input, EOF, and LF/CRLF handling. No primitive is replaced by a source
stub or hole.

Future work includes broader instances, specialized collections, JSON, regex,
exception cleanup APIs, and concurrency. These do not silently expand the implicit API.
