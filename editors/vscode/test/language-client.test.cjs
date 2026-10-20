const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');
const manifest = require('../package.json');

function extension({ settings = {}, startError, startGate } = {}) {
  const clients = [];
  const errors = [];
  const listeners = [];
  const subscriptions = [];
  const vscode = {
    workspace: {
      getConfiguration: () => ({ get: (key, fallback) => settings[key] ?? fallback }),
      onDidChangeConfiguration: (listener) => {
        listeners.push(listener);
        return { dispose() {} };
      },
    },
    window: { showErrorMessage: (message) => { errors.push(message); } },
  };
  class LanguageClient {
    constructor(id, name, server, options) {
      Object.assign(this, { id, name, server, options, stopped: false });
      clients.push(this);
    }
    async start() {
      await startGate;
      if (startError && clients.length === 1) throw startError;
      this.running = true;
    }
    isRunning() { return this.running === true; }
    async stop() {
      if (!this.isRunning()) throw new Error('Client is not running');
      this.stopped = true;
      this.running = false;
    }
  }
  const sandbox = {
    module: { exports: {} },
    require: (name) => {
      if (name === 'vscode') return vscode;
      if (name === 'vscode-languageclient/node') return { LanguageClient };
      throw new Error(`Unexpected dependency: ${name}`);
    },
  };
  vm.runInNewContext(readFileSync(require.resolve('../extension.cjs'), 'utf8'), sandbox);
  return {
    ...sandbox.module.exports, clients, errors, subscriptions,
    change: (section) => listeners.forEach((listener) => listener({
      affectsConfiguration: (key) => section === key || section.startsWith(`${key}.`),
    })),
  };
}

test('manifest activates the client for Ficus with executable defaults', () => {
  assert.equal(manifest.main, './extension.cjs');
  assert.ok(manifest.activationEvents.includes('onLanguage:ficus'));
  const properties = manifest.contributes.configuration.properties;
  assert.equal(properties['ficus.server.path'].default, 'ficus');
  assert.deepEqual(properties['ficus.server.args'].default, ['lsp']);
  assert.equal(manifest.capabilities.untrustedWorkspaces.supported, false);
});

test('starts the default server for file documents and stops on deactivation', async () => {
  const ext = extension();
  await ext.activate({ subscriptions: ext.subscriptions });
  const [client] = ext.clients;
  assert.equal(client.server.command, 'ficus');
  assert.deepEqual(Array.from(client.server.args), ['lsp']);
  assert.equal(client.options.documentSelector[0].scheme, 'file');
  assert.equal(client.options.documentSelector[0].language, 'ficus');
  assert.equal(ext.subscriptions.length, 1);
  await ext.deactivate();
  assert.equal(client.stopped, true);
});

test('passes paths with spaces and Stack arguments without shell interpretation', async () => {
  const settings = {
    'server.path': '/tools with spaces/stack',
    'server.args': ['exec', 'ficus', '--', 'lsp', '--library', '/my library'],
  };
  const ext = extension({ settings });
  await ext.activate({ subscriptions: ext.subscriptions });
  assert.equal(ext.clients[0].server.command, settings['server.path']);
  assert.deepEqual(ext.clients[0].server.args, settings['server.args']);
  assert.equal(ext.clients[0].server.options?.shell, undefined);
  await ext.deactivate();
});

test('restarts on server settings changes and ignores unrelated settings', async () => {
  const settings = {};
  const ext = extension({ settings });
  await ext.activate({ subscriptions: ext.subscriptions });
  ext.change('editor.fontSize');
  assert.equal(ext.clients.length, 1);
  settings['server.path'] = '/other/ficus';
  ext.change('ficus.server.path');
  await new Promise(setImmediate);
  assert.equal(ext.clients.length, 2);
  assert.equal(ext.clients[0].stopped, true);
  assert.equal(ext.clients[1].server.command, '/other/ficus');
  settings['server.args'] = ['lsp', '--source-root', 'src'];
  ext.change('ficus.server.args');
  await new Promise(setImmediate);
  assert.equal(ext.clients.length, 3);
  assert.equal(ext.clients[1].stopped, true);
  assert.deepEqual(ext.clients[2].server.args, settings['server.args']);
  await ext.deactivate();
});

test('reports startup failure and recovers after settings change', async () => {
  const ext = extension({ startError: new Error('spawn ENOENT') });
  await ext.activate({ subscriptions: ext.subscriptions });
  assert.match(ext.errors[0], /ENOENT.*ficus.server.path.*ficus.server.args/);
  ext.change('ficus.server.path');
  await new Promise(setImmediate);
  assert.equal(ext.clients.length, 2);
  assert.equal(ext.errors.length, 1);
  await ext.deactivate();
});

test('deactivation waits for startup and cancels queued restarts', async () => {
  let finishStart;
  const startGate = new Promise((resolve) => { finishStart = resolve; });
  const ext = extension({ startGate });
  const activation = ext.activate({ subscriptions: ext.subscriptions });
  await new Promise(setImmediate);
  ext.change('ficus.server.path');
  const deactivation = ext.deactivate();
  finishStart();
  await Promise.all([activation, deactivation]);
  assert.equal(ext.clients.length, 1);
  assert.equal(ext.clients[0].stopped, true);
});
