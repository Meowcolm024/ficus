const assert = require('node:assert/strict');
const { test } = require('node:test');
const grammar = require('../syntaxes/ficus.tmLanguage.json');
const interpolation = grammar.repository.interpolation.patterns.find(rule => rule.captures);

for (const name of ['x', '_value', '_', 'Module.value', 'Module._value', 'Data.Module.value', 'Δέντρο.όνομα']) {
  test(`interpolation highlights a valid variable: ${name}`, () => {
    const source = `{${name}}`;
    const match = new RegExp(interpolation.match, 'u').exec(source);
    assert.ok(match);
    assert.equal(match[0], source);
    assert.equal(match[2], name);
  });
}

test('interpolation can directly follow and precede doubled brace escapes', () => {
  const match = new RegExp(interpolation.match, 'u').exec('{{{x}}}');
  assert.ok(match);
  assert.equal(match[0], '{x}');
  assert.equal(match.index, 2);
});

for (const name of ['Type', 'Module.Type', 'record.field', 'f x', 'x + y', 'if', 'Module.do']) {
  test(`interpolation does not highlight an invalid variable: ${name}`, () => {
    assert.equal(new RegExp(interpolation.match, 'u').test(`{${name}}`), false);
  });
}

test('escapes are consumed before interpolation and qualified names use term scopes', () => {
  assert.equal(grammar.repository.string.patterns[0].include, '#escape');
  assert.equal(grammar.repository.interpolation.patterns[0].match, '\\\\[{}]');
  assert.equal(grammar.repository.interpolation.patterns[1].match, '\\{\\{|\\}\\}');
  assert.ok(interpolation.captures[2].patterns.some(rule => rule.include === '#qualified-value'));
  assert.ok(interpolation.captures[2].patterns.some(rule => rule.include === '#term-identifier'));
});
