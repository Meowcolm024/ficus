# Ficus Implementation Notes

This document records non-normative implementation choices, compiler tooling, and versioned engineering plans. Language behavior and the organized v1+ language-feature plans are defined by [SPEC.md](SPEC.md). Moving a representation or algorithm here does not change source-language behavior; implementations must preserve the specification's nominal identities, typing rules, diagnostics, and evaluation order.

## 1. Pipeline

Ficus uses four AST stages:

```text
source
→ lexing and parsing with parser-driven layout
→ Concrete AST
→ desugaring and name resolution
→ Abstract AST
→ type inference and elaboration
→ Core AST
→ erasure and runtime lowering
→ Runtime AST
→ evaluator compilation or code generation
```

`Runtime AST` is untyped in the sense that static types and schemes are erased, but it remains a validated runtime IR rather than an unchecked source language.

This split is intentional:

- Concrete AST faithfully preserves parsed source structure, comments, pragmas, and explicit versus indentation-based blocks for diagnostics and layout-aware pretty printing as a naive formatter.
- Abstract AST removes syntactic sugar and resolves lexical references to canonical identities; typed field selection, pattern coverage, and evidence insertion remain inference/elaboration work.
- Core AST is the small, typed, explicit result of inference and elaboration.
- Runtime AST is optimized for simple and efficient interpretation.

The reference implementation is written in Haskell. Each boundary should have a validator, focused tests, and a source map back to Concrete AST locations.

Before name resolution, every module receives the six reserved primitive types. The frontend additionally imports Prelude unless the module has `NO_IMPLICIT_PRELUDE`. It rejects `do` and string interpolation when that import is disabled rather than attempting ordinary name resolution for their dependencies.

Keep type and trait declarations in one namespace. Keep module bindings separate from type/kind bindings and permit primitive spellings and `Type` as local module names or aliases. A bare `use Data.Int` binds module Int without rebinding the primitive type; qualification resolves through the module namespace. Module spelling does not change primitive ownership. Repeated module qualifiers warn. At a qualified use, filter by exported terminal name and namespace, then deduplicate by canonical defining identity; distinct surviving identities are ambiguous. Bare imports bind only their final component; aliased imports bind only the alias. Store compiler-known library entities by their defining module and declared name after name resolution; aliases and re-exports must not change the registry key.

The Concrete AST stores a dotted expression as an unresolved base-and-segments chain. For an uppercase-only chain, name resolution treats all but the last component as a module path and the last as a type in a type expression or a constructor in a term or pattern; with a lowercase segment, it treats the whole uppercase prefix as a module path and that first lowercase segment as a value. Later lowercase segments become field projections. Reject direct projection from a constructor. Preserve the unresolved Concrete form until this step, and reject a missing module or export rather than reinterpreting the chain as constructor projection.

### 1.1 Source spans and provenance

Concrete, Abstract, and Core AST nodes retain source spans and provenance. A source span records the file and start/end positions; provenance connects transformed or generated nodes to the source nodes and declarations that produced them. Combining clauses must retain the individual clause spans as well as the binding origin. Generated lambdas, matches, and dictionary evidence must retain their originating locations rather than borrowing arbitrary neighboring spans.

Core metadata should connect inferred types and resolved references to source occurrences and declaration identities. This supports later LSP features such as showing types, jumping to definitions, and semantic highlighting. Runtime lowering embeds relevant source context in explicit error messages and fallible primitive operations; Runtime nodes have no spans or provenance.

### 1.2 Abstract declarations

Abstract syntax represents resolved values, type aliases, data/record declarations, traits, and implementations with separate constructors. Attach each signature and validated declaration pragma to its declaration identity; do not encode type/trait declarations as value expressions. Check equal written value arity and group source-ordered clauses into one value definition/ordered case matrix, retaining resolved patterns, per-clause scopes/where groups, and the number of written value parameters. Keep named clause groups until inference/coverage checking. Normalize lambda parameter patterns to simple binders plus explicit Abstract matches during resolution/desugaring; patterns remain on those matches for checking. Named clause groups are compiled to Core afterward. This refines the earlier proposal to lower every clause group to lambdas immediately, without changing source evaluation or initialization behavior. The interface and pass contracts are in Sections 1.4–1.6.

### 1.3 Parsing and formatter checks

Editor highlighting is independent of compiler parsing. Editor grammars may give known pragmas and their argument roles distinct colors; this does not introduce directive-specific compiler productions.

Use Megaparsec for parsing. The set of operator spellings is open, so operator grouping cannot rely on a static enumeration of operator names. Build grouping dynamically from encountered operators using the specification's spelling-based precedence and associativity rules; this does not introduce fixity declarations. Apply the same rules to expressions, types, and infix constructor patterns, rejecting mixed associativity within a precedence group.

Lex `--` as a line comment only when the following character is not another operator character, so `-->` remains an operator; `{-` always starts a block comment outside literals, so an unterminated `{-x}` is a lexical error. Qualification/projection separators permit surrounding whitespace wherever ordinary layout allows continuation. Do not let a leading dot override item boundaries, dedents, or the prefix `with` clause-block boundary. Embedded operator dots still require non-dot operator characters on both sides, and `..` remains reserved to import lists. Parse module-qualified constructors in patterns and named record construction, plus parenthesized qualified operator references; reject operator sections.

Drive layout from parser expectations for `block1` and `block`. The parser supplies virtual delimiters when it enters an indented block; a standalone lexing pre-pass must not decide where blocks begin. An expression block opens only at explicit `{` or newline plus deeper indentation after an expression introducer. For prefix `with`, stop the scrutinee at the explicit clause `{` or the newline opening the indented clause block. For postfix record `with`, require the same explicit or indented field-block delimiter. Parse projection and field-block suffixes in one left-associated postfix loop before application, keeping dotted chains unresolved. Preserve a generic record-with node until resolution can distinguish a direct record constructor from an existing record value; do not classify by uppercase spelling alone or by whether fields are omitted. Nested postfix field blocks belong to the scrutinee expression, not the surrounding prefix match; consume them at their own depth before opening the clause block. Lookahead for `=` and `<-` is limited to the current layout depth; nested record fields cannot classify an outer `do` or expression-block statement. String interpolation in v0 accepts a bare or module-qualified value name only, so its scanner need not parse nested expressions. Recognize `\{` and `\}` as string escapes before trying an interpolation opener; retain `{{` and `}}` as the other literal-brace forms.

Resolve shared grammar prefixes with lookahead at the current nesting and layout depth, backtracking, or a shared prefix representation. In `do`, `<-` selects a bind and `=` selects a declaration; in expression blocks, `:` selects a signature. For a top-level upper-name prefix, a direct `:` selects a kind signature; otherwise parse optional bare or kind-annotated type parameters through `=` for a type alias. Reject parameter lists before a signature colon and comma-separated signature targets; every signature names exactly one target. At an expression start that admits lambdas, speculatively parse the complete lambda parameter sequence: an optional leading type-binder prefix followed by value binder patterns, or type binders alone. Commit only if that entire sequence is followed by a structural `->`; otherwise rewind to an operator expression. A partial binder parse or merely finding an arrow later is insufficient. In non-lambda contexts (if conditions and match guards), parse an application such as `foo @a bar` up to the enclosing clause arrow without attempting lambda parsing. In ordinary expression contexts, that same prefix followed by `->` is invalid because its type binder follows a value binder. At declaration boundaries, require the complete named definition head followed by `=`. Keep arrows inside parenthesized type arguments and kind annotations at their nested depth. Share annotated-pattern parsing across binder and general pattern positions. Treat `:` inside a candidate parenthesized pattern as a type-annotation delimiter; arrows inside that type do not select the outer lambda. Without the outer arrow, rewind and parse an expression annotation under the ordinary expression grammar. Never search nested blocks for an outer item's delimiter. These strategies must produce the same Concrete AST.

Parse `::`, `True`, and `False` as ordinary constructor names or operators; their reserved identities are assigned during resolution, with no dedicated parser branches.

Preserve `_` as an ordinary lowercase identifier in Concrete AST, with its source span. Name resolution assigns wildcard, unconditional `if` fallback, or hole meaning to the exact spelling according to context; `_name` remains an ordinary identifier. Do not hardcode those meanings in the lexer or parser. Parse every `if` condition as `non_lambda_expr`; nested conditions need their own delimited clause blocks.

Keep positive and negative fixtures for syntax, layout, pragma placement, selective ADT constructor imports, whole-record imports, and operator grouping. Cover `_` and `_name` through all relevant syntactic contexts, both delimited nested `if` conditions and the undelimited rejection, `(->)` in type applications and instance heads, and expansive `impl` members even when signed or acyclic. A positive fixture should include prefix matching around postfix record construction with mixed braces and layout:

```text
foo () = with Point with { x = 1 ; y = 2 }
    (Point x y) -> x + y
```

The first `with` starts matching; the second constructs its record scrutinee. Closing the record's explicit braces must still allow the following indented match block.

For named declarations, require a `binding_name` at the head. Expression blocks, `where`, and `do` `=` also admit a non-infix pattern declaration such as `(a, b) = pair`; top-level declarations remain named. Reject bare or parenthesized infix pattern heads in every declaration context. Keep parenthesized infix patterns in function parameters, and parse full patterns in `do` `<-` binds, which are not declarations. The type-directed coverage check rejects refutable `<-` patterns; an infix constructor pattern can pass when it covers its inferred type. Give `do` `=` declarations ordinary strict sequential binding nodes rather than immediately applied lambdas, so definitions with parameters and generalization behave like expression-block bindings. Add negative fixtures for `x :: xs = value` in each declaration context and for `do { (x :: xs) <- action; rest }`; add positive fixtures for `uncons (x :: xs) = ...`, `(a, b) = pair`, and `do { f a = a; rest }`.

Consider property-based tests with a Concrete AST generator that renders valid combinations of indentation and explicit braces. Check that parsing pretty-printed concrete syntax preserves structure modulo formatting and spans, that comments survive, and that formatting is idempotent. Retain negative fixtures separately so invalid syntax is not normalized into an accepted form by the generator.

