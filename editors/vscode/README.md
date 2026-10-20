# Ficus for VS Code

Provides syntax highlighting, compiler diagnostics, inferred-type hover,
go-to-definition, and semantic highlighting for `.ficus` files.

Install Ficus with `stack install`, then open a Ficus file in a trusted workspace.
The extension starts `ficus lsp` over standard input/output and finds `ficus` on
VS Code's PATH by default. The server stops when the extension deactivates.

Set **Ficus: Server Path** (`ficus.server.path`) to use another executable:

```json
{
  "ficus.server.path": "/absolute/path/to/ficus",
  "ficus.server.args": ["lsp"]
}
```

The path is a single executable, including any spaces; do not add shell quotes
or arguments to it. Arguments are separate entries in **Ficus: Server Args**.
For example, when opening this repository as the workspace, use Stack:

```json
{
  "ficus.server.path": "stack",
  "ficus.server.args": ["exec", "ficus", "--", "lsp"]
}
```

To customize module discovery, append `--source-root DIR`, `--library DIR`, or
`--prelude FILE` after `lsp` in the arguments array. Relative paths use the
workspace directory. For multiple workspace folders, prefer absolute paths.
The server uses all workspace folders as source roots by default.

Changing either setting automatically restarts the server. Startup failures
appear as notifications; inspect **Output → Ficus Language Server** for details.
Syntax highlighting is also available in untrusted workspaces; the language
server requires workspace trust because it launches the configured executable.

For extension development, run `npm ci` and `npm test` in this directory, then
launch VS Code with `code --extensionDevelopmentPath=/absolute/path/to/ficus/editors/vscode`.
