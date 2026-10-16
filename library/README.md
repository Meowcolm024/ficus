# Early-development library

`Prelude.ficus` is a placeholder copied from
`test/fixtures/support/Prelude.ficus`. It provides the minimal declarations used
by the current frontend, including `Bind`, `Show`, and `stringAppend`. It is not
the complete standard library, and its API and layout are subject to change.

The package bundles this directory as data files. `ficus compile` searches it by
default; `--library DIR` replaces the default library search root, and
`--prelude FILE` overrides the source of the canonical Prelude module. These
options are for early development and are subject to change.
