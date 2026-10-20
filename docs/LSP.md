# Ficus language server

Start the server over standard input/output:

```sh
stack exec ficus -- lsp
stack exec ficus -- lsp --source-root src --library library
```

An installed `ficus` executable accepts the same `lsp` subcommand. Configure
your editor's language client to launch it for `.ficus` files, using language
identifier `ficus`. Standard output carries only LSP traffic. The server uses
Haskell's [`lsp` and `lsp-types`](https://github.com/haskell/lsp) libraries for
JSON-RPC, initialization, capability negotiation, document synchronization,
UTF-16 edits, and shutdown.

## Features

The [VS Code extension](../editors/vscode/README.md) starts the server
automatically for Ficus files. Configure `ficus.server.path` to select an
executable and `ficus.server.args` to customize its arguments (default: `["lsp"]`).
Changes to these settings restart the server.

| Method | Behavior |
| --- | --- |
| `textDocument/publishDiagnostics` | Parser, resolver, and type diagnostics, including stable codes, severities, related locations, and document versions |
| `textDocument/hover` | Inferred types for values, local binders, expressions, and record projections; kinds for type names |
| `textDocument/definition` | Canonical declarations across imports and aliases, local binders with shadowing, and nominal record fields |
| `textDocument/semanticTokens/full` | Resolved roles for names, declarations, constructors, parameters, and fields, combined with lexical strings, numbers, comments, keywords, and operators |

The server accepts full-document and incremental changes, including unsaved new
files. Opening, changing, saving, or closing a document rechecks the open files
and their dependency graph. Changes to an open dependency affect its importers
immediately. Closing a file removes its overlay: remaining importers use disk
contents. Diagnostics from previous snapshots are cleared, and a failed check
never supplies stale type information.

Interpolated strings use the editor's lexical highlighting for literal text,
escapes, braces, and embedded names. The server omits whole-string semantic
tokens for these literals so generated references cannot override those colors.
Hover and definition lookup use separate editor ranges for each embedded name;
literal text and braces do not link to an interpolated variable. Compiler nodes
continue to retain the original string's span and provenance.
Unresolved `as` and `pub` tokens also retain lexical scopes, allowing import
keywords and selected members with those names to receive contextual colors.
Resolved values and parameters named `as` or `pub` keep their semantic roles.

When the client supports dynamic file-watcher registration, the server requests
notifications for `**/*.ficus`. Watched disk changes trigger another check.
Initialization uses workspace folders, falling back to the root URI, as source
roots. Workspace-folder changes update these roots. Explicit `--source-root`
flags take precedence; with neither roots nor workspace information, open-file
directories are used. Uppercase module paths must be relative to these roots,
as with `compile`. Duplicate module candidates remain errors.

`--library DIR` is repeatable and defaults to the bundled library.
`--prelude FILE` selects a Prelude override. These discovery options have the
same meaning as in the CLI compiler. File URIs are supported; unsaved documents
must have a file path, rather than an editor-specific `untitled:` URI.

## Architecture

All editor behavior lives under `FicusLsp`:

- `FicusLsp` owns the server, handlers, versions, and snapshot lifecycle.
- `FicusLsp.Workspace` supplies in-memory overlays through
  `Ficus.Compile.compileProvided`, with ordinary module initialization rules.
- `FicusLsp.Index` reads Abstract occurrences and canonical identities, source
  schemes, and typed Core. It does not modify any compiler representation.
- `FicusLsp.Position` converts code-point offsets to UTF-16 ranges. It avoids
  parser columns because those expand tabs; inclusive source ends become
  exclusive LSP ends, and multiline tokens are split into single-line segments.
- `FicusLsp.Protocol` constructs protocol diagnostics, hover, definitions, and
  semantic tokens using the library's advertised token legend.

Compiler and Runtime modules import no LSP modules or protocol types. Analysis
is serialized with document events and queries. This initial implementation
rechecks the graph rather than caching individual compiler passes, so large
projects can increase editor-response latency. It never runs user programs.

## Verification

`stack test --test-arguments='--pattern LSP'` runs position, overlay, indexing,
and real JSON-RPC transport tests. The transport fixture drives Haskell's server
over pipes through initialization, queries, full and incremental edits,
diagnostic publication and clearing, UTF-16 replacements, close, shutdown, and
exit. The ordinary compiler and runtime suites remain part of `stack test`.
