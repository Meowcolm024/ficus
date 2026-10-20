const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;
let pending = Promise.resolve();
let disposed = true;

async function stopClient() {
  if (client) {
    const previous = client;
    client = undefined;
    // A rejected start leaves the client in StartFailed, where stop() rejects.
    if (previous.isRunning()) await previous.stop();
  }
}

function restartClient() {
  pending = pending.then(async () => {
    await stopClient();
    if (disposed) return;

    const config = vscode.workspace.getConfiguration('ficus');
    client = new LanguageClient(
      'ficus',
      'Ficus Language Server',
      {
        command: config.get('server.path', 'ficus'),
        args: config.get('server.args', ['lsp']),
      },
      { documentSelector: [{ scheme: 'file', language: 'ficus' }] },
    );
    await client.start();
  }).catch((error) => {
    void vscode.window.showErrorMessage(
      `Ficus language server failed: ${error.message}. Check ficus.server.path and ficus.server.args in Settings and the Ficus Language Server output.`,
    );
  });
  return pending;
}

function activate(context) {
  disposed = false;
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration((event) => {
    if (event.affectsConfiguration('ficus.server')) restartClient();
  }));
  return restartClient();
}

async function deactivate() {
  disposed = true;
  await pending;
  await stopClient();
}

module.exports = { activate, deactivate };
