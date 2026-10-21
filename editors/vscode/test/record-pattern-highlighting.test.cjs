const assert = require('node:assert/strict');
const { test } = require('node:test');
const grammar = require('../syntaxes/ficus.tmLanguage.json');
const record = grammar.repository['record-pattern'];
const fields = grammar.repository['record-fields'].patterns;

for (const name of ['Point', 'Geometry.Point', 'Δέντρο.Κλάδος']) {
  test(`named record pattern highlights its constructor, keyword and braces: ${name}`, () => {
    const match = new RegExp(record.begin, 'u').exec(`f ${name} with { x = value } = value`);
    assert.equal(match[1], name);
    assert.equal(match[2], 'with');
    assert.equal(match[3], '{');
    assert.equal(record.beginCaptures[2].name, 'keyword.control.ficus');
    assert.equal(record.beginCaptures[3].name, 'punctuation.definition.bracket.ficus');
    assert.equal(record.endCaptures[0].name, 'punctuation.definition.bracket.ficus');
    assert.ok(record.beginCaptures[1].patterns.some(rule => rule.include === '#qualified-term'));
  });
}

test('field labels receive member scopes while bound names remain ordinary names', () => {
  const field = fields.find(rule => rule.match);
  assert.equal(field.name, 'variable.other.member.ficus');
  const labels = [...'y = second; x = first; item = Point with { x = value }'
    .matchAll(new RegExp(field.match, 'gu'))].map(match => match[0]);
  assert.deepEqual(labels, ['y', 'x', 'item', 'x']);
  for (const source of ['value', 'x == y', 'Item = value', '_ = value']) {
    assert.equal(new RegExp(field.match, 'u').test(source), false);
  }
});

test('nested and empty record patterns retain balanced brace and literal scopes', () => {
  assert.ok(new RegExp(record.begin, 'u').test('Point with {}'));
  assert.ok(fields.some(rule => rule.include === '#record-pattern'));
  const braces = fields.find(rule => rule.begin);
  assert.equal(braces.begin, '\\{');
  assert.equal(braces.end, '\\}');
  assert.deepEqual(braces.patterns, [{ include: '#record-fields' }]);
  for (const name of ['comment', 'string', 'character']) {
    assert.ok(fields.findIndex(rule => rule.include === `#${name}`) < fields.findIndex(rule => rule.match));
  }
  const includes = grammar.patterns.map(rule => rule.include);
  assert.ok(includes.indexOf('#record-pattern') < includes.indexOf('#qualified-term'));
});
