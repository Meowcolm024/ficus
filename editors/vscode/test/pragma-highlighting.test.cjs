const assert = require('node:assert/strict');
const { test } = require('node:test');
const grammar = require('../syntaxes/ficus.tmLanguage.json');

// Check the pragma rules' matches and capture scopes without editor dependencies.
function pragmaMatch(source) {
  for (const rule of grammar.repository.pragma.patterns) {
    if (!rule.match) continue;
    const match = new RegExp(rule.match, 'u').exec(source);
    if (match) return { rule, match };
  }
  return null;
}

for (const target of ['Handle', 'intAdd', '(+)', 'Café']) {
  test(`builtin annotation identifies its key and target: ${target}`, () => {
    const result = pragmaMatch(`BUILTIN HANDLE ${target}`);
    assert.ok(result);
    assert.equal(result.match[1], 'BUILTIN');
    assert.equal(result.match[2], 'HANDLE');
    assert.equal(result.match[3], target);
    assert.equal(result.rule.captures[1].name, 'keyword.control.directive.builtin.ficus');
    assert.equal(result.rule.captures[2].name, 'constant.other.builtin-key.ficus');
    assert.equal(result.rule.captures[3].name, /^\p{Lu}/u.test(target) ? 'entity.name.type.ficus' : 'entity.name.function.ficus');
  });
}

test('foreign annotation identifies backend, symbol, and local binding', () => {
  const result = pragmaMatch('FOREIGN JS "console.log" log');
  assert.ok(result);
  assert.deepEqual(result.match.slice(1), ['FOREIGN', 'JS', '"console.log"', 'log']);
  assert.equal(result.rule.captures[1].name, 'keyword.control.directive.foreign.ficus');
  assert.equal(result.rule.captures[2].name, 'constant.other.foreign-backend.ficus');
  assert.equal(result.rule.captures[3].name, 'string.quoted.double.ficus');
  assert.equal(result.rule.captures[4].name, 'entity.name.function.ficus');
});

test('incomplete annotations retain directive highlighting', () => {
  for (const name of ['BUILTIN', 'FOREIGN']) {
    assert.equal(pragmaMatch(name).rule.name, 'keyword.control.directive.ficus');
  }
});

test('compiler key spellings outside annotations remain ordinary identifiers', () => {
  for (const name of ['BUILTIN', 'FOREIGN', 'HANDLE', 'JS', 'MAGIC']) {
    const keyword = grammar.repository.keyword.patterns.some(rule => new RegExp(rule.match, 'u').test(name));
    assert.equal(keyword, false);
  }
  assert.equal(pragmaMatch('MAGIC'), null);
});


test('private pragma distinguishes its optional member modifier', () => {
  const result = pragmaMatch('PRIVATE member');
  assert.deepEqual(result.match.slice(1), ['PRIVATE', 'member']);
  assert.equal(result.rule.captures[1].name, 'keyword.control.directive.ficus');
  assert.equal(result.rule.captures[2].name, 'storage.modifier.ficus');
});

test('deprecation pragma retains known-directive coloring', () => {
  const result = pragmaMatch('DEPRECATED oldName "Use newName instead"');
  assert.equal(result.match[0], 'DEPRECATED');
  assert.equal(result.rule.name, 'keyword.control.directive.ficus');
});
