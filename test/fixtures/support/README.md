# Shared mini Prelude for fixtures

Prelude.ficus is the single shared fixture library. It deliberately defines its
members directly; it may later become a selective re-export module without
changing client fixtures. It is test support, not a freeze of the production
Prelude API or standard-library module layout. Its NO_IMPLICIT_PRELUDE header
avoids importing itself, and its implementation uses ordinary calls/matches,
never do notation or interpolation.

Included scope: Int arithmetic, Eq/Ord and comparisons, strict Boolean helpers,
String concatenation/equality/length, Show for Int/Bool/String/Unit/Maybe, Maybe
constructors and helpers, Bind/Pure/Functor for Maybe, and explicitly quantified
id/const. Reserved primitive types, Type, True/False, list constructors, and unit
come from the compiler's intrinsic environment and are not redeclared here.

Default source roots for semantic fixture providers:

- name-resolution: case directory (positive/negative), local support/, and
  ../../support relative to name-resolution/.
- type-checking: case directory and ../../support relative to type-checking/.
- desugaring/pattern-lambdas: case directory and ../../support.
- other direct fixture families: case directory and ../support.

Load the same Prelude module once by canonical identity. Do not copy its source
into each project or substitute a separate dummy library. Isolated module-graph
cases explicitly override this configuration: their malformed/bootstrap Prelude
files are graph inputs, and missing-Prelude projects must have no shared fallback.

The future fixture primitive registry must recognize exactly these keys/contracts
for this library; unknown keys elsewhere remain errors:

| Keys | Ordinary target signature |
| --- | --- |
| INT_ADD, INT_SUB, INT_MUL, INT_DIV, INT_REM | Int -> Int -> Int |
| INT_EQ, INT_LT | Int -> Int -> Bool |
| INT_SHOW | Int -> String |
| STRING_APPEND | String -> String -> String |
| STRING_EQ | String -> String -> Bool |
| STRING_LENGTH | String -> Int |

Register sugar identities by declaration ownership: the bind method of trait
Prelude.Bind, the show method of Prelude.Show, and Prelude.stringAppend for interpolation
concatenation. These are fixture contracts for the injected registry; the full production primitive API remains separate. STRING_APPEND supplies
stringAppend; (++) is an ordinary wrapper.
Targets keep their normal Prelude defining identity; BUILTIN keys are metadata.
Show String returns its input without quoting. Boolean combinators are strict
v0 functions; use if for short-circuiting. Integer implementations must preserve
specified 64-bit wrapping; division/remainder edge cases follow the eventual
primitive contracts. Length smoke assertions use ASCII pending a precise Unicode
length contract. No production builtin implementations are added by this file.

MiniPrelude.ficus in semantics/type-checking/positive is the future inference and
runtime smoke input. Expected examples: arithmetic() = 5, negation() = -2, quotient() = 4,
remainder() = 2, boolean() = True, stringOps() = "ab", stringSize() = 3,
interpolation 7 = "value=7", stringInterpolation "hello" = "text=hello",
maybeProgram() = Just 2, maybeFailure() = Nothing, pairProgram() = Just 3,
maybeFallback() = 0, maybeEquality() = True, maybeDisplay() = "Just (1)",
and explicitType() = 1. These are authored assertions, not executed results.

The current parser suite includes Prelude.ficus as a parser-acceptance case.
Resolution, class evidence, primitive execution, and sugar evaluation still need
the upcoming stages; parsing alone does not establish that this library checks
or executes. No parser/build/test execution is claimed by this inventory.
