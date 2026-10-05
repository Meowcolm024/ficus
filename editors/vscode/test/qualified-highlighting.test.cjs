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

for (const source of ['Just', 'Nothing', 'True', 'False', 'Point', 'Byte', 'Vec', 'Δέντρο']) {
  test(`bare uppercase name has constructor scope in terms and type scope in types: ${source}`, () => {
    for (const [context, scope] of [
      ['term-identifier', 'entity.name.tag.constructor.ficus'],
      ['identifier', 'entity.name.type.ficus'],
    ]) {
      const rule = grammar.repository[context].patterns[0];
      assert.equal(new RegExp(rule.match, 'u').exec(source)[0], source);
      assert.equal(rule.name, scope);
    }
  });
}

test('root terms and patterns use constructor identifiers without type overrides', () => {
  const includes = grammar.patterns.map(rule => rule.include);
  assert.ok(includes.includes('#term-identifier'));
  for (const typeRule of ['#identifier', '#primitive-type', '#library-type']) {
    assert.equal(includes.includes(typeRule), false);
  }
  const typeIncludes = grammar.repository['type-expression'].patterns.map(rule => rule.include);
  assert.ok(typeIncludes.includes('#identifier'));
  assert.equal(typeIncludes.includes('#term-identifier'), false);
});

for (const source of ['@Int', '@a', '@Data.Maybe.Maybe', '@_']) {
  test(`explicit type argument uses type scopes: ${source}`, () => {
    const rule = grammar.repository['explicit-type-argument'].patterns.find(rule => rule.match);
    const match = new RegExp(rule.match, 'u').exec(source);
    assert.equal(match[0], source);
    assert.equal(rule.captures[1].name, 'keyword.operator.type-application.ficus');
    assert.equal(rule.captures[2].patterns[0].include, '#type-expression');
  });
}

test('longer @ operators are not explicit type arguments', () => {
  for (const rule of grammar.repository['explicit-type-argument'].patterns) {
    for (const source of ['@+Int', '@@Int', '+@Int']) {
      assert.equal(new RegExp(rule.match ?? rule.begin, 'u').test(source), false);
    }
  }
});

test('explicit type arguments precede term scopes, and signature braces have a type context', () => {
  const includes = grammar.patterns.map(rule => rule.include);
  assert.ok(includes.indexOf('#explicit-type-argument') < includes.indexOf('#qualified-term'));
  assert.ok(grammar.repository['type-expression'].patterns.some(rule => rule.include === '#type-quantifier'));
  assert.equal(grammar.repository['type-quantifier'].patterns[0].include, '#type-expression');
});
