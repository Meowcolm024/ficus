# Existential record patterns and type members (v1+ proposal)

Ordinary explicit value-field record patterns are implemented and tested in
`../compile/record-patterns/` and `../parsing/`. The parser runner executes the combined existential type-member acceptance
cases and the three parser rejection cases in this directory. Semantic
expectations remain authored proposals.
ParsingV1.ficus is parser acceptance only: resolution/type checking may fail.
It covers record patterns in every admitted declaration/binder/match/do context,
omitted fields, uppercase type-member fields without @, explicit/layout
construction, arrow-containing type RHSs, and existing @/clause boundaries.
Uppercase type-member labels are parsed and checked. Executable existential
fixtures are in `../compile/record-patterns/Existential*.ficus`; these exercise
witness scoping and escape, higher kinds, constructor slots, and captured trait
dictionaries against both Runtime evaluators. Function and lambda record binders require
parentheses, as ordinary constructor applications do.
PositionalValuesV1.ficus retains value-only construction and anonymous unpacking.

Negative expectations use semantic validation unless marked parser rejection:

| File | Proposed kind | Primary span (one-based, inclusive) |
| --- | --- | --- |
| PatternConcreteTypeV1.ficus | InvalidTypeMemberPattern | 2:37–42 (String) |
| PositionalTypeV1.ficus | ExcessTypeArguments | 2:16–22 (@String) |
| DuplicateTypeMemberV1.ficus | DuplicateField | 2:34–36 (second Err) |
| WitnessEscapeV1.ficus | EscapingExistential | 2:55–55 (result x) |
| TypeMemberAtConstructionV1.ficus | SyntaxError (parser) | 1:29–29 (@) |
| TypeMemberAtPatternV1.ficus | SyntaxError (parser) | 1:37–37 (@) |
| MissingFieldEqualsV1.ficus | SyntaxError (parser) | 1:35–35 (e) |
| PatternCoverageV1.ficus | RefutablePattern | 4:23–48 (Box with { item = Just x }) |

Assert diagnostic kind/primary span rather than wording when integrated. The
upper-label pattern with String must parse and then fail the type-binder rule;
never reject a pattern merely because its shape looks refutable. PatternCoverage
is a mixed positive/negative semantic case: omitted fields cover the record, but
a nested Just pattern does not cover Maybe. Also cover unknown type-member labels,
kind mismatches, value/type-label confusion, witness non-escape with omitted
members, preserved recursive-binding restrictions, and record punning rejection.
