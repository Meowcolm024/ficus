const assert = require('node:assert/strict');
const { test } = require('node:test');
const grammar = require('../syntaxes/ficus.tmLanguage.json');

function matchRules(patterns) {
  return patterns.flatMap(rule => {
    if (rule.include) return matchRules(grammar.repository[rule.include.slice(1)].patterns);
    return rule.match ? [rule] : [];
  });
}

for (const operator of ['<|>', '+', '>>=', '::']) {
  test(`parenthesized signature operator receives operator and bracket scopes: ${operator}`, () => {
    const signature = grammar.repository.signature;
    const match = new RegExp(signature.begin, 'u').exec(`    (${operator}) : a -> a`);
    assert.ok(match);
    assert.equal(match[2], `(${operator})`);
    assert.equal(match[3], ':');
    assert.equal(signature.beginCaptures[3].name, 'keyword.operator.ficus');

    const rules = matchRules(signature.beginCaptures[2].patterns);
    const operatorRule = rules.find(rule => new RegExp(rule.match, 'u').exec(operator)?.[0] === operator);
    assert.ok(operatorRule, 'signature names must apply operator highlighting');
    assert.equal(operatorRule.name, operator.startsWith(':')
      ? 'keyword.operator.constructor.ficus' : 'keyword.operator.ficus');
    for (const bracket of ['(', ')']) {
      const bracketRule = rules.find(rule => new RegExp(rule.match, 'u').exec(bracket)?.[0] === bracket);
      assert.ok(bracketRule, 'signature names must apply bracket highlighting');
      assert.equal(bracketRule.name, 'punctuation.definition.bracket.ficus');
    }
  });
}

test('ordinary signature names keep their identifier scopes', () => {
  const signature = grammar.repository.signature;
  const rules = matchRules(signature.beginCaptures[2].patterns);
  for (const [name, scope] of [['foo', 'variable.other.ficus'], ['Handle', 'entity.name.type.ficus']]) {
    const match = new RegExp(signature.begin, 'u').exec(`${name} : Type`);
    assert.equal(match[2], name);
    assert.equal(rules.find(rule => new RegExp(rule.match, 'u').test(name)).name, scope);
  }
});

test('operator definitions and longer colon operators do not start signatures', () => {
  for (const source of ['(<|>) x y = x', '(<|>) :: xs', '(<|>) :+ xs']) {
    assert.equal(new RegExp(grammar.repository.signature.begin, 'u').test(source), false);
  }
});