Diagnostics render source excerpts and primary-span underlines through `Ficus.Error.Pretty`, using the exact parsed text and four-column tab stops. Parser diagnostics have stable `P`-prefixed codes; `N` and `T` are reserved for name resolution and type checking. See [ERRORS.md](ERRORS.md) for the registry. This follows the source-referenced style of `rustc`. A small set of humorous messages may explain attempts at dependent types, such as `foo : Int -> Type`, or suggest traits for `bar : Type -> Bool`. Suggested fixes are deferred.

### 1.4 Resolution passes and canonical names (proposed M2 design)

The resolver accepts validated Concrete modules plus a source-root/module-provider configuration. It returns a validated Abstract module, export summary, source-reference index, and diagnostics. The resolver implementation separates Provider (file lookup), Header/Pragma (semantic directives), Discovery (module graph), Scope (interfaces and import candidates), and Desugar (pure translation). Ficus.Resolve composes them; inference remains separate.

Use canonical qualified identities for globals. A reference written as `M.insert`, after `use Data.Map as M`, denotes the original `Data.Map.insert`. Re-exporting it through Prelude or another module keeps that owner and identity. Store structured module paths and declaration IDs, not dotted strings to split during later passes. Namespace and declaration role are part of lookup metadata: a record type and its constructor can have the same displayed qualified spelling but different identities. Reserved compiler primitives use stable intrinsic IDs, not invented source-module ownership. Locals, lambda binders, pattern variables, and scoped type variables use fresh IDs, with spelling retained only for diagnostics/pretty printing. Canonicalization does not make an otherwise unimported name accessible.

The inspiration is Agda's distinction between local variables, global definitions, constructors, patterns, clauses, and declaration metadata after scope analysis. See [Agda.Syntax.Abstract](https://hackage-content.haskell.org/package/Agda-2.8.0.2/docs/Agda-Syntax-Abstract.html) and its [source](https://agda.github.io/agda/src/Agda.Syntax.Abstract.html). Ficus keeps terms, types, and kinds separate; it does not adopt Agda's dependent Pi types, reflection forms, or unresolved constructor candidates in successfully resolved term occurrences. Clauses/patterns remain useful until checking even when lexical scope has been settled.

#### R0 — Header scan and module identity

- Derive the canonical module path relative to the configured root; never silently rename an entry file to Main. Resolve imports through a module provider. Source-root precedence and duplicate-file selection are configuration decisions still to specify, not an implicit first-file-wins rule.
- Scan generic pragma nodes before traversing imports or bodies. Classify supported names by language version, argument shape, target class, and placement. Unknown/unsupported/invalid directives produce semantic N-codes; lexer/parser failures keep their existing P-codes.
- Extract header-only `NO_IMPLICIT_PRELUDE`. Declaration pragmas elsewhere cannot retroactively alter imports. `BUILTIN` stays declaration metadata and does not change module mode. Future `STANDALONE` is discovered here for importability checks; future ETA remains attached to one definition and is not a module option.
- Keep the original directive span and each argument span. Duplicate/conflicting BUILTIN associations have their specified validation; do not invent a duplicate-module-flag policy where the spec has not selected one.

Output: `ModuleHeader { moduleId, languageVersion, mode, explicitImports, pendingDeclarationPragmas }`.

#### R1 — Dependency discovery and implicit Prelude

- Install reserved primitive type/kind/constructor identities independently of imports. Their namespace protection does not prohibit primitive-named module bindings.
- Unless the header disables it, add an implicit import edge to canonical Prelude and its public-member scope. Preserve an `ImplicitPrelude` origin anchored at the module header/source start so a missing Prelude or cycle has an honest primary location. Explicit Prelude imports do not disable this edge under the current spec; equivalent entities/initialization nodes are deduplicated by identity.
- Discover every dependency's header before resolving the importing body. Include implicit edges in cycle detection. Bootstrap Prelude and its dependencies with explicit `NO_IMPLICIT_PRELUDE`; do not silently exempt the Prelude file or BUILTIN modules.
- Detect import cycles with a DFS stack or module SCCs. Report the closing explicit import (or implicit edge anchor) and related spans for the cycle path. Module imports are eager dependencies even if every imported name is unused.
- Load each module once by canonical identity. Preserve written import order as edge metadata; resolution order and map iteration must not become runtime initialization order. Place the proposed implicit Prelude edge before explicit dependencies for internal scheduling, but retain this as an engineering proposal pending any observable implicit-edge ordering contract.
- Future: reject every edge to a STANDALONE module, including implicit edges, aliases, and re-exports, using header metadata before executing or resolving initialization.

Output: an acyclic module graph with dependency/source-order metadata. Source-root/library distribution and observable ordering of implicit versus explicit imports remain explicit configuration/design questions.

#### R2 — Interfaces, selections, and import candidate sets

Process dependencies before importers. Initially export summaries can be in-memory products of resolved/checked dependencies; serialized `.interface` files and their cache compatibility are separate v1+ work. Maintain the distinction between name visibility and transitive type/trait metadata needed to check imported signatures. Split interfaces into a resolver-facing NameSummary (identities, public categories, ownership, visibility, implementation IDs) and an inference-facing CheckedSignatureSummary (closed schemes/kinds and nominal/trait descriptors). The latter is passed separately to inference, never embedded as Core nodes or solver metavariables in Abstract. When an imported value has an inferred signature, finish checking that dependency before checking its importer; naming can use its collected NameSummary sooner.

- A module-only or aliased import installs a qualifier, not its unqualified values. A selected/all-members import installs selected entities, not a module alias. Do not grant additional qualification syntax just because a module was loaded.
- Validate selected names against the dependency's public exports. ADT selections check constructor ownership; a bare ADT type imports only that type. A record type also brings its public constructor and nominal field labels; explicit record member selections remain invalid. Fields are never injected as ordinary callable values. Index their descriptors by nominal owner and label; same-spelled fields from different records are typed selectors, not N0002 global-value ambiguities.
- Keep `Map (Namespace, Spelling) (NonEmpty ImportCandidate)` for opened imports. Each candidate has a canonical target and every import route/span that introduced it. Union by target identity; do not pick the last import or emit an ambiguity just for multiple distinct targets.
- Ordinary uses demand exactly one candidate after applying lexical scope. A use with none is unresolved; a use with distinct remaining targets is ambiguous and lists all canonical names with related import spans. Do not use inferred types to pick between otherwise ambiguous value/type/constructor imports.
- Missing modules/exports and malformed semantic selections fail immediately, even if unused. Reserved names remain protected. Distinct local declarations are still checked for duplicates independently of import candidates. Do not misclassify an imported candidate set as repeated source declarations.
- `pub` is a demand on the public export map. Union selected entities with existing public declarations/re-exports by namespace/spelling; identical canonical identities coalesce. Different identities under one exported name fail at the re-export, with the conflicting export/declaration as a related span. A successful export summary never contains unresolved ambiguity.
- Collect visible implementation identities separately from opened names, following SPEC's implementation visibility/closure rules for each import edge. Do not make instance visibility depend on whether an ordinary imported spelling is used.
- Keep qualifier candidate sets and all import routes. Repeated qualifiers warn, but an unused conflict is legal; qualification demands only entities exporting the requested name.

