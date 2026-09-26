# Ficus trade-offs

Ficus is an opinionated, minimalist scripting language with global Hindley–Milner inference. These omissions keep that goal manageable; they are design choices, not claims that richer languages are inferior. [SPEC](SPEC.md) defines the actual rules.

## Restricted traits instead of general implicit search

Ficus chooses Haskell 98-ish, single-parameter traits over the wider machinery of [modern GHC type classes](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/instances.html), [Agda instance arguments](https://agda.readthedocs.io/en/stable/language/instance-arguments.html), or [Scala implicit resolution](https://docs.scala-lang.org/scala3/reference/changed-features/implicit-resolution.html). Restricted implementation heads, decreasing instance constraints, acyclic supertraits, and rejection of overlap make resolution terminating and deterministic for accepted programs. Ownership rules preserve coherence across modules. The aim is predictable inference and diagnostics without search priorities, backtracking heuristics, or results that depend on local implicit scope. This sacrifices expressive instance relationships and contextual customization; it does not imply that every richer system is undecidable or nondeterministic. [The Implicit Calculus: A New Foundation for Generic Programming](https://doi.org/10.1145/2345156.2254070) gives a formal model of implicit resolution, including higher-order rules and partial resolution. See the [Haskell 98 report's class and instance restrictions](https://www.haskell.org/onlinereport/decls.html).

## A small inference system instead of richer type relations

Ficus omits nominal, structural, and row-based subtyping, GADTs, and dependent types to preserve its simple global inference model. Subtyping needs inequality constraints and variance; [GADTs](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/gadt.html) introduce branch-local type equalities; dependent types require reasoning about terms inside types. Supporting these can require a different solver, more annotations, or restricted inference. Ficus still has nominal ADTs and structural products and lists; those do not imply subtyping.

There are also decidability limits: in full System F with bounded subtyping (`F_<:`), both subtyping and typing are undecidable. See Pierce's [Bounded Quantification Is Undecidable](https://doi.org/10.1006/inco.1994.1055). This result concerns that combination of subtyping and bounded polymorphism, not every subtyping system.

This is not a claim that subtyping rules out principal types: Boolean-algebraic types combine unions, intersections, and negation; carefully designed systems can retain principal inference. See [The Simple Essence of Boolean-Algebraic Subtyping](https://doi.org/10.1145/3776689). Ficus chooses the smaller solver and simpler inferred types instead.

## File modules instead of an ML module calculus

Ficus uses file-based modules and imports, without ML-style signatures, functors, or first-class modules (see [OCaml modules](https://ocaml.org/docs/modules) for a concrete example). Those features support powerful abstraction, but add another language of composition and checking. For simple scripts, ordinary functions, ADTs, and traits are the intended tools. Planned libraries and dependency resolution do not require an ML module calculus.

## Effects and proofs: knowing where to stop

I haven't seriously read any effects papers yet, so this is a scope decision, not a grand verdict on algebraic effects. Ficus uses strict evaluation and direct effects; if handlers are what you're after, try [Koka](https://koka-lang.github.io/koka/doc/book.html).

Ficus is also not intended to be a theorem prover. It wants to run your script, not defend your dissertation. For dependent types and proofs, please use [Lean](https://lean-lang.org/doc/reference/latest) or [Agda](https://agda.readthedocs.io/en/stable/) instead. Planned exceptions and mutable references do not turn Ficus into an algebraic effect system—or a proof assistant.

## Strict evaluation and the cost of recursion

Haskell's laziness makes infinite structures and tying recursive knots convenient, but it can also retain unevaluated work and the data that work refers to. Space leaks can make memory use difficult to predict; see [Space Improvements and Equivalences in a Functional Core Language](https://doi.org/10.4204/EPTCS.265.8). Ficus chooses strict, left-to-right evaluation so ordinary computation and effects happen when their expressions are evaluated. Strictness does not eliminate every space leak, and it can evaluate work that laziness would avoid.

The cost is less freedom in recursive value definitions. Ficus permits mutually recursive functions, but every reference within a recursive binding cycle must be protected by a lambda after parameter desugaring. Unrestricted cyclic values such as `ones = 1 :: ones` are rejected; delaying computation requires an explicit function. More permissive strict recursion needs initialization-safety analysis: [A Practical Mode System for Recursive Definitions](https://doi.org/10.1145/3434326) shows how call-by-value languages can safely admit more recursive definitions. Ficus deliberately uses the smaller restriction described in [SPEC](SPEC.md).
