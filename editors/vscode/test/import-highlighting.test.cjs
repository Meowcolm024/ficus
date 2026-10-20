const assert = require('node:assert/strict');
const { test } = require('node:test');
const grammar = require('../syntaxes/ficus.tmLanguage.json');

test('as and pub have keyword scopes only outside the import selection', () => {
  const imports = grammar.repository['import-declaration'].patterns;
  const keyword = imports.find(rule => rule.name === 'keyword.other.import.ficus');
  for (const name of ['as', 'pub']) {
    assert.equal(new RegExp(keyword.match, 'u').exec(name)[0], name);
    assert.equal(grammar.repository.keyword.patterns.some(rule => new RegExp(rule.match, 'u').test(name)), false);
  }
  const selection = grammar.repository['import-selection'];
  assert.ok(selection, 'the outer import list must have its own context');
  assert.equal(new RegExp(selection.begin, 'u').test('('), true);
  assert.equal(new RegExp(selection.end, 'u').test(')'), true);
  assert.ok(selection.patterns.some(rule => rule.include === '#identifier'));
  assert.ok(selection.patterns.some(rule => rule.include === '#import-type-members'));
  assert.ok(selection.patterns.some(rule => rule.include === '#import-selection'), 'parenthesized operators must not close the outer selection');
  assert.equal(selection.patterns.some(rule => rule.name === 'keyword.other.import.ficus'), false);
  assert.ok(imports.some(rule => rule.include === '#import-selection'));
  assert.equal(imports.some(rule => rule.include === '#import-type-members'), false);
});

test('soft keyword prefixes inside longer identifiers remain ordinary names', () => {
  const keyword = grammar.repository['import-declaration'].patterns.find(rule => rule.name === 'keyword.other.import.ficus');
  for (const source of ["as'", "pub'", 'as_value', 'public', 'asλ', 'pubλ']) {
    assert.equal(new RegExp(keyword.match, 'u').test(source), false);
  }
});
