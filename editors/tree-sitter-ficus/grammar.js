// This grammar supplies highlighting tokens, not Ficus parsing or validation.
// Keeping the tree flat lets indentation-sensitive code highlight without a
// layout scanner and preserves highlighting while a declaration is incomplete.
module.exports = grammar({
  name: 'ficus',

  extras: $ => [/[\s\uFEFF\u2060\u200B]+/, $.line_comment, $.block_comment],

  rules: {
    source_file: $ => repeat($._token),

    _token: $ => choice(
      $.pragma,
      $.string,
      $.character,
      $.float,
      $.integer,
      $.wildcard,
      $.lower_identifier,
      $.upper_identifier,
      $.upper_operator,
      $.value_operator,
      $.arrow,
      $.bind_arrow,
      $.constraint_arrow,
      $.equals,
      $.colon,
      $.dot,
      'use', 'type', 'trait', 'impl', 'with', 'if', 'where', 'do',
      '(', ')', '[', ']', '{', '}', ',', ';'
    ),

    line_comment: _ => token(prec(2, /--[^\r\n]*/)),
    block_comment: _ => token(prec(1, seq('{-', repeat(choice(/[^-]/, /-[^}]/)), '-}'))),
    pragma: _ => token(prec(2, seq('{-#', repeat(choice(/[^#]/, /#[^-]/, /#-[^}]/)), '#-}'))),

    // Opaque literal tokens keep comment delimiters inside strings and chars.
    string: _ => token(seq('"', repeat(choice(/[^"\\]/, /\\[\\'"nrt]/)), '"')),
    character: _ => token(seq("'", choice(/[^'\\\r\n]/, /\\[\\'"nrt]/), "'")),

    float: _ => token(/\d+\.\d+/),
    integer: _ => token(/\d+/),
    wildcard: _ => '_',
    lower_identifier: _ => /\p{Ll}[\p{L}\p{M}\p{N}_']*/,
    upper_identifier: _ => /\p{Lu}[\p{L}\p{M}\p{N}_']*/,

    // Operator grouping depends on spelling and is deliberately absent here.
    upper_operator: _ => /:[!#$%&*+\/<=>?@\\^|~:\-]+/,
    value_operator: _ => /[!#$%&*+\/<=>?@\\^|~\-][!#$%&*+\/<=>?@\\^|~:\-]*/,
    arrow: _ => '->',
    bind_arrow: _ => '<-',
    constraint_arrow: _ => '=>',
    equals: _ => '=',
    colon: _ => ':',
    dot: _ => '.',
  }
});
