const assert = require('node:assert/strict');
const { test } = require('node:test');
const grammar = require('../syntaxes/ficus.tmLanguage.json');

for (const context of ['type', 'term']) {
  for (const source of ['Data.Maybe.Just', 'Data . Maybe . Just', 'Δέντρο . Κλάδος']) {
    test(`qualified uppercase name in ${context} context: ${source}`, () => {
      const rule = grammar.repository[`qualified-${context}`];
      assert.ok(rule);
      const match = new RegExp(rule.match, 'u').exec(source);
      assert.equal(match[0], source);
      assert.equal(rule.captures[1].name, 'entity.name.namespace.ficus');
      assert.equal(rule.captures[2].name, context === 'type'
        ? 'entity.name.type.ficus' : 'entity.name.tag.constructor.ficus');
    });
  }
}

test('qualified value and projection chain does not match an uppercase terminal', () => {
  const rule = grammar.repository['qualified-term'];
  assert.ok(rule);
  for (const source of ['Data.Maybe.value.field', 'Data.Maybe.Justicex']) {
    const match = new RegExp(rule.match, 'u').exec(source);
    if (source.endsWith('field')) assert.equal(match, null);
    else assert.equal(match[2], 'Justicex');
  }
});

test('type contexts use type rules before ordinary identifiers', () => {
  const patterns = grammar.repository['type-expression'].patterns;
  assert.ok(patterns.findIndex(rule => rule.include === '#qualified-type')
    < patterns.findIndex(rule => rule.include === '#identifier'));
  assert.equal(patterns.some(rule => ['#number', '#string', '#character'].includes(rule.include)), false);
});

test('only a bare colon starts a type annotation', () => {
  const rule = grammar.repository['type-annotation'];
  for (const source of [':', ': Int']) assert.ok(new RegExp(rule.begin, 'u').test(source));
  for (const source of ['::', ':+', '+:']) assert.equal(new RegExp(rule.begin, 'u').test(source), false);
});
