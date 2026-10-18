# v0 examples

- `Main.ficus`: implicit Prelude, a total list lookup, debug strings, and IO.
- `Collections.ficus`: qualified data imports, list mapping/filtering, safe
  defaults, and zip.
- `Control.ficus`: Maybe application and choice with explicit thunks, `do`
  sequencing, and Result traversal.
- `Builtins.ficus`: explicit Byte/Vec imports and direct compiler-key operations.

Check all examples from the repository root:

```sh
stack exec ficus -- compile --library library examples/Main.ficus examples/Collections.ficus examples/Control.ficus examples/Builtins.ficus
```

Compilation validates typed Core. The current compiler does not execute `main`.