Use-site conflict checking and identity deduplication follow the relevant model in [Haskell 2010 §5.5.2](https://www.haskell.org/onlinereport/haskell2010/haskellch5.html#x11-1030005.5.2); Ficus retains its own import forms, acyclic modules, separate field namespace, and selected re-export rule.

#### R3 — Declaration collection and lexical scopes

- Allocate IDs for top-level and mutually visible where declarations before traversing their bodies. Group clauses by their owning value definition, preserving order and all clause spans; attach signatures to the corresponding declaration in that declaration list, not to an imported namesake. A signature-only name can be a provisional declaration fulfilled by a valid BUILTIN association; reject an unfulfilled ordinary signature after all associations are known. Diagnose duplicate signatures and independent duplicate definitions separately from legitimate clause grouping. Before combining clauses, check equal written value arity as specified in SPEC §6: count parameter patterns before `=`, excluding @ binders, RHS lambdas and signature arrows. Report N0012 on the later inconsistent clause head, relating it to the first head. Check during declaration grouping/desugaring before type inference; do not repair a mismatch by eta expansion. Preserve a common arity and every original count/span for validation and where timing. Sequential shadowing bindings are not grouped together; repeated zero-parameter definitions remain duplicate declarations.
- Predeclare nominal types, aliases, constructors, traits, methods, fields, and implementations in their specified namespaces. Record constructor/field ownership and nominal identity explicitly. Same-spelled entities in permitted separate namespaces remain distinct. Nominal fields carry their owner, so a diagnostic may display Data.People.Person.name without treating that display as a new source-level value path.
- Resolve function/lambda patterns with a fresh local ID per binder. Check duplicate binders across the complete pattern/parameter list. Guards and clause bodies see that clause's binders; other clauses do not. Bind `_` as a wildcard without allocating a value variable; `_name` is ordinary. Wildcard declaration heads are translated to anonymous PatternDefinition Wildcard nodes, not ValueDefinitions. Keep each initializer, its source order, and where plan; allocate no global/local name, and never group repeated wildcard heads. Reject parameterized wildcard heads and all name-only uses of `_` during resolution.
- For sequential expression/do declarations, resolve the initializer against the previous environment, then extend it for later items. Self-reference is not introduced by a sequential declaration. Shadowing gets a warning and a new ID. For mutually visible where/top-level groups, predeclared bindings are available throughout; SCC safety is checked later.
- Maintain separate type-variable scopes. Explicit `@a` binders enter later parameter annotations/body/where scopes. A signature's explicit `{a}` and implicit free variables get signature-local IDs; a definition's `@` IDs are aligned positionally by checking, not unified merely because they share text. Named annotation variables without a permitted binder remain invalid. Infer kind/type holes later; no resolver metavariables or solved types belong in Abstract.
- Resolve implementation member definitions against their trait member identities in the implementation's member scope. Repeated `show` definitions in different implementations are not duplicate global functions; record an implementation ID plus member ID and let elaboration build evidence.
- Resolve generic BUILTIN targets after declaration collection so adjacency and source order do not affect lookup. Keys remain metadata. Validate key existence and association conflicts here; target type/kind contracts and primitive-body elaboration belong to T-stage checking.

Output: per-group symbol tables, canonical declarations, lexical references, and source-occurrence index entries. Only the conversion pass imports both Concrete and Abstract modules; output nodes never contain a Concrete node or Concrete-specific type.

#### R4 — Occurrence resolution and hygienic desugaring

Resolve names before generating sugar references, then refer directly to selected canonical identities. Generated fresh binders cannot capture source variables or be captured by them.

| Source form | Abstract result / remaining work |
| --- | --- |
| Bare/qualified name, operator reference | Local ID or canonical global/constructor/method identity. Operator applications become ordinary binary applications after dynamic grouping; do not regroup based on the resolved operator |
| Dotted chain | Resolve its module prefix/export once, then represent remaining projections as label selectors. Never retry a missing export as constructor projection |
| Field projection/update | Keep a source-spanned field-label selector and receiver expression. Inference chooses nominal field identity from the receiver; this is a typed field obligation, not unresolved lexical value lookup |
| Record `with` | Direct resolved record constructor becomes named construction; any other receiver becomes update and must infer a record type. Preserve supplied field order, even when constructor field order differs |
| Prefix `with`, annotated/constructor patterns | Resolved match and pattern nodes, with guards/order intact; coverage and refutability are not resolver decisions |
| Lambda parameter patterns | Unary simple-binder lambdas with nested explicit matches at their application points; preserve annotations and original pattern IDs/spans for checking |
| `if` | Distinct conditional node, including an explicit final fallback marker for `_`; keep it distinct through Core |
| `do` `<-` / nonfinal expression | Applications of the registered Bind method and a hygienic simple-binder lambda with an explicit pattern match. Attach a required-total-coverage obligation and original pattern span to that match for `<-`; do not let desugaring lose the semantic rejection |
| `do` declaration / expression block | Strict sequential-binding/effect nodes; never replace polymorphic sequential declarations with immediately applied lambdas |
| Interpolated string | Left-associated concatenation/show applications using registered library identities, preserving segment/value evaluation order and origins; plain strings remain literals |
| `@T`, `{a}`, type/kind annotations | Separate type application, signature quantifiers, and scoped annotation syntax; kind/type checking remains later |
| List/product/unit and literals | Dedicated semantic aggregate/literal nodes with intrinsic identities where needed; literal decoding/range validation has its own diagnostics |

Check the module mode before expanding do/interpolation: under NO_IMPLICIT_PRELUDE they fail even if the user explicitly imports Bind or Show. When enabled, sugar uses compiler-known library identities through the registry, unaffected by a local `bind`/`show` spelling or ambiguous ordinary imports. Interpolation uses the canonical Prelude.stringAppend binding associated with STRING_APPEND. Inject sugar contracts through a separate extensible SugarRegistry, independent of ResolveConfig; fixture-only configurations live in tests. Negation likewise uses the existing primitive/numeric contract rather than an invented name lookup.

Lower lambda parameter patterns to explicit matches here as described below. Do not lower named clause groups, field constraints, dictionaries, or ETA here. Lambda/where and source parameter metadata must survive so inference and Core lowering preserve initialization points. Build a resolved reference graph for recursive groups, including type references separately; checking expansiveness, signature conformance, recursion protection, and dictionary-induced initialization edges belongs to inference/elaboration.

#### Lambda parameter normalization

Abstract lambda nodes bind one value ID, never a pattern. Normalize a source lambda after resolving its parameter patterns and body:

```text
(p1 p2 -> body)
  => fresh1 -> with fresh1 {
       p1 -> fresh2 -> with fresh2 { p2 -> body }
     }
```

This is schematic resolved syntax: `fresh1`/`fresh2` are hygienic IDs, not generated source spellings requiring another lookup pass. Normalize right-to-left to construct the nested result, but preserve left-to-right application/matching behavior. Match the first argument immediately after its application, before evaluating a following application argument. Do not collect all parameters into one tuple match beneath all lambdas: `((Just x) y -> body) Nothing (effect ())` must fail on Nothing before effect runs.

A bare variable parameter can directly bind its resolved ID without an extra match. A bare wildcard uses a fresh unused binder. All other parameter patterns, including annotated variables, use a fresh argument binder and an explicit match retaining the original resolved pattern and annotation. No irrefutability decision is needed to perform this translation; type/coverage checking can later prove a generated match total. Generated lambdas, binders, receiver references, matches and clauses inherit the corresponding parameter's span and generated-origin metadata; the source body keeps its own origin.

Keep explicit type abstractions separate and outside the value-lambda chain: `@a (x : a) -> x` becomes a TypeLambda followed by a simple-binder Lambda and an annotated-pattern Match. Type abstractions do not delay runtime work. Keep source-based parameter counts and monomorphism metadata; generated matches must not make a source function initializer look expansive. For a future lazy arrow, normalization must preserve the specified parameter-matching demand rather than removing it just because coverage proves the pattern irrefutable.

A do-bind uses the same normalization, but its generated match carries the required-total-coverage obligation from the original `<-` pattern. A refutable do pattern still parses/resolves and then fails typed checking. Ordinary lambda-generated matches retain ordinary match-failure behavior and warning-only coverage obligations. Wildcards/variables can discharge totality structurally without an extra match node, retaining an origin/obligation record for diagnostics and validation.

Attached where groups stay at their source execution point. For `f p = q -> body where ...`, the group's work remains after the first written value parameter and its pattern match, before constructing the returned q lambda. Generated binders/matches do not count as extra written parameters. Named multi-clause definitions remain clause groups until checking/lowering; their eventual compilation must likewise preserve source-clause selection, parameter matching and where timing. Source and expected-shape cases are in `test/fixtures/desugaring/pattern-lambdas/`; these are authored assertions, not hand-edited AST goldens.

### 1.5 Abstract syntax for inference/elaboration (proposal)

Place shared identities in `Ficus.Syntax.Name`, semantic literals in a shared stage-neutral module, Abstract types in `Ficus.Syntax.Abstract`, validation in `Ficus.Syntax.Abstract.Validate`, and translation/loading in `Ficus.Resolve.*`. These are proposed files, not additions in this documentation change. Abstract imports shared source/name/literal types only, never `Ficus.Syntax.Concrete`. Core must not import Abstract types either; the elaborator owns that conversion.

Use an Abstract-owned node wrapper, in the style of the existing Concrete wrapper but with no dependency on it:

```haskell
newtype LocalId = LocalId Int
newtype TypeVarId = TypeVarId Int
newtype ModuleId = ModuleId (NonEmpty Text)
-- DeclarationKey distinguishes permitted same-spelled declarations/namespaces.
data GlobalId = GlobalId ModuleId DeclarationKey | IntrinsicId PrimitiveKey

data Node a = Node
  { nodeId :: NodeId, nodeSpan :: Span, nodeOrigin :: Provenance, nodeValue :: a }
-- Text is diagnostic/source spelling, not the identity used for lookup.
data Binder = Binder LocalId Text
data TypeBinder = TypeBinder TypeVarId Text (Maybe KindSyntax)
data Reference = LocalRef LocalId | GlobalRef GlobalId

type Expr = Node ExprF
data ExprF
  = Ref Reference | Constructor GlobalId | Method GlobalId
  | Literal SemanticLiteral | Hole HoleId
  | Apply Expr Expr | TypeApply Expr (NonEmpty TypeSyntax)
  | Lambda Binder Expr | TypeLambda (NonEmpty TypeBinder) Expr
  | Match Expr (NonEmpty MatchClause) | Conditional (NonEmpty IfClause)
  | Sequence (NonEmpty Statement) Expr
  | Where WherePlan BindingGroup Expr
  | Project Expr FieldSelector
  | ConstructRecord GlobalId [FieldAssignment]
  | UpdateRecord Expr (NonEmpty FieldAssignment)
  | Product (NonEmpty Expr) | List [Expr] | Unit

type Pattern = Node PatternF
data PatternF
  = Bind Binder | Wildcard | ConstructorPattern GlobalId [Pattern]
  | LiteralPattern SemanticLiteral | ProductPattern (NonEmpty Pattern)
  | ListPattern [Pattern] | UnitPattern | AnnotatedPattern Pattern TypeSyntax
-- Future record patterns/type-member openings extend this type in v1+.

type TypeSyntax = Node TypeF
data TypeF
  = TypeVariable TypeVarId | TypeConstructor GlobalId
  | TypeApplication TypeSyntax TypeSyntax
  | FunctionType ArrowMode TypeSyntax TypeSyntax
  | QualifiedType [PredicateSyntax] TypeSyntax | TypeHole HoleId
-- Normalize list/product/function constructor sugar to intrinsic TypeConstructor
-- applications. ArrowMode is Strict in v0; CallByName is a v2+ extension.
data SchemeSyntax = SchemeSyntax [QuantifiedBinder] [PredicateSyntax] TypeSyntax
-- QuantifiedBinder retains Explicit vs Implicit and stable explicit-argument order.
data PredicateSyntax = PredicateSyntax GlobalId TypeSyntax
-- KindSyntax is a separate Node tree: TypeKind, KindVariable, KindArrow, KindHole.

data ValueBody
  = ExpressionBody Expr | ClausesBody FunctionCases | BuiltinBody BuiltinKey
data FunctionCases = FunctionCases WrittenValueArity (NonEmpty Clause)
data DeclarationF
  = ValueDefinition ValueDefinition
  | PatternDefinition Pattern Expr
  | AliasDefinition AliasDefinition | DataDefinition DataDefinition
  | RecordDefinition RecordDefinition | OpaqueBuiltinType GlobalId BuiltinKey KindSyntax
  | TraitDefinition TraitDefinition
  | ImplementationDefinition ImplementationDefinition
-- Every nested clause, binder, statement, assignment, predicate, quantifier,
-- kind, signature, and declaration is also wrapped in Node in the actual API.
```

This is a representation sketch, not compilable Haskell: supporting records and their located fields are defined by the following contracts. Avoid a fully unified term/type universe or a generic extensible AST framework until a concrete need appears.

| Record / supporting type | Required contents |
| --- | --- |
| `AbstractModule` | Module ID/mode, ordered dependency edges, unique public export table, visible implementation IDs, declaration groups, source-occurrence index, registry associations, coverage obligations |
| `ValueDefinition` | Owner global/local binder, optional resolved SchemeSyntax, declaration pragmas, ValueBody (including signature-backed builtin values), all source clause origins, source-based parameter/monomorphism metadata, including original lambda parameters independently of generated matches |
| `FunctionCases` | One binding identity and ordered clause matrix, with common written value arity checked during desugaring. This is the single function case group, not independent definitions; later Core lowering preserves curried application/matching order |
| `Clause` / `MatchClause` | Fresh clause binders, ordered type/value parameters or pattern, optional guard, RHS, per-clause where group, written value-parameter count; no inferred refutability flag |
| `WherePlan` | `AtInitialization` or `AfterValueParameters n`, attached to the source declaration/clause rather than inferred from a resulting lambda chain |
| `Statement` | Strict effect or sequential named/pattern binding. Binding IDs become visible only in later statements; binding boundary retained for generalization |
| `BindingGroup` | Nonempty resolved declarations, recursive/sequential scope classification, source order and resolved dependency edges; SCC classification is structural, not proof of safe initialization |
| `FieldSelector` / `FieldAssignment` | Label and label span, optional already-known nominal owner/member identity, RHS and field-where metadata; preserve order. Unknown receiver/member association is for inference, not a speculative global lookup |
| `DataDefinition` / `RecordDefinition` | Nominal type ID, optional kind signature, kind-annotated parameters, constructor IDs, constructor field types or ordered nominal field descriptors |
| `TraitDefinition` | Trait ID/parameter, resolved supertrait predicates, method IDs and SchemeSyntax; no dictionaries yet |
| `ImplementationDefinition` | Implementation ID, resolved trait/head/context, method-to-body mapping and declaration metadata; overlap, orphan, superclass and evidence checks remain T-stage work |
| `CoverageObligation` | Live match/pattern/clause IDs, original spans, required-total versus warning-only reason, or a discharged-simple-binder record attached to its lambda ID. Do-bind obligations survive generated lambda/match conversion |
| `Occurrence` | Source spelling/span, selected canonical reference or binder definition, and import-route metadata for navigation; no retained Concrete AST |

An expression hole has an identity/origin but no inference metavariable yet. Abstract validation accepts it. Inference retains a typed goal using the shared parameterized expression syntax, continues elaboration, and reports its zonked type, lexical context, and blocking constraints after checking; it may retain typed holes in diagnostic Core, but reports them as elaboration errors and forbids them in accepted Core. Runtime lowering independently rejects any remaining hole. The detailed goal/recovery contract is in [TYPECHECKING.md](TYPECHECKING.md#expression-hole-goals-and-continuing-elaboration). Similarly a type hole is syntax consumed by kind/type inference. Resolve implicit signature variables once per signature in a stable traversal; binder order exposed to explicit application comes only from written explicit quantifiers, never incidental traversal order.

The source `id : {a} -> a -> a; id @b (x : b) = x` has distinct signature and definition TypeVarIds, an ordered explicit quantifier, and a clause-local value ID for x. Elaboration aligns/checks the type binders. A term reference to an imported id uses its defining module's GlobalId; applying `@Int` adds a TypeApply node, without introducing a runtime lambda or delay.

### 1.6 Validation, elaboration ownership, and failure recovery

Abstract validation checks referential integrity of every global/local/type-variable ID, permitted namespace/role, lexical dominance, distinct pattern binders, closed signature-variable scopes, uniform written value arity within each FunctionCases group and valid where/value-parameter metadata, unique export targets, source locations/provenance, and presence of required coverage obligations. Imported metadata may include non-visible types/traits needed to check signatures, but these do not become names source code can refer to. Symbolic field selectors are an explicit allowed obligation. There are no pattern-bearing Lambda nodes, raw dotted chains, operator trees, unresolved pragma targets, do nodes, interpolation segments, or Concrete nodes in a successful Abstract module.

Inference/elaboration owns kind solving/defaulting; signature checking and explicit binder alignment; @ instantiation and holes; nominal record field selection; type-directed coverage and do-bind totality; type/value/monomorphism restrictions; alias regularity; trait constraints and dictionaries; initialization safety including generated evidence; and typed match/clause lowering to Core (lambda parameter patterns have already become Abstract matches). Preserve distinct if nodes. Lower supplied record fields through source-ordered temporaries if constructor order differs; updates evaluate their receiver once. Generated temporaries, lambdas, matches, and evidence inherit their actual origin's span/provenance. Extend the current SourceOrigin-only representation with generated-origin tags and parent spans in the shared source module, not by embedding earlier AST nodes.

A failed name use produces a diagnostic and, only in a recovery-only tree, a poison reference linked to that diagnostic ID. Skip dependent checks that would merely repeat the same unresolved name; continue independent declarations/modules when possible. Poison/recovery trees cannot pass validateAbstract or enter inference. A valid but unused import candidate set is not poison and does not occur as an unresolved Expr reference. Sort diagnostics deterministically by module traversal/source span/code and list alternative import routes in stable order. Do not suppress independent missing-export, pragma, or cycle errors just because a body failed.

Diagnostics, explicit draft N/T code mappings, primary/related-span conventions, and warning severity are in [ERRORS.md](ERRORS.md#proposed-resolution-and-elaboration-diagnostics). Each pass's acceptance fixtures and validator checks are tracked in PLAN M2a–M2g. No canonical ID allocation order or map iteration order is allowed to alter runtime effects.

## 2. Type checker

The detailed proposed pass contracts, generalization schedule, evidence-aware
initialization checks, and implementation checkpoints are in
[TYPECHECKING.md](TYPECHECKING.md). That document refines this section without
changing SPEC.md or claiming an implemented type checker.

The type checker may follow *Typing Haskell in Haskell* (THIH), simplified for Ficus. Useful parts include:

- kinds, type variables, constructors, substitutions, and unification;
- predicates and qualified types;
- schemes, instantiation, and generalization;
- class environments, entailment, and ambiguity checks;
- inference over binding groups using dependency SCCs.

Ficus omits much of Haskell's complexity: it is strict, has single-parameter traits, and initially excludes higher-rank types, GADTs, type families, and unrestricted polymorphic mutation.

Inference consumes the Abstract AST and produces typed syntax and explicit evidence for every resolved trait predicate. Preserve annotated patterns, their spans, and provenance across the Concrete/Abstract boundary. Before resolving a v0 pattern annotation, reject named type variables not in the lexical scope of an explicit `@` binder. Names mentioned only in an enclosing or separate signature do not enter that scope; `_` remains an inference hole. Resolve the remaining type and unify it with the whole annotated pattern's type. Recurse through nested annotations in arguments, matches, declarations, and `do` bindings without adding implicit binders; determine refutability from the checked types and resolved patterns. Declaration-head and irrefutability checks inspect the underlying pattern through annotation wrappers, so annotations cannot bypass the ban on infix declaration heads or refutable v0 `do` binds. Infer holes in the enclosing inference context; annotations do not add runtime arguments. For a recursive SCC, make explicit signature schemes available for independent instantiation at recursive use sites, then check each signed definition against its signature. Infer unsigned bindings with shared monotypes inside the SCC and generalize eligible ones at its boundary. Signature holes must be solved without using polymorphic recursion through the missing part. The separate non-expansive-initializer and lambda-protection checks still apply to cyclic SCCs.

Apply the v0 value restriction at each binding-group boundary. Generalize only non-expansive right-hand sides, using the same syntactic classifier that rejects expansive `impl` member initializers. A signature cannot bypass the restriction. After resolving constructors and inferring the bound result and nested pattern types, use the exhaustiveness/coverage checker to prove total coverage for each `do` `<-` pattern. Do not classify by syntax or constructor spelling. Single-constructor ADTs and records may pass when their fields cover their types; multi-constructor, literal, and list patterns need ordinary coverage analysis. Annotations and infix notation are transparent to coverage. Reject patterns without proven coverage with their own primary spans. Keep this check before Core lowering, separate from declaration-head syntax and runtime matching demand.

Also apply the v0 monomorphism restriction before generalizing unsigned bindings: if a binding has unresolved trait predicates and no written value parameters or explicit outer value lambda, keep one monotype rather than abstracting those predicates into a reusable dictionary function. Resolve its remaining predicates against that monotype before accepting the binding. A complete explicit signature overrides this restriction but still must satisfy the value restriction; a signature with unresolved holes does not override it. Cover unsigned, signed, and lambda-wrapped constrained bindings with separate fixtures.

Keep weak type variables monomorphic across later uses and reject any still unresolved at the end of module inference, whether or not they carry trait predicates. A signature cannot silently generalize weak variables created by an expansive initializer.

The built-in list, binary-product, and function constructors participate in kind inference as `[] : Type -> Type`, `(*) : Type -> Type -> Type`, and `(->) : Type -> Type -> Type`. They have stable constructor identities, so implementation heads and higher-kinded holes may target them directly without aliases or spelling-based special cases in inference.

For a value signature, expression annotation, or pattern annotation, each `_` becomes a fresh type metavariable with a fresh kind metavariable. Unification may solve a hole to a proper type or a higher-kinded constructor such as `(*)`. After checking the inferred expression or binding, zonk the written skeleton, retain residual inferred predicates, and generalize only where the v0 value restriction permits. Reject type holes in alias right-hand sides, data bodies, trait member signatures, implementation heads, and other type-only locations.

Parse kind atoms as ordinary uppercase names, then resolve the reserved `Type` kind during semantic checking; do not hardcode `Type` in the parser. Kind annotations on alias, ADT, record, and trait parameters constrain inferred kinds. Share the type-parameter parser across these declarations: each parameter binds a lowercase name, optionally annotated with a kind, and never performs type matching. An optional top-level kind signature also constrains the alias's inferred kind; check it consistently with parameter annotations. Every `_` in a kind signature is a fresh kind metavariable to solve from the declaration; default any still-unconstrained kind variable to `Type` after inference and issue a warning. A standalone `_` in a non-binder, non-pattern expression position is an expression hole: retain its typed goal and continue inference/elaboration, then issue its contextual hard-error diagnostic after solving the available constraints, even if inference otherwise succeeds. Core AST may retain expression-hole nodes for continued elaboration and diagnostics. Elaboration must report them as errors, and Runtime lowering must independently reject them rather than emitting a hole or stub.

Reject partial applications and direct or indirect cycles of transparent aliases. Check recursive ADT SCCs for regularity before kind inference accepts them: occurrences must use declared parameters unchanged and in order, including through mutual recursion.

Class-environment validation should enforce the Haskell 98 declaration forms before entailment:

- a trait head is `C a`, and every superclass predicate is `Ci a`;
- an implementation head is `C (T a1 ... an)` with distinct variables;
- every implementation-context predicate is `Ci aj` for a head variable;
- concrete, repeated, nested, and missing head variables are rejected.

These restrictions apply only to declarations. Predicates generated at use sites may contain arbitrary well-kinded monotypes, subject to ambiguity checking.

After collecting trait declarations, validate the superclass graph with an SCC pass. Every cyclic SCC, including a self-loop, is a static error. Entailment may then traverse superclasses without cycle detection in its hot path.

Integer and floating literals enter inference directly as `Int` and `Float`; they do not generate numeric trait predicates. Unary negation preserves either type and lowers to the corresponding compiler primitive.

Represent `Int` with signed 64-bit values and wrapping arithmetic, and `Float` with IEEE 754 binary64 values. Keep questions about out-of-range literals, integer division, and conversions separate from these settled representations.

Record projection may use a deferred `Field receiverType label resultType` constraint. Mark all type variables reachable from a pending field constraint weak so inner `where` or binding-group generalization cannot quantify them. Propagate those constraints to enclosing use sites, then solve once ordinary inference fixes a nominal receiver, no later than the module boundary. Unify the result with the declaration's field type. An unresolved receiver is a type error; do not generalize a field constraint. Field labels do not participate in trait lookup or choose a record type by themselves.

Parse every pragma into the same Concrete form: an ALL_CAPITAL name and an ordered list of identifier/string arguments, with spans and provenance. Do not enumerate directive names or attach signatures in the parser. Preserve arbitrary pragma names until semantic validation checks supported names, argument forms/counts, and placement. Parenthesized operator names remain identifier arguments; numbers and character literals are not pragma arguments.

During name resolution, collect `BUILTIN` metadata for ordinary top-level targets in the current module. Resolve targets using the same namespaces and declaration identities as ordinary names, independently of adjacency or source order. Obtain signatures and kinds from normal declarations. Reject unresolved targets, conflicting associations, incomplete signatures for bodyless declarations, and additional source definitions. Compiler keys are registry identifiers, not scope references.

The registry maps keys to expected type/kind contracts and implementations or opaque representations. Validate each target declaration against its contract during elaboration. Opaque types retain their declaring module's nominal identity and ownership; values elaborate to typed primitive nodes. Builtin pragmas do not suppress Prelude. Bootstrap modules that need to avoid implicit import cycles use `NO_IMPLICIT_PRELUDE` explicitly.

Validate orphan implementations against nominal ownership after alias expansion. An implementation must belong to the trait owner or the outer type constructor's owner. The built-in constructors `[]`, `(*)`, and `(->)` and primitive types `Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` have no module owner, so their implementations must belong to the trait owner. Erasing a single-field ADT's representation must not change its ownership or instance identity.

Trait bodies contain signatures only and an `impl` must supply every declared member. Derived operations such as `(/=) : Eq a => a -> a -> Bool` and `(<) : Ord a => a -> a -> Bool` are ordinary top-level functions, not trait members or dictionary fields. Elaborate their constraints and calls normally; instances need no forwarding members for these operations. Reject default member bodies and fallback instance implementations.

Method signatures may introduce additional qualified constraints on method-level variables, as `Traversable.traverse` does for `Applicative f`. Elaborate those predicates into method evidence at use sites; they are not new trait parameters. Reject a method whose unconstrained value type omits its trait parameter, such as `trait C a = { foo : Int }`.

Collect visible implementations from the current module and the transitive closure of its explicit and implicit imports. Do not consult unrelated modules in the build. Perform overlap and resolution-cycle checks within the visible set, independent of import order.

Before accepting module initialization or elaborating an `impl`, the checker classifies every top-level value initializer and every member initializer as non-expansive or expansive, including acyclic definitions and definitions with complete signatures. Only non-expansive initializers are accepted by default. In v1+, permit expansive acyclic top-level initializers only when the defining module carries validated STANDALONE metadata; never apply the exception to recursive SCCs or implementation members. Include immediately initialized `where` bindings in this check; an expansive attached group on a definition with no written value parameters remains invalid even if the right-hand side produces a lambda, unless the acyclic standalone exception applies. Do not extend this blanket restriction to local bindings evaluated during function calls. Written value parameters count as surrounding lambdas, so the body of a method such as `show x = effect x` is not evaluated during dictionary construction. Include dictionary construction and member-to-top-level references in the same initialization dependency graph; a variable initializer may read an already initialized dependency but cannot bypass the cyclic-SCC checks.

### Explicit type binders and application (v0)

Parse outermost signature quantifiers `{a}`/`{a : Kind}`, definition/lambda binder prefixes `@a`/`@(a : Kind)`, and application arguments `@` followed by one ordinary type atom. Reserve bare `@`, retaining maximal munch for longer operators. Preserve binder/argument spans and provenance; record static type arguments separately from runtime arguments. Do not reinterpret term braces as type applications. Nested quantifiers and polymorphic function arguments are unsupported in v0.

Retain the order of explicit quantified variables separately from implicitly quantified variables in schemes and interfaces. Scope definition/lambda binders over annotations, body, and attached where declarations; align them positionally with signed quantifiers, or check unsigned bodies under fresh abstract variables before rank-1 generalization. Instantiate supplied arguments in declared order, kind-check them, and infer omitted positions and holes. Do not infer public argument order from unification traversal. Reject unbound annotation variables, excess type arguments, concrete type patterns, and type binders/arguments after value parameters/arguments.

Erase type abstraction/application without inserting runtime lambdas or calls. Count only written value parameters for where initialization and recursive lambda protection. Type-only abstractions preserve their body's expansiveness and source-based monomorphism classification; they cannot delay effects or bypass initialization checks. Keep ordinary value restriction and signed-recursion rules. The versioned source fixture inventory is in `test/fixtures/type-application/`; it is not wired into the scaffold runner.

### Record construction and update

Resolve construction only for a direct bare or qualified record constructor; constructor-valued variables remain ordinary function values. For update, infer the receiver, require a nominal record type, and constrain each supplied label and replacement against that same instantiated type. Reuse deferred field constraints without selecting a record type from its labels or generalizing an unresolved receiver. Preserve type arguments and reject unknown/duplicate labels, type-changing replacements, and punning. Updates involving existential records remain open.

Lower an update with a fresh binding for the receiver and successive bindings for replacement initializers in source order. Reconstruct the record from those bound replacements and unchanged fields from the bound receiver; never reconstruct in declaration order before evaluating the replacements in source order. Preserve references in unchanged fields. Generated bindings, projections, and constructor nodes retain the update/field origins' spans and provenance. Classify updates as expansive even if their children are non-expansive.

The v0 parser is implemented in `src/Ficus/Syntax/Parser.hs` with a Megaparsec lexer in `src/Ficus/Syntax/Parser/Lexer.hs`. Its typed, source-oriented Concrete syntax is in `src/Ficus/Syntax/Concrete.hs`; shared positions and provenance are in `src/Ficus/Util/Source.hs`, language tokens are in `src/Ficus/Syntax/Token.hs`, parser codes and diagnostics are in `src/Ficus/Error/Parser.hs`, and source-excerpt rendering is in `src/Ficus/Error/Pretty.hs`. `test/Ficus/Parser/Spec.hs` runs `test/fixtures/parsing/`, including the record-with corpus, and checks semantic fixtures for parser acceptance. Run it with `stack test`. Lossless source rendering preserves the original text. `Ficus.Syntax.Concrete.Pretty` provides a naive AST printer using the `pretty` package: it preserves explicit braces versus layout blocks with four-space indentation and moves comments above their containing top-level item while retaining their text and order. The `ficus format [FILE]` command reads a file or stdin and prints that result to stdout; `ficus --version` uses the package version from `Paths_ficus`. Formatter tests compare reparsed typed syntax including block delimiters, modulo source maps, and check idempotence. Cover prefix/postfix nesting, application precedence, suffix association, brace/layout boundaries, nested field declarations and `where`, qualified constructors, qualified value updates, type annotations, and the future record-pattern boundary. Semantic fixtures must separately check receiver evaluation once, source-order effects, type preservation, missing construction fields versus omitted update fields, and initialization restrictions. No golden AST files should be accepted without review.

### 2.1 Builtin and future foreign annotations

Add syntax fixtures for uniform ALL_CAPITAL names, identifier/string arguments, parenthesized operator names, and unknown directives that parse but fail semantic validation. Reject numeric/character arguments and inline/local pragmas under the v0 rules. Test all proposed pragma forms with the same parser, without requiring their future semantic support.

Builtin semantic fixtures cover opaque and higher-kinded types, values, imports/re-exports, ordinary scope, retained Prelude, and pragmas separated from their target signatures in either source order. Negative fixtures cover unknown keys, unresolved targets, incompatible types/kinds, conflicting associations, missing/incomplete declaration signatures, extra source definitions, duplicates, and invalid placement. Preserve pragma and declaration provenance on generated nodes.

Future `FOREIGN LANG "symbol" name` uses the same parsed pragma representation and ordinary target resolution. Its backend adapter checks the declaration's signature and lowers to foreign-call nodes. Foreign support remains v2+ work; marshalling, symbol resolution, exception handling, and ABI rules require specification. No foreign-specific syntax or signature attachment belongs in the parser.

## 3. Core AST

The more explicit proposed typed calculus, polymorphic dictionary method fields,
runtime match-failure representation, and independent validator are in
[TYPECHECKING §6](TYPECHECKING.md#6-proposed-core-calculus-and-ast). The grammar
below is a compact overview; it omits scheme abstraction/instantiation and failure
continuations described there. Inference and finalized Core share a parameterized
`ExprF`/`Expr ty` structure; there is no separate checked expression datatype.
Private work records retain unresolved pattern, field, and evidence plans.
Continuing expression-hole elaboration uses shared `Hole` nodes and the
`PartialElaboration` result described in
[TYPECHECKING §4](TYPECHECKING.md#expression-hole-goals-and-continuing-elaboration).
Core includes typed hole nodes for diagnostic output. Elaboration reports each
hole as an error; completeness validation accepts only hole-free Core. Runtime
lowering independently rejects holes even if earlier checks were bypassed.

A compact Core AST should stay close to the type-checker's elaboration result. Functions and applications are unary and curried; trait evidence is explicit. One possible grammar is:

```ebnf
module  = { data_decl | dict_decl | bind } ;

bind    = name ":" type "=" expr ;
expr    = variable
        | hole hole_id
        | literal
        | fun binder "->" expr
        | app expr expr
        | let bind in expr
        | letrec "{" rec_bind { ";" rec_bind } "}" in expr
        | con constructor type_args value_args
        | case expr of "{" alt { ";" alt } "}"
        | if "{" if_alt { ";" if_alt } "}"
        | dict dict_constructor type_args value_args
        | select expr field
        | prim primitive type_args value_args ;

rec_bind = name ":" type "=" expr ;
if_alt  = expr "->" expr | "_" "->" expr ;
alt      = constructor binders "->" expr
         | literal "->" expr
         | "_" "->" expr ;
```

Every binder and expression carries its inferred Core type, even where the notation above omits it. HM type variables and type arguments may be retained for validation and specialization, then erased when the backend does not need them.

### 3.1 Functions and calls

Core AST functions are unary. A multi-parameter source definition becomes nested lambdas, and a multi-argument call becomes nested applications. For example:

```text
f : (Eq a, Show a) => a -> Int -> String
f x n = ...
```

is represented schematically as:

```text
f = fun eqA ->
    fun showA ->
        fun x ->
            fun n ->
                ...
```

An elaborated call is:

```text
app (app (app (app f eqInt) showInt) x) n
```

Dictionary evidence is an ordinary explicit parameter, conventionally placed before value parameters. Binder metadata may distinguish evidence from source parameters for diagnostics and later erasure, but Core AST application has only one mechanism.

### 3.2 Dictionaries

Each trait becomes a dictionary type containing:

- one field for each superclass dictionary;
- one function field for each method.

An `impl` becomes a dictionary constructor or a top-level dictionary value. A constrained binding receives required dictionaries explicitly. A method reference becomes `select dictionary method`; superclass entailment becomes selection of the superclass field.

Dictionary construction is explicit and strict. Reusing a dictionary value is preferable to reconstructing it at each call. Resolution is complete before Core AST generation: the Core AST contains no implicit trait lookup.

A trait with no members and only proof meaning has a unit dictionary. When no runtime operation consumes that evidence, lowering may erase both its dictionary value and its lambda/application pair. `Exception e` cannot currently be assumed to qualify: typed `catch` needs nominal runtime identity, and its evidence or another type token must survive erasure. The choice of representation remains open.

### 3.3 Other translations

Suggested translations are:

- source parameters and applications become nested unary lambdas and applications;
- sequential blocks become nested strict lets;
- non-expansive, lambda-protected recursive SCCs become `letrec`;
- patterns and `with` become `case`;
- binary products, lists, ADTs, and records become constructors and projections;
- n-component surface products become right-nested binary constructors;
- unary `-` becomes the `Int` or `Float` negation primitive;
- `do` and interpolation use the desugarings in the specification.

Keep `if` as a distinct Core AST conditional node, as shown schematically above. Desugaring must not turn it into `with`, and Core generation must not route it through a pattern-match node. The exact Runtime AST branch representation remains an implementation choice.

`let` is strict, including `do` `=` declarations and local pattern bindings. `letrec` accepts only SCCs whose initializers are non-expansive and whose recursive references are protected by lambdas. It allocates all slots first, then evaluates right-hand sides in source order. Constructor, dictionary, call, and primitive arguments evaluate left-to-right. Place an attached `where` group after every written parameter and before the declaration's right-hand side; arity raising must preserve any work at that intermediate application point.

Elaboration must preserve the specification's evaluation order. The Core AST validator should reject unbound variables, type mismatches, unsaturated dictionaries, invalid constructor arities, expansive cyclic initializers, unprotected recursive references, and malformed case alternatives. Keeping the Core AST typed makes the evaluator, optimizer, and future backends easier to validate.

## 4. Runtime AST

The implemented module layout, AST, lowering steps, evaluator, and embedding API
are recorded in [the Runtime design](RUNTIME.md).

Runtime lowering must check the entire input Core module for expression holes before erasure or optimization, including unused bindings, lambda bodies, dictionary methods, and unselected branches. Encountering a hole returns a structured error at its original span and prevents Runtime output, even if elaboration or completeness validation was bypassed. The lowering traversal also explicitly rejects the hole constructor; no runtime stub or delayed failure is generated.

Runtime AST has no expression-hole constructor. It erases static types, type arguments, schemes, trait predicates, source names, spans, and provenance. Source context remains only in explicit error payloads. Dictionaries with operational fields remain; uncertain evidence is retained conservatively.

A compact form is:

```ebnf
program = globals, functions, layouts, initialization_schedule ;
fun     = arity, frame_size, expr ;
expr    = local lexical_address
        | global global_id
        | literal
        | closure function_id captures
        | call expr args
        | let expr expr
        | letrec recursive_slots expr
        | con tag args
        | case expr alternatives
        | if arms fallback
        | select expr constructor_id field_index
        | prim primitive_id args error_context
        | raise message ;
```

Runtime lowering erases constructor wrapping for every nominal ADT with exactly one constructor and one field, including single-field records. Construction evaluates the field with ordinary strict semantics and returns its representation directly, without allocating a tag or box. Matching unwraps that representation without tag dispatch, and a field projection returns the underlying representation. Keep the nominal type and constructor identities in typed Core AST and source metadata; only their runtime wrapper is erased.

Explicit dictionary arguments normally occupy leading runtime slots, followed by value arguments. Memberless proof dictionaries may be erased only when no runtime operation consumes their evidence; the unresolved `Exception e` representation is excluded from this erasure assumption. Other dictionaries lower to constructor-like records, method selection to indexed field selection, and dictionary methods to ordinary closures.

### 4.1 Arity raising

Runtime AST raises arity for efficient execution. It groups only Core AST lambda chains whose intermediate application points perform no observable work into n-ary functions and flattens matching saturated application spines. Attached `where` initialization after a prefix of written parameters prevents flattening across that point. Partial applications and higher-order uses remain explicit closures.

In `f a b`, source semantics evaluate and apply `f a` before evaluating `b`; flatten an application only when the intermediate application is free of observable work. For `f x = y -> body where ...`, initialize `where` after `x`, before constructing the returned lambda. For `f x y = body where ...`, initialize it after both written parameters. Do not infer the initialization point from the number of lambdas in the resulting Core expression.

### 4.2 Variables and environments

Runtime AST must not perform string-based name lookup. Bound variables use lexical addresses:

```text
(frame depth, slot index)
```

This is a De Bruijn-style representation adapted to n-ary frames. It avoids alpha-renaming and gives direct slot lookup. A scalar De Bruijn index is simpler, but makes frame lookup and IR rewriting less clear.

Globals, functions, constructors, fields, and primitives use dense numeric IDs. After closure conversion, captures use compact closure-slot indices. Separate debug tables map IDs and source locations back to names.

### 4.3 Evaluator-oriented design

Runtime AST favors a small evaluator:

- constructor and field names become numeric tags and indices;
- pattern matching becomes tag or literal dispatch;
- argument and field vectors evaluate left-to-right;
- function metadata records arity and frame size;
- partial application stores the callee and supplied arguments;
- saturated calls allocate one frame and enter the body;
- tail position is explicit or structurally apparent;
- a validator rejects impossible states before execution.

Tail position may support a backend-specific tail-call optimization, but Runtime AST and source semantics do not require every backend to provide constant-stack tail calls.

Runtime AST is compiled compositionally before execution, so the hot path does not inspect AST constructors. ANF or compact bytecode may still be added if host-closure execution becomes the bottleneck. It should be derived from the Runtime AST, not replace the Core AST.

### 4.4 Erasure and validation

Lowering from Core AST must:

- erase types while retaining dictionaries used at runtime and uncertain evidence;
- erase single-constructor, single-field wrappers without allocating tags or boxes; assign tags and field indices for other data representations, plus function IDs and lexical addresses;
- perform arity analysis and flatten eligible unary lambda/application chains into the calling convention;
- erase memberless proof dictionaries only when their evaluation and evidence applications can safely be removed;
- preserve strict left-to-right evaluation;
- preserve partial and extra application behavior;
- embed source context in generated error messages and fallible primitive operations, without per-node Runtime metadata.

The Runtime AST validator checks indices, arities, tags, case tables, capture layouts, primitive operands, non-expansive cyclic initializers, and lambda protection in recursive groups. The interpreter may rely on these invariants.

### 4.5 Implemented representation and boundary

`FicusBackend.Lower.Runtime.lowerProgram` independently checks Core acceptance
and links dependency-ordered modules. It preserves their ordered binding groups.
The Runtime validator returns an opaque `ValidatedProgram`, the only input to
public evaluator compilation. Runtime modules import no earlier AST types.

Frames are vectors of `IORef (Maybe Value)` cells. Depth zero names the nearest
frame; function entry has one argument frame in parameter order. A sequential
`Let` pushes a one-slot frame, and `LetRec` pushes one frame for the entire group.
Every selected case alternative pushes a frame, including an empty frame for a
literal test. Captures use separate zero-based slots and hold cells, so recursive
closures share initialized storage. Creating a closure drops unrelated lexical
frames. All global cells are allocated before the initialization schedule runs;
local recursive cells are allocated before that group's ordered initializers.
A premature read produces a structured error rather than a host-language knot.

Dense vectors store functions, constructor layouts, and primitives. The program
stores a global-cell count; source identities remain in the lowering result. List nil, list cons, and binary pair reserve tags 0, 1, and 2.
Bool and Unit use immediate literals. Other non-erased constructors receive
nominal tags; dictionaries receive aggregate tags with superclass fields before
methods. Byte uses `Word8`, Vec uses an immutable vector, Int uses `Int64`, and
Float uses `Double`. Single-field nominal wrappers allocate no layout or box.
All dictionaries currently survive; type-only scopes and applications do not.

Arity raising crosses pure lambda chains, type scopes, and monomorphic aliases
of supplied parameters. Matches and other strict lets stop it. Calls remain
unary after Core lowering; even hand-built multi-operand Runtime calls evaluate
and apply each operand before evaluating the next. Functions retain value versus
evidence parameter roles for recursive-read validation. Bindings retain their
Core non-expansiveness certificate and offending source span: erased syntax
cannot reliably reconstruct this source classification. Operand types and these
source facts remain Core acceptance responsibilities.

## 5. Evaluator compilation

Runtime AST compiles to host-language evaluator functions:

```haskell
type EvalM = ExceptT RuntimeError IO
type Eval = Env -> EvalM Value
compileExpr :: Program -> Expr -> Eval
```

`EvalM` accounts for runtime errors and effects; a pure presentation may simplify it to `Value`. `compileExpr` traverses each Runtime AST expression once and returns a host closure that performs only its runtime work. Compiled child evaluators and code-table elements are forced before execution, including unselected branches and delayed function bodies.

```haskell
compile (Local address) =
    \env -> lookupLocal address env

compile (Let rhs body) =
    let rhsEval  = compile rhs
        bodyEval = compile body
    in \env -> do
        value <- rhsEval env
        bodyEval (push value env)

compile (Fun arity body) =
    let bodyEval = compile body
    in \env -> pure (VClosure arity bodyEval env [])
```

A lambda body is compiled to an `Eval` closure before any runtime function value is created. Evaluating the lambda packages that code closure with the current lexical environment. A partial application also stores supplied arguments; a saturated call creates the n-ary frame and invokes the stored evaluator directly.

Calls, alternatives, constructor fields, primitive operands, and dictionary operations follow the same pattern: compile their subexpressions once, then combine the evaluator closures. Recursive function groups use precompiled bodies and explicitly shared cells.

This is compositional evaluator compilation, staged interpretation, or closure threading. It resembles specializing an interpreter with respect to a program, but it is not general partial evaluation and requires neither binding-time analysis nor a Futamura projection.

Runtime AST is a good input because type checking, trait search, source names, and complex patterns have already been removed. Primitive effects remain behind a small evaluator interface.

A direct AST interpreter may remain as a simple test oracle. The compiled evaluator must produce the same values, errors, and effect order.

## 6. Future backends

The v2+ backend targets JavaScript and adds tail-call optimization. Generate from validated Runtime AST and preserve strict evaluation, closure capture, nominal identities, embedded error messages, and intermediate application work. Implement tail calls explicitly rather than relying on host-engine support; direct loops and trampolines are candidate strategies. Specify coverage for self, mutual, and higher-order tail calls before promising constant-stack execution.

v3+ considers WebAssembly GC or LLVM. Closure conversion, memory management, runtime services, and the backend choice remain open.

Optimized or generated code must remain observationally equivalent to the reference evaluator.

## 7. Entry points and compiler artifacts

Execution takes an explicitly selected entry-module identity; do not discover an entry by searching for `main`. Resolve and validate a `main` defined by that module, reject missing or invalid entry functions, and retain its resolved identity/address for invocation rather than doing runtime string lookup. Do not require library modules to define `main` or invoke unselected entry candidates. Entry-point validation accepts exactly `main : [String] -> Unit` and `main : [String] -> Result String Unit` in v0. The backend driver passes command-line arguments and handles Unit/Result returns and exit reporting according to SPEC §22. Entry-point exception handling belongs to v1+.

v1+ compilation produces both module interface files and object files, each using Lisp-like syntax. The initial object files serialize Runtime AST as text; integration with v2+ generated JavaScript and later backend artifacts remains to be specified. The concrete schemas, file extensions, compatibility/versioning rules, output paths, and linking details remain to be specified.

## 8. Initial v1+ CLI

```text
ficus compile FILES
ficus run FILE
ficus repl [FILE]
ficus format [-f FILE]
ficus lsp
```

The current early-development `compile FILE...` command runs discovery, parsing,
name resolution, type inference, and elaboration to validated Core. It emits no
artifacts and neither requires nor invokes `main`. `Ficus.Compile` has no backend
dependency; backend drivers consume its checked modules and retained dependency
order. Errors return nonzero; warnings do not fail the command. The future full compilation behavior below
remains planned.

`--library DIR` replaces the default bundled library root and is repeatable.
`--prelude FILE` overrides the source of canonical Prelude without renaming it;
its dependencies use the configured roots. Repeatable `--source-root DIR`
selects project roots; absent that flag, input file directories supply the roots.
Overlapping roots with distinct module identities and duplicate module files are
errors. These discovery options are for early development and subject to change.
`library/Prelude.ficus` is an initial copy of the fixture Prelude, bundled as
package data rather than found relative to the current working directory.
`Ficus.Library.Contracts` holds its provisional compiler/sugar contracts;
fixture-only configuration remains in tests.

Future artifact emission will use a backend driver to lower the Core produced by `Ficus.Compile` and write interface and textual Runtime AST object files. `run FILE` explicitly selects the module represented by FILE as the entry module, validates its own `main`, and executes it with the evaluator. Compilation alone does not select or invoke an entry module. `repl` starts an interactive evaluator session and optionally loads a file. `format` parses to Concrete AST and pretty-prints it with layout as a naive formatter. `lsp` exposes semantic highlighting, jumping to definitions, inferred-type hover, and compiler diagnostics using the spans, declaration identities, and provenance retained across AST stages. The server uses Haskell's `lsp` library and confines protocol types, unsaved buffers, and editor indexes to `FicusLsp`; compiler stages have no LSP dependencies in their source. See [LSP.md](LSP.md) for its API boundaries and synchronization behavior.

`FicusBackend.Driver.Run` validates the selected module's own entry signature
before initialization. Lowering exposes constructor addresses so Result returns
are decoded by numeric tags rather than runtime name lookup.

`FicusBackend.Driver.Repl` owns interactive compilation and execution; the CLI
uses Haskeline only for terminal input and command dispatch. A session retains
source snapshots, name scopes, inferred schemes, evaluated values and compiled
closures, and a stable constructor/dictionary layout table. Core modules are
temporary compilation results and are not retained in the session. Each accepted
submission has a fresh internal module identity. Previously
accepted names are injected explicitly into resolution scope, preserving
canonical identities and letting new submissions shadow names without editing
old source. Source snapshots are recompiled for new expressions/declarations,
but evaluated globals are reused by identity with `initializeWith`; previous
initializers and their effects do not run again. Retained closures keep their
original global cells and code. Calls use the current invocation's effect
interface. Stable numeric constructor and dictionary tags allow old closures
and new code to exchange data even after additional types are defined.

The compiler's explicit `InteractiveInitialization` mode permits only acyclic
expansive top-level initializers. Ordinary compilation retains
`OrdinaryInitialization`; the mode is carried into Core so its validator checks
the correct boundary contract. Recursive groups and implementation members
retain their normal restrictions. No source pragma activates this mode.
Rebindings receive fresh module-owned identities. Constructor reuse is checked
against the owner of the type being replaced; omitted constructors are hidden
from both the retained name scope and ordinary imports such as implicit Prelude.
`:kind` resolves type and trait names against the current source scope and reads
stored kinds, displaying only the kind. Other type-level expressions are checked
using a temporary alias; the query reads its inferred kind and displays applied
trait predicates with a `Constraint` result. `:type` resolves terms and reads a bare
value or constructor's stored scheme. Other expressions are compiled inside a temporary
Unit thunk; the query displays its inferred result scheme without lowering,
initializing, or executing code, and without installing session bindings.
Trait kind displays use the inferred dictionary parameter kind with a `Constraint` result, rather than Core's
dictionary type result `Type`. This display metadata retains no
Core AST. `:help` lists commands and aliases. Expressions are compiled inside a
Unit thunk and formatted with qualified `Class.Debug.debug`. Successful
loads/imports/declarations replace the session
transactionally; failed operations preserve the previous snapshots and retained values.
Runtime errors are reported without leaving the REPL loop. Source snapshots
remain stable until an explicit successful reload. Object output paths remain
open.

## 9. Further versioned work

v1+ adds deprecation pragmas with one or more identifier targets and a string message. Preserve that metadata for use-site diagnostics and module interfaces; detailed targeting and warning policy remain to be specified. v1+ also admits declaration pragmas inside implementations, where groups, and local definition sequences. Preserve them as generic pragma nodes and validate per-directive placement; module pragmas remain module-only. Module-level `OPTIONS` pragmas use the ordinary identifier/string argument list; compiler-option interpretation is a separate semantic step. The accepted options, flags, warnings, and precedence relative to CLI options remain open.

The proposed library roots are `Ficus.Builtin`, `Class`, `System`, `Data`, and `Control`, with selected re-exports through `Prelude` (SPEC §24.5; PRELUDE §1). The proposed bootstrap policy gives every standard-library module, including Prelude itself, explicit imports and `NO_IMPLICIT_PRELUDE`. Use ordinary calls in bootstrap sources because v0 rejects `do` and interpolation under this pragma; builtin pragmas do not disable Prelude automatically. Keep primitive implementations in their trait-owning modules; primitive-named modules may be imported directly or aliased. The local module-name collision policy remains open. Implement the proposed v0 inventory in PRELUDE §1 only after its operation contracts are selected; Seq and Alternative follow the explicit thunk contracts in SPEC §16 and PRELUDE §6; Debug/Default contracts and Result/Either naming remain open. Check module-level non-expansiveness before initialization so later mutable-reference primitives cannot run implicitly during module loading. Preserve the ordinary thunk expressions and strict call order; do not insert automatic thunking for operators or add implicit memoization. Applicative includes Functor, Pure, and Seq; Alternative extends Applicative. Keep seqLeft/seqRight as derived functions and require explicit trait member implementations. Reconcile numeric traits and Void bootstrap without dropping existing contracts. No Control modules are planned for v0; Data.Map must not be implicitly re-exported by Prelude. Freeze and review an explicit Prelude export list before stabilizing its implicit API. Module availability, expanded APIs, and the JSON/regex interfaces remain open.

v2+ adds concurrency primitives, lazy arrows, a simple JavaScript backend with tail-call optimization, a simple build system, libraries beyond Prelude, dependency resolution, and FFI. v3+ considers WebAssembly GC or LLVM. Build configuration, package/dependency formats, dependency algorithms, FFI targets, and foreign calling conventions remain open.

## 10. Versioned language implementation work

The feature designs and their settled or draft status are grouped in SPEC.md, Sections 24–26. This section records their implementation requirements.

### 10.1 Empty types and matching

For v1+, extend parsing to accept empty type bodies and empty `with` blocks. Empty record and empty ADT bodies share `type T = {}`: both grammar alternatives can accept the same empty braces, and there is no field or constructor token to distinguish them. Handle this shared empty-body case explicitly so parser alternative ordering does not assign different meanings or synthesize a nullary record constructor. An empty type body is uninhabited and introduces no constructor at either source or runtime level. Reject `Void with {}` during constructor resolution/elaboration because `type Void = {}` provides no record constructor. Include positive fixtures for the declaration and `with x {}` elimination and a negative semantic fixture for `Void with {}`. Exhaustiveness checking must recognize an empty match on such a type as exhaustive and distinguish it from an empty match on a potentially inhabited type. Core validation and runtime lowering must support elimination with no alternatives; do not introduce a synthetic value or constructor for `Void`. This replaces the v0 builtin bindings for `Void` and `absurd`.

An optional warning for an empty type body may explain that it has no values and suggest `type Token = { Token }` if a unit-like type was intended. Keep this advisory; do not reject intentional empty types or replace them automatically.

### 10.2 Record patterns and mutable references

The v1+ mutable-reference API is settled as specified in `SPEC.md`. Continue enforcing the v0 value restriction so expansive local bindings such as `ref = newRef []` are not generalized; at top level these initializers are rejected unless they are acyclic definitions in a v1+ standalone module. The value restriction still applies to any admitted expansive initializer. Atomicity and interaction with fibers remain unspecified.

For v1+ record patterns, parse explicit-brace field patterns contextually, distinct from record construction. Permit them in `with` clauses, lambda/function arguments, non-recursive bindings, and both `do` binding forms (`<-` and `=`). Reject them in recursive `let` groups. During SCC analysis, reject top-level or `where` record-pattern bindings that participate in a cycle and suggest a named function with an internal `with` match. Resolve only the supplied labels, reject duplicate or unknown labels, and generate ignored slots for omitted value fields without creating binders. Permit an empty field pattern for a known nonempty record type. Compute irrefutability from the resolved record and supplied subpatterns using the same coverage checker; omitted fields are wildcards. Do not automatically accept a record pattern for `<-` if a supplied field can fail. Record punning is unsupported; require explicit labels and patterns.

### 10.3 Lazy arrows (v2+)

Elaboration inserts a non-memoizing thunk at each call-by-name argument and invokes it on every demanded variable use. Schematically, `and a b` becomes `and' (_ -> a) (_ -> b)`, where `and'` accepts `Unit -> Bool` thunks; repeated demands call the thunk repeatedly. Capture the call site's lexical environment without evaluating the argument or moving effects outside the thunk. Do not cache values or errors, hoist demanded work, or introduce common-subexpression sharing across demands. Strict local bindings retain their ordinary evaluate-once semantics. Non-variable/non-wildcard parameter matching forces once per matching attempt and binds components of that value; coverage proofs must not eliminate that force.

Retain the arrow's strict/call-by-name mode in type checking and typed Core until elaboration has made every demand explicit. Arrow modes must match for unification; neither arrow is a subtype of the other and no implicit coercion is inserted. Preserve source spans/provenance on thunks, forces, and pattern matches. Concrete Core/thunk representation remains open; evaluation and non-sharing are specified in SPEC §25.1. Planned parsing and effect-order cases are in `test/fixtures/lazy-arrows/`.

### 10.4 Exceptions (v1+) and fibers (v2+)

`Exception e` has no source-level methods, but typed `catch` needs nominal runtime identity for `e`. Nominal types such as `UserId` and `Int` can have identical erased value representations, and a polymorphic `Exception e => ...` cannot reconstruct `e` from a value after erasure. Preserve a nominal type token, either in non-erased exception evidence or in another runtime type representation carried through `throw`, `catch`, and fibers. Erasing `Exception e` to unit without such a token is invalid. The exact representation and matching mechanism remain open and block implementation of these operations. The proposed source APIs and their operational open questions remain in SPEC.md.

### 10.5 Existential packages (v1+ proposal)

Existential record type members remain v1+. Extend declaration and named `with` parsing to uppercase type-member labels and lowercase value-field labels. An uppercase label selects a type-expression RHS in construction or a lowercase type binder in patterns; do not require `@`. Parse the entire type RHS at its own nesting depth so function-type arrows cannot become enclosing lambda or clause arrows. Validate the resolved record member, kind, duplicate labels, and field types semantically. In `SomeException with { Err = String; showErr = (e : String) -> e }`, use the supplied witness while checking all value fields, independent of label order. In `SomeException with { Err = e; showErr = se }`, create a fresh abstract witness and scope it over the pattern's value bindings and permitted body; reject concrete type matching and witness escape.

Keep type members out of positional slots and out of the constructor's ordinary visible `@` parameters. Positional construction/matching contains only value fields; infer the witness during construction and open it anonymously during matching. Named patterns omitting the type member likewise open an anonymous witness. Only a named `with` member can explicitly supply or name the witness. Retain package evidence/dispatch needed at runtime; do not assume all witness evidence can be erased. Witness inference, records containing only type members, existential updates, and potential exception/fiber API revisions remain open. Versioned parser and semantic cases are in `test/fixtures/record-patterns/`; v0 type-directed coverage cases are in the parsing and type-checking fixture directories.

### 10.6 Private members and structural deriving

For `PRIVATE member`, retain the public type but exclude its ADT constructors or its record constructor and fields from exported interfaces. Check visibility for both positional and named construction/patterns and field access.

After generic pragma parsing, require `DERIVE` to have no arguments and attach it to the following top-level declaration, which must be an implementation. Read trait, type, and constraints from the ordinary implementation header. Reject any nonempty source body before generating members, including partially supplied methods; do not fill missing members or add fallback method behavior. Initially generate structural Show/Eq members, then run ordinary implementation validation, ownership/overlap checks, superclass resolution, and type checking against the written context without adding constraints. Preserve pragma, implementation, and type-declaration provenance on generated nodes. Generation rules remain open. Planned fixtures cover empty derived implementations, explicit contexts, and separate traits; negative fixtures cover pragma arguments, invalid targets, unsupported derivations, insufficient contexts, and partially or fully handwritten bodies, with diagnostic kinds and primary spans. Editor highlighting retains the generic known-directive rule.

### 10.7 Standalone module initialization

Interpret argument-free `STANDALONE` after generic pragma parsing and require module-level placement before imports. Record the module flag in source metadata and compiled interfaces. Check it on every import edge, including aliases, selective imports, re-exports, and implicit Prelude dependencies, and reject imports targeting standalone modules before their initialization. A standalone module may import ordinary dependencies; the pragma neither disables Prelude nor selects an entry.

Use dependency SCCs to limit the relaxed initializer check to acyclic top-level definitions, including their immediate `where` work. Keep recursive initializer safety, member checks, generalization restrictions, and initialization order unchanged. Compilation does not require main solely because the module is standalone; execution still validates main in the explicitly selected entry module. Planned fixtures cover expansive standalone initializers, deferred main validation, imported dependencies, and rejection of imports, expansive cycles, expansive implementation members, arguments, and invalid placement.

### 10.8 Eta expansion (v1+)

Attach ETA metadata only to its target binding; do not store it as a module or scope default or propagate it to sibling or nested bindings. After definition grouping and type inference establish the initializer's function type, elaborate argument-free ETA into one fresh unary lambda applying the original complete initializer to its parameter. Retain attached where initialization inside that delayed initializer and retain written-parameter metadata for its original internal application points. Use the directive/binding origin's span and provenance for generated nodes. Do not evaluate the initializer into a temporary outside the lambda or flatten across its work.

Perform initialization non-expansiveness, recursive lambda-protection, and value-restriction eligibility checks on the expanded initializer; ordinary signature, constraint, and source-based monomorphism checks remain in force. Do not generalize the original expansive initializer before expansion. Resolve bodyless, non-function, and pattern-binding targets as errors. The v1+ source fixture inventory is in `test/fixtures/eta/`; it is not wired into the scaffold runner. Planned checks cover top-level, implementation-member, where, expression-block, and do definitions, immediate where work, repeated effects on application, curried intermediate work, recursion checks, and invalid arguments/targets/placement.

## Frontend implementation API

`Ficus.Resolve.Provider.fileProvider` accepts explicit source roots and either
`PreludeFromRoots` or `PreludeFile path`. The latter supplies the source of the
canonical Prelude module without deriving its identity from the override filename.
Duplicate matching files are configuration errors; root order does not choose one.
`moduleIdentity` validates a path relative to an explicitly chosen root.
`discoverModules` accepts an injected provider and one or more entry identities;
it parses modules once and retains independent parse, lookup, and cycle errors.
`resolveGraph` and `resolveModule` accept independent resolver and sugar contracts.
Test support defines the fixture registry; the compile driver injects the separate
early-development library contracts. Resolution uses ReaderT for
lexical environments, State for IDs/diagnostics, and ExceptT for local recovery.
A failed declaration does not stop other declarations or modules; failed modules
are excluded from successful Abstract output. Consumers must check diagnostics
before compiling an entire graph. Inference owns typed safety and coverage checks.

Module directives are classified by a semantic pragma table, and retained in
ModuleOptions. Extending the table and option interpretation does not require
parser branches. STANDALONE and OPTIONS remain unavailable until their versioned
semantics are implemented. `Ficus.Error.Diagnostic.ToDiagnostic` adapts typed
phase diagnostics to a shared envelope; prettyDiagnostic handles any such value,
including warning severity and related source labels, without file IO.
