# Lambda parameter patterns → explicit Abstract matches

Authored future-resolver/elaborator cases, not AST goldens. SourcesV0.ficus is
parser-valid; touch/next are injected harness operations, so it is not a
successful standalone module. DoBindingsV0.ficus uses ../../support/Prelude.ficus and its Bind Maybe
implementation, without redeclaring Maybe/Just; doRefutable is its
intentional typed rejection. Keep this source separate from NO_IMPLICIT_PRELUDE
so PreludeRequired cannot mask the coverage check.
RecordV1.ficus is versioned future parser input, not accepted in v0. No resolver
or elaborator executes this directory yet.

The Abstract shape invariant is Lambda Binder Expr, with no parameter Pattern.
TypeLambda retains only static type binders. Resolved patterns occur on explicit
Match clauses and named clause groups; they remain available for typed coverage.

| Source binding | Expected shape / assertion |
| --- | --- |
| pairLambda | Lambda fresh → Match fresh with product pattern; body references the pattern's x ID |
| nestedLambda | Lambda fresh1 → Match Just x → Lambda fresh2 → Match product (y,z) → body; never both lambdas followed by one tuple match |
| variableLambda | Direct Lambda x → Ref x; no capture or extra match needed |
| wildcardLambda | Fresh unused first binder followed by Lambda x → Ref x |
| typedLambda | TypeLambda a → Lambda fresh → Match fresh with (x : a) → Ref x; preserve annotation/type-variable IDs |
| hygiene | Generated argument ID differs from the source fresh1 ID; body keeps both resolved references |
| whereTiming | Retained named clause has AfterValueParameters 1 metadata; eventual clause lowering matches that argument and runs where before constructing the returned y lambda |
| failBeforeNextArg | Matching Nothing against Just fails before next runs |
| doBinding | Callback Lambda fresh → Match product; required-total coverage obligation points to the original do pattern |
| doRefutable | Resolve to explicit Match, then reject RefutablePattern at 3:27–32 (Just x), not during parsing/resolution |
| unpack (v1) | Simple lambda plus named record match; hidden e is scoped to the branch, never a lambda value binder |
| omitted (v1) | Explicit empty-field record match; omitted fields introduce no binders |

Check generated spans/origins against the corresponding original parameter, not
the following parameter/body. All original body and pattern variable IDs survive.
Variable/wildcard do patterns may discharge totality without a match, recording
the owning lambda and source origin rather than referring to a deleted pattern
node. For nontrivial patterns, coverage obligations reference live Match/pattern
IDs. Generalization/non-expansiveness checks must see the outer value lambda;
static TypeLambda alone still cannot protect an expansive initializer.

For v2 call-by-name, explicit parameter-pattern matches must preserve the
specified demand: do not erase a match merely because it is irrefutable. Keep
source pattern/demand metadata if later pattern compilation changes its shape.
Add independent runtime/differential assertions once the evaluator exists.
