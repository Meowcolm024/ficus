# v0 examples

- `Main.ficus`: implicit Prelude, a total list lookup, debug strings, and IO.
- `Interpolation.ficus`: variable and qualified-name interpolation, computed
  values, and literal braces.
- `Collections.ficus`: qualified data imports, list mapping/filtering, safe
  defaults, and zip.
- `Control.ficus`: Maybe application and choice with explicit thunks, `<*`/`*>`,
  composition operators, `do` sequencing, and Result traversal.
- `Builtins.ficus`: explicit Byte/Vec imports, direct compiler-key operations,
  and standard handle reads/writes.
- `Exceptions.ficus`: the v1 typed exception API, an explicit nominal instance,
  and recovery through a matching handler.
- `Fibonacci.ficus`: recursive calls and branches with deliberately repeated work.
- `Primes.ficus`: integer division, remainder, branching, and bounded accumulation.
- `MergeSort.ficus`: deterministic data generation, list allocation, and recursive
  divide-and-conquer sorting.

Check all examples from the repository root:

```sh
stack exec ficus -- compile --library library examples/Main.ficus examples/Interpolation.ficus examples/Collections.ficus examples/Control.ficus examples/Builtins.ficus examples/Fibonacci.ficus examples/Primes.ficus examples/MergeSort.ficus
```

Compilation validates typed Core. The compile command does not execute `main`.

Run the interpolation example with an optional greeting name:

```sh
stack exec ficus -- run examples/Interpolation.ficus -- Ada
```

```text
Hello, Ada!
Argument count: 1
Hello, Ada! Argument count: 1
Qualified value: ()
Literal braces: {name} and {name}
Braces around a value: {Ada}
```

## Mini benchmarks

Each of the three new examples exposes `benchmark : Unit -> ...` and prints one
final result from `main`. Work happens when the function is called, rather than
at module initialization. Inputs are deterministic; command-line arguments are
ignored. Adjust the fixed argument in `benchmark ()` to tune the workload.

| Example | Default workload | Expected output | Integer bounds |
| --- | --- | --- | --- |
| Fibonacci | Naive recursive `fibonacci 24` | `46368` | Input clamped to 0–30; largest result is 832040. |
| Primes | Trial division through 10000 | `(1229, 5736396)` | Limit clamped to 0–20000; total stays below 400000000. Divisibility checks use `n / divisor` rather than squaring the divisor. |
| MergeSort | Sort 2048 generated integers | `(2048, 91749716217)` | At most 4096 values, each below 65521; generation intermediates are at most 16445537 and the weighted checksum at most 549755781120. |

All documented workloads stay well within signed 64-bit `Int`. Fibonacci is
intentionally exponential, so raising its input increases time sharply.

Run them from the repository root:

```sh
stack exec ficus -- run examples/Fibonacci.ficus --library library
stack exec ficus -- run examples/Primes.ficus --library library
stack exec ficus -- run examples/MergeSort.ficus --library library
```

For a rough end-to-end measurement, prefix a command with `time`. This includes
process startup, parsing, type checking, lowering, and printing. Use identical
inputs and repeat runs when comparing implementations. The default results were
checked through both the compiled and direct evaluators.
