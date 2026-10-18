# Ficus Language Specification

## 1. Scope

Ficus is a strict, impure, expression-oriented functional language for scripting, with Hindley–Milner inference, nominal ADTs, structural products and lists, pattern matching, and single-parameter traits.

Sections 2–22 specify v0; Section 23 lists exclusions. Section 24 groups planned v1+ features, and Sections 25–26 track later and open designs. Planned features are unavailable in v0. Library APIs are non-normative unless stated otherwise. Implementation details belong in [IMPL.md](IMPL.md).

## 2. Source files and modules

Each file defines one module. Its path and filename determine its module name; there is no `module` declaration.

Relative to a configured source root, directory and file components form the dotted module path. For example, `Data/Map.ficus` defines `Data.Map`. Every component must be an uppercase identifier. A configured module provider may map a logical module path to a physical source file (including an explicit Prelude source file); module identity follows the logical path.

```text
use Foo
use Foo as F
use Foo (x, y, Z)
use Foo (..)

use Data.Map
use Data.Map (Map)
use Data.Map (..) pub
```

`use Foo` imports only the final module component as a local qualifier. For example, `use Data.Int` permits `Int.member`, not `Data.Int.member`. `as` replaces that qualifier: `use Data.Int as I` permits only `I.member`. An import list introduces its named public members; `..` introduces all public members.

Modules and types have separate namespaces: module `Data.Map` and type `Map` may coexist.

A bare or aliased import brings its module name or alias into the local module-name scope. An import list brings only the selected members into local scope. Primitive type names and `Type` may occur in module paths and may also be bound as local module names or aliases. Their module bindings are separate from the reserved type/kind bindings:

```text
use Data.Int        -- valid: binds the module name Int
use Data.Int (add)  -- valid: binds only add
use Data.Int as I   -- valid: binds the module name I
use Data.Int as Type -- valid: binds a module alias, not the kind Type
```

Multiple module imports may share a local qualifier. Repeated bindings emit a warning. Routes to the same module are deduplicated; distinct modules remain candidates. A qualified occurrence is resolved against the candidates that export its terminal name in the requested namespace: no candidate is a missing-export error, one canonical defining entity succeeds, and distinct defining entities are ambiguous. Import order never selects a winner. An unused qualifier conflict is permitted.

A type import may explicitly select ADT constructors:

```text
use Data.Maybe (Maybe(..))
use Data.Either (Either(Left))
use Data.Complex (Complex)
```

For an ADT, a bare type import imports only the type; `T(..)` also imports all its public constructors, and `T(Constructor,...)` imports the selected public constructors. For a record, importing its type automatically imports its public constructor and fields. Record member selections such as `Complex(real)` and `Complex(..)` are invalid. Imported fields remain nominal field labels, not standalone values. The outer `use Foo (..)` still imports all public module members. In v0 all members are public; the deferred private pragma can hide members in v1+.

`pub` after an explicit import list re-exports the imported members. It is invalid after a bare or aliased import:

```text
use Data.Map (Map) pub  -- valid
use Data.Map (..) pub   -- valid
use Data.Map pub        -- invalid
use Data.Map as M pub   -- invalid
```

Import conflicts are checked at use sites. Distinct imported entities with the same spelling in one namespace may coexist when unused; an occurrence requiring that name is an ambiguity error unless qualification or lexical scope selects one entity. This includes names brought in by implicit Prelude. Multiple import/re-export routes to the same defining entity do not create ambiguity. Import order does not select a winner. Missing modules, nonexistent exports, and invalid member selections remain errors even when the imported name is unused.

Publishing an ambiguous name is also a use: `pub` re-exports must provide a unique defining entity for each exported spelling and namespace. Distinct entities exported under the same name are rejected at the re-export, even without an expression using them. Re-exporting the same entity through multiple routes is valid. Module qualifier conflicts follow the same use-site principle, as described above.

Imports are initialized once, in source order, before the importing module. Import cycles are static errors.

All top-level declarations are public in v0. Private pragmas are planned in Section 24.4.

Pragmas occur only at global declaration level in v0. v1+ extends declaration-level placement to implementation members, `where` groups, and local definitions; each directive retains its own target and placement requirements. Each block contains an ALL_CAPITAL name followed by whitespace-separated identifiers or strings. Every pragma uses the same syntax; its arguments, placement, and meaning are checked semantically. Module pragmas appear before imports; declaration pragmas appear among top-level declarations. `NO_IMPLICIT_PRELUDE` disables implicit Prelude and its dependent sugar. `BUILTIN` does not disable Prelude (Section 19). Private/deprecation pragmas are planned in Section 24.4; `FOREIGN` is planned in Section 25.

## 3. Lexical structure

Source is Unicode and case-sensitive. Lowercase identifiers name values, fields, and type variables. A lowercase identifier starts with a lowercase Unicode letter or `_`, followed by identifier characters; `_` and names such as `_value` are both lexed as ordinary lowercase identifiers. Uppercase identifiers name modules, types, constructors, and traits. A symbolic name beginning with `:` belongs to the uppercase namespace and may name a constructor or type. Name resolution gives the exact spelling `_` its wildcard or hole meaning according to position; names beginning with `_` have no special meaning.

Hard keywords are:

```text
use type trait impl with if where do
```

`as` and `pub` are soft keywords in import declarations. `True` and `False` are lexed and parsed as ordinary uppercase identifiers; their constructor meanings are reserved semantically.

Line comments begin with `--` only when it is not followed by another operator character; `-->` is one operator token, while `-- text` is a comment. A bare `--` at end of line is a comment. Block comments begin at every `{-` outside a string or character literal and end at the next `-}`; they do not nest. Thus `{-x}` starts an unterminated block comment, not a braced expression. Pragmas use `{-#` and `#-}` and take precedence over ordinary block comments.

Literals include decimal integers and floats, characters in single quotes, and strings in double quotes. An integer literal such as `1` has type `Int`; a literal with a decimal point such as `1.0` has type `Float`. Numeric literals are not overloaded. `Int` values are signed 64-bit integers, and integer arithmetic wraps modulo 2^64. `Float` values use IEEE 754 binary64. Character and string escapes include `\\`, `\'`, `\"`, `\n`, `\r`, and `\t`. Strings additionally accept `\{` and `\}` for literal braces.

A symbolic operator is a nonempty sequence of operator characters, using maximal munch after comment and reserved-token recognition. A dot may occur within an operator only when flanked on both sides by non-dot operator characters, as in `+.+`; it cannot begin or end one. A colon-led operator is an upper operator; every other operator is a value operator. Bare `@`, `:`, `=`, `->`, `<-`, `=>`, and `.` are reserved in their grammatical roles. `..` is reserved for import lists and is invalid as an expression operator. `::` is lexed and parsed as an ordinary upper operator but has reserved list-constructor semantics.

A qualification or field-projection dot permits surrounding whitespace, subject to layout and block boundaries. `x.field`, `x .field`, `x. field`, and `x . field` have the same meaning. This also applies to module paths and qualified names, such as `People . default . name`. `1.foo` and `1 . foo` are syntactically projections but fail typing because `Int` has no fields. Float tokens, `..`, and dots embedded in symbolic operators such as `+.+` retain their lexical meanings.

## 4. Layout

Tabs use four-column stops (columns 1, 5, 9, and so on) for indentation and source positions. A tab advances to the next stop; spaces advance one column.

Layout applies only at grammar positions requiring `block1` or `block`. An indented block is equivalent to an explicit block with `{`, `;`, and `}` delimiters, using the indentation rules below.

If the next token is not `{`, a layout block begins at that position. Its first token sets the block indentation. A later token at the same indentation starts an item; smaller indentation ends the block; greater indentation continues the current item. Blank lines and comments do not affect layout.

Explicit blocks use braces and semicolons:

```text
f x = { y = g x; h y }
```

A block is either layout-controlled or explicitly braced. Nested blocks choose independently. Every expression block is nonempty and ends in an expression.

An expression block starts only with explicit `{` or with a newline and greater indentation immediately after an expression introducer: `=` in a value, pattern, or record-field declaration; `<-` in a `do` bind; or `->` in a lambda, `if` clause, or match clause. A single expression on the current line, such as `1`, is an `operator_expr`, not a one-item layout block. Nested blocks have their own layout depth, so a `=` or `<-` inside one cannot classify a surrounding item.

A leading separator dot continues an expression only where ordinary layout permits continuation. It does not suppress a new item or a block boundary:

```text
result =
  foo
    .bar
    .baz
-- equivalent to result = (foo.bar).baz

invalid =
  foo
  .bar  -- invalid: a new block item cannot begin with a dot
```

Both continuation lines are deeper than the active block indentation; neither needs to be deeper than the preceding continuation line.

For prefix `with`, the scrutinee ends at the following explicit `{` or at the newline that opens a more-indented match-clause block. Tokens in that new block cannot continue the scrutinee as application arguments. An unparenthesized multiline scrutinee must use an explicit enclosing expression block or parentheses. For `if` and `do`, the keyword itself is followed by an explicit or layout block. A postfix record `with` likewise requires `{` or a newline and greater indentation for its field block; the closing `}` or dedent ends the record expression before a following application argument.

For a multiline dotted scrutinee, parentheses preserve the prefix `with` boundary:

```text
with (foo
  .bar
  .baz)
  Pattern -> result
```

## 5. Grammar

Block delimiters may be explicit or supplied by the layout rules in Section 4. Section 14 defines operator grouping.

```ebnf
module          = { pragma }, { use_decl }, { top_decl } ;
top_decl        = type_decl | type_alias
                | trait_decl | impl_decl | signature | value_decl
                | pragma ;

use_decl        = "use", module_name,
                  [ "as", upper_ident
                  | "(", import_items, ")", [ "pub" ] ] ;
import_items    = ".." | import_item, { ",", import_item } ;
import_item     = upper_name, [ "(", import_members, ")" ]
                | lower_ident | operator_name ;
import_members  = ".." | import_member, { ",", import_member } ;
import_member   = ident | operator_name ;
module_name     = upper_ident, { ".", upper_ident } ;

pragma          = "{-#", pragma_name, { pragma_arg }, "#-}" ;
pragma_name     = ALL_CAPITAL identifier matching [A-Z][A-Z0-9_]* ;
pragma_arg      = ident | operator_name | string ;
signature       = signature_name, ":", signature_type ;
signature_type  = { type_quantifier, "->" }, type_expr ;
type_quantifier = "{", lower_ident, [ ":", kind_expr ], "}" ;
value_decl      = pattern_head, "=", expr, [ where_clause ] ;
pattern_head    = binding_name, { type_binder }, { binder_pattern } ;
type_binder     = "@", lower_ident | "@", "(", lower_ident, ":", kind_expr, ")" ;
where_clause    = "where", block1(local_decl) ;
local_decl      = signature | value_decl | pattern_decl ;
pattern_decl    = binding_pattern, "=", expr, [ where_clause ] ;
binding_pattern = pattern excluding a bare binding_name or infix head ;

type_alias      = upper_name, { type_param }, "=", type_expr ;
type_decl       = "type", upper_name, { type_param }, "=", type_body ;
type_param      = lower_ident | "(", lower_ident, ":", kind_expr, ")" ;
kind_expr       = kind_atom, [ "->", kind_expr ] ;
kind_atom       = upper_name | qualified_type | lower_ident | "(", kind_expr, ")" ;
type_body       = block1(constructor_decl) | block1(field_decl) ;
constructor_decl= upper_name, { type_atom } ;
field_decl      = lower_ident, ":", type_expr ;

trait_decl      = "trait", [ constraints, "=>" ], upper_ident, type_param,
                  "=", block(signature) ;
impl_decl       = "impl", [ constraints, "=>" ], trait_ref,
                  "=", block(value_decl) ;
trait_ref       = upper_ident, type_atom ;
constraints     = constraint | "(", constraint, { ",", constraint }, ")" ;
constraint      = trait_ref ;

expr            = lambda_expr | if_expr | with_expr | do_expr
                | block_expr | operator_expr ;
non_lambda_expr = if_expr | with_expr | do_expr
                | block_expr | operator_expr ;
lambda_expr     = [ type_binders ], binder_pattern, { binder_pattern }, "->", expr
                | type_binders, "->", expr ;
type_binders    = type_binder, { type_binder } ;
operator_expr   = prefix_expr,
                  { (value_operator | upper_operator), prefix_expr } ;
prefix_expr     = "-", prefix_expr | application ;
application     = postfix_expr, { "@", type_atom }, { postfix_expr } ;
postfix_expr    = atom, { ".", ident | "with", block1(record_field) } ;

if_expr         = "if", block1(if_clause) ;
if_clause       = non_lambda_expr, "->", expr ;
with_expr       = "with", expr, block1(match_clause) ;
match_clause    = pattern, [ "if", non_lambda_expr ], "->", expr ;
do_expr         = "do", block1(do_stmt) ;
do_stmt         = pattern, "<-", expr | value_decl | pattern_decl | expr ;
block_expr      = block1(block_item) ;
block_item      = local_decl | expr ;

atom            = lower_ident | upper_ident | literal | unit_expr | product_expr
                | list_expr | operator_ref | paren_expr ;
literal         = integer | float | char | string ;
operator_ref    = operator_name | module_name, ".", operator_name ;
paren_expr      = "(", expr, ")" | "(", expr, ":", type_expr, ")" ;
unit_expr       = "(", ")" ;
product_expr    = "(", expr, ",", expr, { ",", expr }, ")" ;
list_expr       = "[", [ expr, { ",", expr } ], "]" ;
record_field    = lower_ident, "=", expr, [ where_clause ] ;

pattern         = simple_pattern, { upper_operator, simple_pattern } ;
simple_pattern  = lower_ident | literal_pattern | "()"
                | constructor_pattern | product_pattern
                | list_pattern | annotated_pattern | "(", pattern, ")" ;
binder_pattern  = lower_ident | literal_pattern | "()"
                | upper_ident | product_pattern | list_pattern
                | annotated_pattern | "(", pattern, ")" ;
annotated_pattern = "(", pattern, ":", type_expr, ")" ;
constructor_pattern = (upper_name | qualified_constructor), { binder_pattern } ;
qualified_constructor = module_name, ".", upper_name ;
product_pattern = "(", pattern, ",", pattern, { ",", pattern }, ")" ;
list_pattern    = "[", [ pattern, { ",", pattern } ], "]" ;
literal_pattern = literal | negative_number ;
negative_number = "-", (integer | float) ;

type_expr       = [ constraints, "=>" ], function_type ;
function_type   = product_type, [ "->", function_type ] ;
product_type    = type_operator_expr, { "*", type_operator_expr } ;
type_operator_expr = type_application, { upper_operator, type_application } ;
type_application= type_atom, { type_atom } ;
type_atom       = lower_ident | upper_name | qualified_type
                | list_constructor | product_constructor | function_constructor | list_type
                | "(", type_expr, ")" ;
list_constructor = "[", "]" ;
product_constructor = "(", "*", ")" ;
function_constructor = "(", "->", ")" ;
qualified_type  = module_name, ".", upper_name ;
list_type       = "[", type_expr, "]" ;

block1(X)       = "{", X, { ";", X }, [ ";" ], "}" ;
block(X)        = "{", [ X, { ";", X }, [ ";" ] ], "}" ;
binding_name    = lower_ident | "(", value_operator, ")" ;
signature_name  = binding_name | upper_name ;
upper_name      = upper_ident | "(", upper_operator, ")" ;
operator_name   = "(", (value_operator | upper_operator), ")" ;
ident           = lower_ident | upper_ident ;
value_operator  = operator_symbol not beginning with ":" - reserved_operator ;
upper_operator  = operator_symbol beginning with ":" - ":" ;
```

Lexical productions are defined in Section 3.

`if` conditions and pattern guards exclude unparenthesized lambdas to disambiguate the clause arrow. Parenthesized lambdas are allowed. Nested conditionals require their own delimited blocks: `if { if { _ -> True } -> True; _ -> False }` is valid, but `if if if _ -> True -> True -> True` is not.

`_` has ordinary identifier syntax: it is a wildcard in binders and patterns, an unconditional fallback as a whole `if` condition, and a hole in expression, type, or kind positions (Section 7.4). It never denotes a source name.

A declaration `_ = expr` is an anonymous wildcard binding: it retains the initializer and its ordinary strict evaluation, initialization restrictions, and attached `where` timing, but introduces no value identity, scope entry, or export. Repeated wildcard bindings are independent declarations in source order, not duplicate definitions or function clauses. This form is allowed at top level, in `where` groups, and in expression-block and `do` declarations.

A wildcard head cannot take value or `@` parameters: `_ x = x` and `_ @a = expr` are invalid because those forms require a function name; `_ = x -> x` discards a function expression instead. `_ : Int` is not a valid signature target. `_` cannot name a field or method, be an import selection or qualified member, or be a `BUILTIN` target. Type parameters, explicit type binders, and signature quantifiers also require names other than `_`. These restrictions are checked semantically, without parser special cases. `_name` remains an ordinary name.

`binder_pattern` is deliberately self-delimiting so adjacent function parameters remain unambiguous. Atomic, product, and list patterns may be binders directly. A constructor application or infix pattern must be parenthesized to form one binder:

```text
fromMaybe fallback (Just value) = value
uncons (x :: xs) = (x, xs)
mapPair f (x, y) = (f x, f y)

mapper = (Just value) fallback -> value
```

Without parentheses, adjacent atomic patterns denote separate binders.

Declaration heads cannot be infix patterns, even when parenthesized: `x :: xs = value` is invalid in every declaration context. Top-level definitions require a binding name or a standalone wildcard head `_`; local and `do` `=` definitions also admit non-infix patterns such as `(a, b)`, `Just x`, and `[x, y]`. `(++) xs ys = ...` names a value operator and is valid. Infix patterns remain valid as parenthesized function arguments; `do` `<-` accepts them only when type-directed coverage proves them irrefutable (Section 10).

### 5.1 Qualification and shared syntax

In an upper-identifier-led dotted chain ending in an uppercase name, the preceding uppercase components must name a visible module qualifier and the final one names an exported type in a type expression or an exported constructor in a term or pattern. When a lowercase segment follows an uppercase prefix, the whole uppercase prefix must name a visible module qualifier and the first lowercase segment names its exported value; later lowercase segments are field projections of that value. Constructors cannot be projected from directly: `Person.name` names value `name` from module `Person` or is rejected; `B.c` names `c` from the module bound as `B` (for example by `use A.B`); canonical module paths do not themselves introduce qualifiers. Modules are not values. `(Person "Ada" 36).name` projects a constructed value.

Shared syntactic prefixes have the following meanings at the current nesting and layout depth:

- In a `do` block, `<-` selects a pattern bind, `=` selects a named or pattern declaration, and the absence of either selects an expression statement. Declaration statements have the strict sequential binding and generalization rules of expression blocks.
- In an expression block, `:` selects a local signature, `=` selects a named or pattern declaration, and the absence of either selects an expression.
- At top level, an upper name followed directly by `:` introduces a kind signature; an upper name followed by optional type parameters and `=` introduces a type alias.
- At the start of an expression, binder patterns followed by `->` form a lambda; otherwise the expression follows the operator-expression grammar.
- Prefix `with expr block1(match_clause)` is pattern matching. Postfix `with block1(record_field)` is named construction when its receiver resolves to a bare or module-qualified record constructor, and record update when its receiver has a nominal record type. Field completeness does not select between these meanings.

Delimiters inside nested blocks do not classify an outer item: `Person with` followed by an indented `name = "x"` is one record expression, not an outer declaration.

## 6. Names and scope

Values, constructors, fields, and modules have their respective namespaces; types and traits share one namespace. A type and a trait with the same name cannot coexist in one scope. Multiple pattern clauses defining one value form a single binding and are matched in source order. Duplicate local declarations in one namespace and scope, other than clauses of that binding, are errors, with module qualifiers handled by the warning and use-site rules in Section 2.

All clauses of one named function binding must have the same **written value arity**: the number of value parameter patterns before `=`. Each pattern counts as one parameter, including a product or parenthesized constructor pattern. Explicit `@` type binders do not count. A signature's arrow count, a lambda returned by the right-hand side, and later eta expansion do not change this arity. A mismatch is a static error before the clauses can be combined:

```text
foo x 1 = 0
foo x = y -> y  -- invalid: one written value parameter instead of two

bar x 1 = 0
bar x y = y    -- valid: both clauses have two parameters
```

This applies wherever clauses belong to one binding, including top-level, mutually visible `where` groups, and implementation members. Separate sequential bindings that shadow the same spelling remain separate bindings; their arities need not agree. Repeated zero-parameter definitions remain duplicate declarations, not alternative pattern clauses.

Scope is lexical and innermost-first. Sequential bindings in an expression or `do` block may shadow earlier local bindings, including bindings in the same block; each later right-hand side still sees the previous binding until its own initializer finishes. Shadowing emits a warning. Names within one mutually visible `where` or top-level group, and duplicate names within one pattern, remain duplicate-declaration errors. Import collisions among values, types, and constructors are errors only when a name is used or ambiguously re-exported; resolve such uses by qualification, selective imports, or ordinary lexical scope; colliding local module qualifiers follow Section 2.

Lambda parameters scope over their body. Pattern variables scope over the corresponding guard and branch. A sequential binding scopes over later block items only. A `where` name scopes over its whole group and the expression preceding `where`.

All top-level declarations in a module are mutually visible.

Aliases, selective imports, and re-exports preserve declaration identity, including for Prelude-dependent sugar and builtin bindings.

## 7. Types

The primitive atomic types are:

```text
Int Float Bool Char String Unit
```

`Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` are reserved primitive type names and are in scope in every module, including modules with `NO_IMPLICIT_PRELUDE`. `Type` is the reserved kind name for ordinary types. These names cannot be rebound in their respective type/kind namespaces. They may be components of a module path or local module names/aliases: after `use Data.Int`, bare `Int` in a type expression remains the primitive type, while `Int.member` uses the module qualifier. A module with a primitive spelling gains no ownership of that primitive type.

Built-in expression types are fixed:

```text
1     : Int
1.0   : Float
-1    : Int
-1.0  : Float
'a'   : Char
"a"   : String
True  : Bool
()    : Unit
```

Function, product, and list types are structural:

```text
a -> b
a * b * c
[a]
```

`->` associates right. Product types are binary and right-associative:

```text
A * B * C = A * (B * C)
```

Parentheses group types. Products require at least two components.

Lists, binary products, and functions also expose their constructors as type atoms:

```text
[]  : Type -> Type
(*) : Type -> Type -> Type
(->): Type -> Type -> Type
```

`[a]` is equivalent to `[] a`, `a * b` to `(*) a b`, and `a -> b` to `(->) a b`. The constructor forms allow partial application and implementation heads such as:

```text
impl Functor [] = ...
impl Bifunctor (*) = ...
impl Functor ((->) r) = ...
```

`[]`, `(*)`, and `(->)` are reserved built-in type-constructor names and cannot be rebound in the type namespace. This does not reserve the value-level multiplication operator `(*)`.

### 7.1 Algebraic data types

`type` introduces a nominal type and constructors:

```text
type Maybe a =
    Nothing
    Just a
```

For `type T a = C A B`, `C : A -> B -> T a`. Constructor application is curried and strict. Symbolic constructor and type names are parenthesized in name or prefix positions and bare in infix use:

```text
type Chain a =
    End
    (:+) a (Chain a)

type (:+:) f g = ...
```

Single-field ADTs and records remain nominal, with strict construction and matching:

```text
type UserId = UserId Int
```

`UserId` and `Int` are distinct types, including for trait ownership and implementation selection.

### 7.2 Records

A record is a nominal type:

```text
type Person =
    name : String
    age : Int
```

Its type name is a positional constructor in declaration order:

```text
Person : String -> Int -> Person
Person "Ada" 36
```

Named construction supplies every field exactly once:

```text
Person with
    name = "Ada"
    age = 36

People.Person with { name = "Ada"; age = 36 }
```

Named fields may appear in any order and evaluate in source order. `person.name` projects a field. Record patterns are deferred; initial-language matching uses the positional constructor.

Field labels are local to their nominal record type, so different record types may reuse a label. Projection binds tighter than application regardless of whitespace: `f x . field` means `f (x.field)`; projecting the result requires `(f x) . field`. Projection chains associate left:

```text
person.address.city
= (person.address).city
```

For `e.field`, the receiver must resolve to a nominal record containing `field`; the result has its declared field type. A label alone never selects a record type. Variables dependent on an unresolved projection remain monomorphic, including across inner binding groups; field constraints cannot be generalized. Enclosing uses may determine the receiver, but an unresolved receiver at module end, a non-record receiver, or a missing field is a type error. Thus unconstrained `getName p = p.name` is invalid, while an inner `where` projection may wait for enclosing uses to fix `p`'s type.

Dotted module qualification is resolved before projection. A qualified value expression consists of a known module path, one exported lowercase value, then zero or more lowercase field projections. Qualified constructors are allowed in construction and patterns but cannot be projected from directly:

```text
People.default.address.city
```

Here `Data.People` is the module, `default` is its exported value, and `address.city` is a projection chain. Section 5.1 defines the qualified value boundary.

Postfix `with` on a bare or module-qualified record constructor is named construction; it requires every field exactly once. On an existing nominal record value it is an update, even when every field is supplied:

```text
older (person : Person) = person with { age = person.age + 1 }
```

An update supplies at least one replacement field. Omitted fields retain their values. Replacement labels must be distinct and belong to the receiver's nominal record type; labels alone do not select that type. The result preserves the receiver's complete type, including its type arguments, and each replacement must have the corresponding field type. Unresolved record receivers are checked under the same deferred, monomorphic field-constraint rules as projection. Constructor-valued functions are not existing records and do not become named-construction targets through a value alias.

Projection and record `with` suffixes bind tighter than application and associate left in source order:

```text
f person with { age = 37 }     -- f (person with { age = 37 })
(f person) with { age = 37 }   -- update the call result
person.address with { city = "Paris" }
(person with { age = 37 }).age
person with { age = 37 } with { name = "Ada" }
```

Applications, lambdas, conditionals, and matches used as update receivers require parentheses. Prefix matches may contain postfix construction or update as their scrutinee, provided the field and clause blocks are separately delimited; parentheses make the boundary explicit:

```text
with (person with { age = 37 }) { Person name age -> age }
```

An update evaluates its receiver exactly once, then replacement initializers left-to-right in source order, and produces a new record without mutating the receiver. Unchanged reference-valued fields retain their references; updating the enclosing record does not copy the referenced mutable contents. Field initializers use ordinary lexical scope, not an implicit binding of old fields. Each field may have a `where` group scoped only to its initializer, with the ordinary initialization timing. Updates are expansive expressions for initialization and generalization checks.

Construction, update, and the proposed record patterns require explicit `label = expression` or `label = pattern` fields. Duplicate labels and punning such as `{ age }` are invalid; field labels are not standalone values. Updates of records with existential type members remain open and are not admitted by this v0 rule.

The record field block must start with `{` or on a more-indented next line. `f Person with x = 1 y` is invalid because no field block starts after `with`. In `f (Person with { x = 1 }) y`, the braces delimit construction before `y` is parsed as the next argument.

### 7.3 Aliases, signatures, and annotations

A declaration without `type` normally defines a transparent, non-recursive alias:

```text
Point = Int * Int
Parser (a : Type) = String -> [a * String]
```

Literals are not type or kind expressions, including type arguments: `T 1`, `T 'a'`, and `T "tag"` are invalid.

A signature names exactly one identifier or parenthesized operator name before `:`. This applies to value, kind, and trait-member signatures. `ident1, ident2 : T` and `ident1 ident2 : T` are invalid; write separate signatures. Parameters belong on definitions, not before the colon in a signature.

Signatures constrain inferred types. An annotation `(e : T)` constrains `e`;
it does not pass a runtime type argument. Expressions also accept a trailing
annotation without outer parentheses, as in `x = 2 : Int` and
`sum x y = x + y : Int`. The annotation binds less tightly than application and
all expression operators, so the latter constrains the whole `x + y` expression.
A bare trailing annotation cannot have an outer function arrow or constraint:
write `f : (Int -> Int)` or `(f : Int -> Int)`, and parenthesize constrained types
likewise. This keeps bare lambda and clause arrows unambiguous. Annotated
binders and patterns still require parentheses. In an expression block,
`x : Int` at the start of an item remains a local signature; use `(x : Int)`
when the item is an annotated expression. In a `do` block, a bare name followed
by `:` is still an invalid signature item; parenthesize the annotation there.

Patterns may carry parenthesized type annotations wherever patterns or binder patterns are accepted, including function and lambda arguments, constructor arguments, nested product/list patterns, match clauses, local pattern declarations, and `do` bindings:

```text
foo (x : Int) = x
(x : Int) y -> x + y
with value { Just (x : Int) -> x; Nothing -> 0 }
```

An annotation constrains the whole annotated pattern's type without changing its bindings or refutability. All existing restrictions on patterns and declaration heads still apply. In v0, pattern annotations may mention named type variables only when scoped by explicit `@` binders (below): `foo (x : a) = x` is rejected, even if a separate signature mentions `a`. With an explicit binder, `foo @a (x : a) = x` is valid. Concrete types and inference holes `_` are allowed; an annotation does not implicitly bind or quantify type variables.

Without a following outer lambda arrow or a pattern context, `(x : Int)` is an expression annotation. In `(f : Int -> String) -> f 1`, the arrow inside parentheses belongs to the type. Bare `x : Int -> x` is invalid. Parentheses keep annotated patterns self-delimiting; existing outer `=`, `<-`, and `->` delimiters distinguish declarations, binds, and lambdas.

Type aliases may have an optional top-level kind signature, checked against the definition. Parameters of aliases, ADTs, records, and traits may carry parenthesized kind annotations; bare parameters have their kinds inferred. Type parameters bind lowercase names and cannot match types: `Alias Int = ...` and `Alias (Maybe a) = ...` are invalid. An alias must always be fully applied where used, and aliases may not form direct or indirect cycles:

```text
Parser : Type -> Type
Parser a = String -> [a * String]

type Box (a : Type) = Box a

type Container (f : Type -> Type) a = Wrap (f a)

trait Functor (f : Type -> Type) =
    map : (a -> b) -> f a -> f b
```

`Type` denotes the kind of ordinary types. Kind annotations do not pass runtime arguments. Aliases require definitions. Each `_` in a kind signature is inferred independently from its declaration; unconstrained kind variables default to `Type` with a warning.

Recursive ADT definitions must be regular: a recursive occurrence uses that ADT's declared type parameters unchanged and in the same order. Non-regular recursion such as `type Nest a = Wrap (Nest [a])` is a static error, including when it passes through a mutually recursive group.

#### Explicit type binders and application (v0)

Value signatures may begin with ordered type binders `{a}` or `{a : Kind}`. Unbound type variables in an ordinary signature retain implicit outermost quantification; explicit type application addresses only the explicitly written binders, in their declared order. Explicit binders are not permitted on kind signatures.

```text
id : {a} -> a -> a
id @a (x : a) = x

duplicate : {a} -> a -> (a * a)
duplicate = @a (x : a) -> (x, x)

value () = id @Int 1
items () = id @[Int] [1, 2]
```

At the beginning of definition or lambda parameters, `@a` binds a type variable over subsequent parameter annotations, the body, and its attached `where` group. `@(f : Type -> Type)` also supplies a kind annotation. Type binders precede all value parameters and bind distinct names, never match concrete types; `_` is not a binder name. A definition's explicit binders correspond positionally to its signature's explicit binders; local binder names may differ. When no signature is supplied, retain the written binder order in the inferred scheme and check the body with those variables abstract. Signature variables alone do not enter the definition's annotation scope.

In an application, `@T` supplies one type atom. Compound types require parentheses, for example `foo @(List Int)` or `foo @(Int -> String)`. Supplied types must have the binder's kind. Omitted explicit arguments are inferred by ordinary instantiation; `@_` skips one position with an inference hole. All written type arguments precede value arguments, and excess arguments are errors. Bare `@` is reserved punctuation; longer operators retain maximal munch. Braces remain expression-block delimiters in terms: `foo {Int}` is not type application. `with foo @Int { ... }` has an unambiguous match-block boundary.

The enclosing syntax determines the role of a shared prefix. `foo @a bar = body` is a named definition; `@a bar -> body` is a lambda; `foo @a bar` is an application. As a standalone expression, `foo @a bar -> body` is invalid: a lambda cannot put a type binder after the value binder `foo`. In `if { foo @a bar -> body; _ -> fallback }`, however, `foo @a bar` is the non-lambda condition and the arrow starts its clause body. The same rule applies to match guards. Arrows inside parenthesized type arguments or kind annotations do not delimit the enclosing clause or lambda.

Type binders and applications are static and do not add runtime parameters, evaluate arguments, or delay work. Non-expansiveness classifies their underlying term, so a type-only application of a non-expansive value remains non-expansive. They do not provide lambda protection for recursive initialization or make an expansive initializer non-expansive. Written-parameter counts for `where` timing count only value parameters. Trait dictionary parameters have the separate initialization rule in Section 16. Polymorphic type abstractions remain subject to ordinary rank-1 generalization, value, and monomorphism restrictions; they cannot be passed as polymorphic function arguments in v0.

v0 permits quantifiers only in the outermost value-signature prefix. Nested quantifiers are rejected, including the higher-rank signature `foo : ({a} -> a -> a) -> (b * c) -> (b * c)`. Higher-rank checking remains future work; retaining `{a}` in signatures does not enable it.

### 7.4 Type signature holes

`_` in a value signature, expression annotation, or pattern annotation is an independent type hole of any inferred kind. The completed type retains inferred predicates and obeys ordinary signature checks and the value restriction.

```text
double : Int -> _
double x = x + x
-- completed as Int -> Int

foo : _ -> _ _ Int
foo x = (1, x)
-- completed as Int -> (Int * Int)
```

In the second example, the constructor hole becomes `(*)` and its argument hole becomes `Int`. Type holes require a value definition, annotated expression, or annotated pattern; they are invalid in aliases, data bodies, trait signatures, implementation heads, and other type-only positions. Kind holes are allowed as specified in Section 7.3.

Standalone `_` is a wildcard in binders and patterns, and an expression hole elsewhere. An expression hole does not immediately abort inference or elaboration: the compiler continues checking the surrounding program using a typed placeholder, collecting constraints and independent diagnostics. After checking, each hole is a hard error whose diagnostic shows its inferred or expected type (including remaining variables), source location, relevant in-scope bindings and their types, and any constraints still blocking the goal. A hole remains an error even when its type is fully known; type inference does not fill in the missing expression. Expression holes may remain in Core AST for continued elaboration and diagnostics, but their presence prevents successful compilation. Lowering from Core to Runtime AST must independently report an error if any expression hole is found, including in unused bindings or unselected branches; it must not erase the hole or replace it with a runtime stub or failure. Runtime AST contains no expression holes.

## 8. Built-in algebraic forms

`Unit` has the sole value and pattern `()`.

`Bool` has predefined nullary constructors `True` and `False`. They are always available and cannot be rebound, shadowed, or imported as different entities. Conditions require `Bool`; truthiness is not overloadable.

Products are binary. Surface n-component values and patterns are right-associated sugar:

```text
(a, b, c) = (a, (b, c))
```

Components evaluate left-to-right.

Lists are structural:

```text
[a]          -- type
[]           -- empty value or pattern
[x, y]       -- literal or pattern
x :: xs      -- construction or pattern
```

List literals denote nested `::` ending in `[]`; elements evaluate left-to-right.

`::` is the predefined list constructor:

```text
(::) : a -> [a] -> [a]
```

`::` is always available and cannot be rebound, shadowed, or imported as a different entity. Its spelling determines its precedence and right associativity (Section 14).

## 9. Expressions and bindings

Evaluation is strict, call-by-value, deterministic, and left-to-right.

Application is curried and binds tighter than infix operators. `f a b` evaluates `f`, then `a`, applies, then evaluates `b` and applies again. Written parameters are nested lambdas; attached `where` initialization follows Section 12. Lambdas capture lexical scope. A failed parameter pattern raises a runtime match error.

An expression block evaluates items in order and returns its last expression. A block containing exactly one expression and no declarations is equivalent to that expression, including for initialization and generalization restrictions (Sections 12, 15–16). A local named declaration evaluates its right side immediately and binds the name; a local pattern declaration evaluates its right side once, matches the non-infix head pattern, then binds its variables for later items. A failed local pattern is a runtime match error. Sequential shadowing is permitted with a warning as specified in Section 6.

```text
swap pair =
    (a, b) = pair
    (b, a)
```

Constructors, products, lists, positional record fields, and named record fields evaluate left-to-right. Record updates evaluate the receiver once before replacement fields in written order. Field projection evaluates its receiver first.

Unary `-` accepts `Int` or `Float` and returns the same type. It is compiler-defined and remains available without Prelude. It binds more tightly than infix operators but less tightly than application:

```text
-f x    = -(f x)
-x * y  = (-x) * y
f - 1   = f - 1
f (-1)  = f applied to -1
```

Whitespace does not change this parse. Prefix `-` may begin an operand but never a fresh unparenthesized application argument, so `f -1` is subtraction and a negative argument must be written `f (-1)`.

Negative numeric patterns use the same sign syntax, for example `-1` and `-1.0`. The sign is parsed syntax, not part of the numeric token.

## 10. Pattern matching

`with e` evaluates `e` once and tries clauses top-to-bottom:

```text
with value
    Just x -> x
    Nothing -> fallback
```

A pattern fails or binds variables. Repeated variables in one pattern are invalid. Constructor, product, and list patterns require the corresponding shape. Literal patterns compare same-typed primitive values.

Refutability is determined after name resolution and type checking, using the same type-directed coverage analysis as exhaustiveness checking; it is not a syntactic category. A pattern is irrefutable when it covers every possible value of its inferred scrutinee type. Variables and wildcards cover any type; product and single-constructor patterns are irrefutable when their component patterns are. For example, `Box x` is irrefutable for `type Box a = Box a`, while `Just x` is refutable for `Maybe a` and `Box 0` is refutable for `Box Int`. Constructor spelling, prefix/infix notation, parentheses, and annotations do not independently decide refutability. Ordinary literal and fixed-length list patterns are refutable for their primitive/list types.

A `do` `<-` bind requires a pattern proved irrefutable for the bound result type. Parse all otherwise supported patterns there; reject a refutable pattern, or one whose total coverage cannot be established, during type/coverage checking with the pattern as the primary span. Other pattern positions retain their ordinary match-failure behavior and exhaustiveness diagnostics. These checks do not change the separate syntactic restrictions on declaration heads or the self-delimiting syntax of binder patterns. Uninhabited-subpattern coverage remains future work (Section 24.1).

Symbolic uppercase constructors may be used in prefix or infix patterns:

```text
(:+) x xs  -> ...
x :+ xs    -> ...
x :: xs    -> ...
People.Person name age -> ...
```

After a pattern matches, its optional guard runs. A false guard continues with the next clause. If none succeeds, evaluation raises a match error.

Implementations should warn about detectable non-exhaustive or redundant matches, but neither is a static error.

## 11. Conditionals and guards

The sole conditional is multi-way `if`:

```text
if
    x < 0 -> -1
    x > 0 -> 1
    _ -> 0
```

Conditions run top-to-bottom until one is `True`; only its result runs. `_` is unconditional and must be last. Reaching the end is a runtime match error. Conditions and guards have type `Bool`.

## 12. Recursion and `where`

Ordinary expression-block and `do` `=` bindings are sequential and non-recursive, including local pattern declarations.

`where` introduces mutually visible declarations. Initialization follows dependency order, breaking ties by source order; the enclosing body runs after all required declarations are initialized. Top-level declarations and `impl` members follow the same rules.

In v0, every top-level value initializer must be non-expansive (Section 16), including acyclic definitions and definitions with complete signatures. Interactive submissions have the separate rules in Section 22.1. v1+ retains this default, with an exception for acyclic top-level definitions in a `STANDALONE` module (Section 24.4). Written value parameters count as surrounding lambdas, so effects may run when a function is called, but not while loading its module. The check includes any attached `where` group that runs during initialization: a definition without written value parameters cannot hide an expansive initializer there, even if its right-hand side is a lambda. Local bindings may still be expansive, subject to the existing value restriction and cyclic-initializer checks.

```text
answer = 42                 -- allowed
answerFn () = 40 + 2        -- allowed: computation on call
computed = 40 + 2           -- invalid: expansive top-level initializer
```

A recursive group is a cycle of initialization dependencies. Every initializer in a cycle must be non-expansive (Section 16), and every reference within the cycle must occur beneath a lambda in its initializer; written value parameters count as lambdas. Other cycles are static errors. Right-hand sides within a cycle evaluate in source order. A direct initializer `x = y` is unprotected even if a later use of `x` occurs under a lambda.

For `f x y = body where ...`, the `where` group runs after both written parameters have been supplied, immediately before `body`. For `f x = y -> body where ...`, it runs after `x` has been supplied, before the returned lambda is created. A declaration with no written value parameters runs its `where` group before its right-hand side is evaluated. For a binding requiring dictionary parameters, initialization may wait until that evidence is supplied, as specified in Section 16; within that initialization, the same `where` positions and dependency order apply. These positions are observable and must be preserved by optimizations.

Within a recursive group, signed bindings may be used polymorphically at their declared types; unsigned bindings have one monotype. Both obey the cyclic-initializer rules.

## 13. Evaluation order

Observable effects occur in this order:

1. function before arguments;
2. operands left-to-right after operator grouping;
3. aggregate members left-to-right;
4. `where` declarations in dependency order with source-order ties, before the enclosing body;
5. block items top-to-bottom;
6. match scrutinee before clauses, and pattern before guard;
7. interpolated string segments left-to-right.

Optimizations must preserve this behavior.

v0 does not guarantee constant stack use for tail-recursive calls.

## 14. Operators

Operators are ordinary curried functions used infix. Their names are always parenthesized in signatures, declarations, imports, and prefix expressions:

```text
(++) : [a] -> [a] -> [a]
(++) xs ys = ...

append = (++) xs ys
```

A bare operator is exclusively infix:

```text
append = xs ++ ys
```

`.` is reserved punctuation for module qualification and field projection. It cannot be declared, imported, referenced as `(.)`, or used as an infix function.

Qualified operator references use a module path followed by a parenthesized operator, for example `List.(++)` after `use Data.List`. Bare operators are infix only, and v0 has no operator sections: `(x +)` and `(+ y)` are invalid.

Infix declaration heads are invalid. Thus `xs ++ ys = ...` is not a function definition. Constructor declarations follow the same rule: `(:+) a (Chain a)` is valid in a type body, while an infix constructor declaration is not.

Colon-led operators inhabit the uppercase namespace. At the value level they construct values rather than naming ordinary functions; at the type level they construct types. Bare `:` is grammatical punctuation; `::` is a reserved constructor name.

Precedence is determined by an operator's first character. These rules apply to expressions, types, and infix constructor patterns. Highest precedence first:

| Precedence | Form or leading character | Examples | Associativity |
|---:|---|---|---|
| 12 | Field projection | `value.field` | Left |
| 11 | Application | `f x` | Left |
| 10 | Prefix negation | `-x` | Prefix |
| 9 | Other operator characters | `~`, `?` | By suffix |
| 8 | `*`, `/`, `%` | `*`, `/`, `%` | By suffix |
| 7 | `+`, `-` | `+`, `-`, `++` | By suffix |
| 6 | `:` | `::`, `:+` | By suffix |
| 5 | `<`, `>` | `<`, `>=`, `<>` | By suffix |
| 4 | `=`, `!` | `==`, `!=` | By suffix |
| 3 | `&` | `&&`, `&` | By suffix |
| 2 | `^` | `^`, `^^` | By suffix |
| 1 | `\|` | `\|`, `\|\|` | By suffix |

Alphabetic names use application, not infix syntax. For every symbolic infix group, an operator whose name ends in `:` is right-associative; every other operator is left-associative. The leading `:` that places an operator in the uppercase namespace is independent of this suffix rule: `::` associates right, while `:+` associates left. A chain within one precedence group must not mix associativities. Spelling therefore determines parsing without fixity declarations.

```text
a + b * c       = a + (b * c)
a - b - c       = (a - b) - c
x +: y +: z     = x +: (y +: z)
x :+ y :+ z     = (x :+ y) :+ z
```

`::` has the `:` group's precedence and associates right.

Type-level `*` forms products and is unrelated to value-level `*`.

## 15. Type inference

Ficus uses Hindley–Milner inference with qualified types.

- Polymorphic uses instantiate fresh variables.
- Equality constraints use unification with an occurs check.
- Generalization follows the v0 value and monomorphism restrictions below.
- A signature may be less general than the inferred type, but not more general.
- An annotation unifies its written and inferred types.
- Signature and annotation holes are completed from the inferred type (Section 7.4).

Inference covers the complete module. Accepted unconstrained definitions have principal types, subject to trait ambiguity.

At each binding-group boundary, the v0 value restriction generalizes variables not free in the environment only when the initializer is non-expansive: a value lambda (including a definition with written value parameters), literal, variable, constructor, or aggregate of non-expansive values. Value applications, including partial applications, projections, record updates, conditionals, matches, `do`, and expression blocks are expansive, with one exception: an expression or `do` block containing exactly one expression and no declarations inherits that expression's classification. Thus `{ 1 }` and `{ x -> x }` are non-expansive, while `{ f x }` and `{ 1; 2 }` are expansive. Expansive result variables remain monomorphic. A signature cannot override this restriction; in particular, a local `inc = (+) 1` cannot acquire a polymorphic type merely by adding one. In source files, such an initializer is rejected outright at top level unless the v1+ `STANDALONE` exception applies; the value restriction still applies there.

The v0 monomorphism restriction further keeps an **unsigned**, constrained binding monomorphic when it has no written value parameters or outer value lambda, even if its initializer is non-expansive. A complete signature may override this extra restriction when the value restriction permits generalization and the definition checks against it; a signature with holes cannot. Otherwise, unresolved trait predicates must be solved for the binding's one monotype. This restriction concerns constrained bindings only; it does not prevent generalizing an unconstrained non-expansive value.

Within a recursive group, signed bindings may be used polymorphically at their declared schemes, while unsigned bindings use one monotype until the group boundary. Each definition must satisfy its signature and the value restriction. Missing parts of a signature containing holes are inferred without assuming polymorphic recursive use of those parts. The separate non-expansive and lambda-protection checks for cyclic initialization still apply.

```text
displayFn x = show x  -- may generalize under Show a
displayMono = show    -- unsigned: monomorphic; Show must resolve for one type

displayPoly : Show a => a -> String
displayPoly = show    -- signed: polymorphic despite having no lambda parameter
```

Weak type variables left by the value or monomorphism restriction may be fixed by later uses within the module, but are never generalized implicitly. Any weak variable still unresolved when module inference ends is a static error, even when it has no trait predicate (for example, an unused local `r = newRef []` once references are available).

A constrained type is ambiguous when a variable used by a predicate does not occur in the unconstrained value type:

```text
foo : C a => Int  -- invalid: a does not occur in Int
```

v0 rejects ambiguous types, inferred or written.

## 16. Traits and qualified types

A trait has one parameter and optional supertraits:

```text
trait Show a =
    show : a -> String

trait Functor f =
    map : (a -> b) -> f a -> f b

trait Pure f =
    pure : a -> f a

trait Seq f =
    seq : f (a -> b) -> (Unit -> f a) -> f b

trait (Functor f, Pure f, Seq f) => Applicative f = {}

trait Bind f =
    bind : f a -> (a -> f b) -> f b

trait (Applicative f, Bind f) => Monad f = {}
```

`Seq` and `Alternative.orElse` use ordinary explicit `Unit -> ...` thunks for their second operands. Calls and operators do not implicitly thunk arguments; `seq mf (_ -> mx)` delays evaluation of `mx`, while all ordinary call arguments still evaluate strictly left-to-right. The operation's implementation decides when to invoke the thunk; thunks do not imply automatic memoization. `Alternative` extends `Applicative`:

```text
trait Applicative f => Alternative f =
    failure : f a
    orElse : f a -> (Unit -> f a) -> f a
```

Qualified types place predicates before `=>`. An `impl` supplies every method exactly once.

Qualified bindings receive their required trait dictionaries before ordinary value arguments. Their initialization, including an attached immediate `where` group, may wait until that evidence is supplied. This permits a binding such as `choose : C a => a -> a` with `choose = x -> y where { Just y = get }`, when `C a` declares `get : Maybe a`: the pattern match runs after the `C a` dictionary is supplied and before the returned value lambda is created. Such initialization runs for each evidence application; it is not implicitly memoized. Bindings without dictionary parameters retain the ordinary initialization timing in Section 12.

This delay does not relax source restrictions. Source initializers must still satisfy the value restriction and the top-level or implementation-member non-expansiveness rules. Generated dictionary parameters do not count as written value parameters and do not provide protection for recursive initialization reads. Dictionary construction and member initialization must also satisfy the cycle checks after evidence dependencies are inserted.

Method signatures may constrain additional variables: `Traversable t` may declare `traverse : Applicative f => (a -> f b) -> t a -> f (t b)`. Method uses require both method-level and trait constraints. Every method's value type must mention the trait parameter; `trait C a = { foo : Int }` is invalid.

Trait and implementation declarations follow the Haskell 98 head restrictions.

### Trait declarations

A trait head is exactly one trait constructor applied to one bound type variable, optionally parenthesized with a kind annotation. The annotation does not change the Haskell 98 head restriction. Every supertrait predicate applies a trait constructor to that same variable:

```text
trait (C1 a, C2 a) => C a = {}  -- valid
```

Concrete types, type applications, and different variables are invalid in a trait head or its superclass context.

The superclass graph must be acyclic. A trait cannot require itself directly or through other traits:

```text
trait C a => C a = {}  -- invalid

trait B a => A a = {}  -- invalid together
trait A a => B a = {}
```

### Implementation declarations

An implementation head has the form:

```text
impl (C1 a1, C2 a2) => C (T a1 a2 ... an) = ...
```

`T` must be a type constructor, including a built-in structural constructor, and its arguments must be distinct bare type variables. A nullary constructor such as `Int` is valid. Each context predicate must apply a trait to one of the head variables.

```text
impl (C1 a1) => C (T Int a1) = ...  -- invalid: concrete argument
impl C (T a a) = ...                 -- invalid: repeated variable
impl Functor [] = ...                -- valid: list type constructor
impl Bifunctor (*) = ...             -- valid: product type constructor
impl Functor ((->) r) = ...          -- valid: function type constructor
```

Type aliases are expanded before this check and cannot be used to evade it. The defining module must own either `C` or the outer constructor `T`. No module owns the built-in `[]`, `(*)`, or `(->)` constructors or the primitive types `Int`, `Float`, `Bool`, `Char`, `String`, and `Unit`. Implementations for any of these must therefore be declared by the module that owns the trait. This rule does not apply to ordinary library-defined types such as `Byte`, `Vec`, and `Void`, whose defining modules own them.

### Use-site predicates

Predicates in signatures and inferred qualified types may apply a trait to an arbitrary well-kinded type:

```text
foo : C [a] => a -> b  -- valid
```

The ordinary ambiguity rule still applies: every variable mentioned by a predicate must occur in the unconstrained value type.

Visible implementations are local or in the transitive closure of explicit and implicit imports. Unrelated build modules contribute none. Each ground predicate has at most one matching visible implementation; its context and supertraits must also resolve. Failure, overlap, and resolution cycles are static errors. Selection is independent of import order.

Trait bodies contain signatures only. Each `impl` supplies every declared member exactly once. Default member bodies, fallback implementations, and local implementations are unsupported.

Operations that would be default instance methods in Haskell are instead ordinary constrained top-level functions outside the trait. For example, `Eq` declares only `(==)` and `Ord` declares only `compare`; inequality and ordering helpers are derived functions:

```text
-- not a member of Eq
(/=) : Eq a => a -> a -> Bool
(/=) x y = not (x == y)

-- not a member of Ord
(<) : Ord a => a -> a -> Bool
(<) x y = with compare x y
    Less -> True
    _ -> False
```

`(/=)` and `(<)` are not members of `Eq` and `Ord` and cannot fill missing implementation members.

A trait or implementation may use an explicit empty block `{}`. This supports marker traits that bundle only supertrait requirements, such as Prelude's `Applicative` and `Monad`. Layout-controlled trait and implementation blocks remain nonempty.

In source files, every top-level value initializer must be non-expansive by default, whether signed, recursive, or acyclic; v1+ `STANDALONE` relaxes this only for acyclic top-level definitions. Every `impl` member initializer must still be non-expansive. Written value parameters count as surrounding lambdas; type binders do not. Non-expansive forms are:

- variables, literals, and constructors;
- value lambdas (static type-only abstractions are classified by their body);
- products, lists, and records whose components are non-expansive;
- constructor applications whose arguments are non-expansive;
- annotations around non-expansive expressions;
- expression or `do` blocks containing exactly one non-expansive expression and no declarations.

General function application, blocks with declarations or multiple expressions, conditionals, matching, `do` with declarations or multiple statements, projection, record update, and primitive calls are expansive. A single-expression block retains its expression's classification, as specified in Section 15. In source files, expansive initializers are rejected as immediate top-level initializers except for the v1+ `STANDALONE` case, and as implementation-member initializers, although they may appear inside a function or member's lambda body.

```text
impl Show Person =
    show person = computeAndPrint person  -- allowed: effect occurs on call

impl Monoid Log =
    empty = makeInitialLog ()             -- invalid: call runs during initialization
```

## 17. `do` notation

`do` has the following equivalences:

```text
do { p <- e; rest }  => bind e (p -> do { rest })
do { declaration; rest } => strict sequential binding of declaration, then do { rest }
do { e; rest }       => bind e (_ -> do { rest })
do { e }             => e
```

A `declaration` is a named definition or non-infix pattern declaration, with expression-block evaluation, generalization, and shadowing rules. `do { f a = a; rest }` binds a function; repeated sequential binders are permitted with a shadowing warning. `<-` accepts only the irrefutable patterns in Section 10. `bind` is Prelude's `Bind` method; `do` is a static error when implicit Prelude is disabled.

## 18. String interpolation

In v0, `{name}` embeds one variable, and `{Module.name}` embeds one qualified variable. A qualified name has one or more uppercase module components followed by one lowercase value name. The braces cannot contain operators, applications, field projections, or other expressions. `{{` and `\{` produce a literal `{`; `}}` and `\}` produce a literal `}`. An escaped opening brace never begins interpolation. Any unmatched, unescaped single brace is a lexical error.

```text
"hello {name}"
"hello {Greetings.name}"
"literal \{name\}"
"sum {x + y}"  -- invalid in v0
```

Interpolation denotes left-associated concatenation of literal segments and `show` calls. Segments and variable uses evaluate left-to-right. Each embedded variable adds its required `Show` constraint. `Show String` is the identity, so interpolating a `String` does not add quotation marks. A string without interpolation is a plain `String`.

The `Show` method and concatenation operation come from the Prelude. Concatenation uses the canonical `Ficus.Builtin.String.stringAppend` value, selectively re-exported by `Prelude`, whose ordinary signature is `String -> String -> String` and whose compiler association is `STRING_APPEND`. Aliases, re-exports, local shadowing, and source spelling do not change the identity used by desugaring. In a `NO_IMPLICIT_PRELUDE` module, an interpolated string is a static error; ordinary string literals remain available.

## 19. Builtin declarations

```text
{-# BUILTIN HANDLE Handle #-}
Handle : Type

{-# BUILTIN INT_ADD intAdd #-}
intAdd : Int -> Int -> Int
```

`BUILTIN key name` associates a compiler implementation with an ordinarily declared top-level name in the same module. The pragma contains no signature and need not be adjacent to its target declaration; signatures and kinds come from ordinary declarations. A target without a source body must have a complete ordinary signature, which the builtin supplies with an implementation. Unknown keys, unresolved targets, incompatible types or kinds, conflicting associations, and an additional source definition are static errors. Placement and argument checks are semantic, not special parser productions.

`HANDLE`, `VOID`, and `BYTE` supply opaque types of kind `Type`; `VEC` supplies an opaque type of kind `Type -> Type`. Their conventional names are `Handle`, `Void`, `Byte`, and `Vec`. For example, `HANDLE` supplies an opaque type conventionally declared as `Handle`. Its declared name is ordinary and may be renamed or imported; it is not an additional reserved primitive type.

A builtin-supplied type is an opaque nominal constructor with no source constructor; a value is a primitive of its declared type. Keys are metadata, not names in language scope. Targets obey ordinary namespaces, mutual top-level visibility, duplicate-declaration, import/export, and ownership rules. Their identity is their defining module and declared name, not their key. Symbolic targets use their ordinary parenthesized identifier syntax.

The v0 compiler registry additionally includes these value contracts. `Vec`,
`Byte`, and `Void` below refer to the ordinarily declared types associated with
`VEC`, `BYTE`, and `VOID`, including when those declarations are renamed or
imported. Contracts require the complete polymorphic signature, up to bound
variable renaming; a specialization or additional trait predicate is invalid.

| Keys | Signature |
| --- | --- |
| `INT_ADD`, `INT_SUB`, `INT_MUL`, `INT_DIV`, `INT_REM` | `Int -> Int -> Int` |
| `INT_EQ`, `INT_LT` | `Int -> Int -> Bool` |
| `INT_SHOW` | `Int -> String` |
| `INT_TO_FLOAT` | `Int -> Float` |
| `FLOAT_ADD`, `FLOAT_SUB`, `FLOAT_MUL`, `FLOAT_DIV` | `Float -> Float -> Float` |
| `FLOAT_EQ`, `FLOAT_LT` | `Float -> Float -> Bool` |
| `FLOAT_SHOW` | `Float -> String` |
| `FLOAT_TO_INT` | `Float -> Int` |
| `CHAR_EQ`, `CHAR_LT` | `Char -> Char -> Bool` |
| `CHAR_SHOW` | `Char -> String` |
| `STRING_APPEND` | `String -> String -> String` |
| `STRING_EQ`, `STRING_LT` | `String -> String -> Bool` |
| `STRING_LENGTH` | `String -> Int` |
| `STRING_TO_CHARS` | `String -> [Char]` |
| `STRING_FROM_CHARS` | `[Char] -> String` |
| `ABSURD` | `Void -> a` |
| `VEC_FROM_LIST` | `[a] -> Vec a` |
| `VEC_TO_LIST` | `Vec a -> [a]` |
| `VEC_LENGTH` | `Vec a -> Int` |
| `BYTE_FROM_INT` | `Int -> Byte` |
| `BYTE_TO_INT` | `Byte -> Int` |
| `HANDLE_STDIN`, `HANDLE_STDOUT`, `HANDLE_STDERR` | `Handle` |
| `HANDLE_READ` | `Handle -> Int -> String` |
| `HANDLE_WRITE` | `Handle -> String -> Unit` |

Integer division truncates toward zero; remainder has the dividend's sign.
Division or remainder by zero is a primitive failure. The minimum signed integer
divided by `-1` wraps to the minimum signed integer, with remainder zero.
Floating arithmetic and comparisons follow IEEE 754 binary64 (including NaN).
`INT_TO_FLOAT` rounds to nearest, ties to even; `FLOAT_TO_INT` truncates toward
zero and fails for non-finite or out-of-range results. `INT_SHOW` renders signed
decimal; `FLOAT_SHOW` renders a shortest round-tripping decimal for finite values
and `NaN`, `Infinity`, or `-Infinity` otherwise. `CHAR_SHOW` returns a singleton
string, without quotes. Character ordering uses Unicode code points; string
ordering is lexicographic by code point. String length counts code points, and
the list/string conversions preserve them in order.

`BYTE_FROM_INT` reduces modulo 256; `BYTE_TO_INT` returns a value in 0–255.
Vectors are immutable sequences; list/vector conversions preserve order and
`VEC_LENGTH` counts elements. `VOID` has no values and `ABSURD` eliminates it.
The three standard handle bindings are stable opaque values for standard input,
standard output, and standard error. They do not perform IO during module
initialization. `HANDLE_READ` reads at most the requested number of Unicode code
points from a readable handle, preserving line terminators, and returns the empty
string at EOF. A non-positive count returns the empty string without performing
IO. `HANDLE_WRITE` writes its string unchanged to a writable handle and returns
unit. Standard input is readable; standard output and standard error are
writable. Using a handle in an unsupported direction or encountering an IO error
is a primitive failure. No close operation is provided in v0.

`System.IO.print`, `println`, and `readLine` are source-derived library functions,
not builtin keys. `print` writes to standard output without a newline; `println`
appends LF. `readLine ()` reads from standard input, removing a terminating LF or
CRLF and returning the empty string at EOF. A final unterminated line is returned
unchanged. `readLineFrom : Handle -> String` provides the same behavior on an
explicit readable handle. Low-level handles, `read`, and `write` require explicit
imports from `Ficus.Builtin.Handle` or `System.IO`.

`BUILTIN` does not affect implicit Prelude. Only `NO_IMPLICIT_PRELUDE` disables it. There is no compiler-provided `magic` identifier or module-level `MAGIC` pragma; `magic` remains an ordinary identifier.

## 20. Prelude

The Prelude is a library, not core semantics. It should provide arithmetic traits, `Eq`, `Ord`, `Show`, `Bind`, list and string operations, IO helpers, `Void`, `absurd : Void -> a`, and common combinators, backed where necessary by imports from builtin-backed modules.

The bundled v0 library uses `Ficus.Builtin.*` for compiler-key bindings,
`Class.*` for traits, `Data.*` for ordinary data APIs, and `System.IO` for IO.
Builtin modules never import the data layer. Every library module explicitly
disables implicit Prelude and imports its dependencies; Prelude selectively
re-exports the reviewed API in [PRELUDE.md](PRELUDE.md#1-organization).
`Handle`, `Vec`, and `Byte` require explicit imports. `Result e a` uses `Err` and
`Ok`; `Ordering` uses `Less`, `Equal`, and `Greater`. `Void` and `absurd` are
builtin-backed library definitions re-exported by Prelude.

Control traits are fine-grained: `Applicative` bundles `Functor`, `Pure`, and
`Seq`; `Monad` bundles `Applicative` and `Bind`. `Seq` takes an explicit thunk as
its second argument. `Alternative` extends `Applicative` with `failure` and
thunked `orElse`. `Maybe` and `Result e` skip the argument thunk when the function
is absent or erroneous. List application is Cartesian, in function-major order;
it skips the thunk for an empty function list, otherwise invokes it exactly once
and reuses that resulting list. List choice appends both lists and invokes its
right thunk exactly once. `Maybe` choice invokes the right thunk only for
`Nothing`; there is no `Alternative (Result e)` instance. List and `Maybe`/`Result`
traversal evaluates left-to-right; a missing/error result skips later thunks.
`(<*)` and `(*>)` are derived aliases for `seqLeft` and `seqRight`; both take
an explicit thunk on the right and retain the selected instance's sequencing
behavior. `Data.Function` exports backward composition `(f << g) x = f (g x)` and
forward composition `(f >> g) x = g (f x)`. These are ordinary spelling-grouped
operators with no special fixity declarations; `($)` is not a library export.
The named `apply`, `pipe`, and `compose` functions remain available.
`and`, `or`, `(&&)`, and `(||)` remain ordinary strict binary functions. Use `if`
for boolean short-circuiting. List `head`, `tail`, and `last` return `Maybe`.
`take` and `drop` treat non-positive counts as zero; `zip` stops at the shorter
list. No `Control` modules, exceptions, concurrency, or `Data.Map` ship in v0.

`Debug.debug : a -> String` is separate from `Show.show`; its scalar instances
quote characters and strings and escape backslash, quotes, newline, carriage
return, and tab. Structural instances retain constructor/container structure.
`Default.default : a` supplies zero for numbers, false for booleans, space for
characters, and the empty string/list, unit, or `Nothing`; a successful `Result`
uses its value type's default. `Ord Float` places NaNs after all non-NaNs and
compares NaNs as `Equal`; IEEE equality still makes NaNs unequal. Positive and
negative zero compare as `Equal`. These library contracts do not add reserved
names or alter the language's ownership and scope rules.

The Prelude is imported implicitly unless the module has `NO_IMPLICIT_PRELUDE`. The six reserved primitive types remain in scope either way.

## 21. Errors

Implementations reject at least:

- malformed tokens, escapes, comments, or pragmas;
- invalid syntax or layout;
- invalid pragma placement or `pub` on a non-list import;
- unresolved or ambiguous names;
- duplicate declarations or pattern variables;
- type mismatches, failed occurs checks, or invalid annotations;
- unresolved weak type variables or field receivers;
- partial or cyclic aliases and non-regular recursive ADTs;
- expression holes, with their inferred types shown in the diagnostic;
- ambiguous or unsatisfied trait constraints;
- missing, duplicate, orphan, or overlapping implementations;
- forbidden expansive top-level or implementation-member initializers, expansive cyclic initializers, or unprotected recursive references;
- invalid record fields or constructor arity;
- invalid or forbidden refutable patterns;
- use of Prelude-dependent sugar when the implicit Prelude is disabled;
- invalid builtin placement, key, target, signature, or source definition.

Runtime errors include failed pattern matches and primitive failures. Diagnostics identify relevant source locations and explain the error; exact wording is unspecified. Suggested fixes are deferred.

## 22. Program entry point

Program execution requires exactly one explicitly selected entry module. The selected module must define its own `main` function with one of the following v0 signatures; a missing or invalid `main` is an entry-point error. Imported or re-exported `main` definitions do not substitute for a definition in that module. Library modules need not define `main`, and a `main` in an unselected module is not invoked automatically:

v0 supports exactly these `main` signatures:

```text
main : [String] -> Unit
main : [String] -> Result String Unit
```

The entry function takes command-line arguments and either returns `Unit` directly or reports a string error through `Result`. `main : Unit` and a polymorphic `Show a => [String] -> Result a Unit` entry point are unsupported. `ficus run FILE [-- ARGS...]` selects FILE's module and passes only ARGS as
strings, excluding the executable and source filename. The `Result` form uses
the canonical `Data.Result.Result` type, including ordinary aliases and
re-exports. Returning `Unit` or `Ok ()` exits successfully. Returning `Err message`
writes the message to standard error and exits with status 1. Compilation,
entry-point, and runtime errors also exit with status 1 and report diagnostics
to standard error. Exception handling at the entry point belongs to v1+.

### 22.1 Interactive execution

`ficus repl [FILE]` starts an interactive session and optionally loads a module;
it does not require or invoke `main`. Expressions execute strictly and their
results are displayed through the library's `Debug` contract, so a result needs
a visible `Debug` instance. Single-line top-level declarations may be added using
ordinary declaration syntax. Acyclic interactive bindings may have expansive
right-hand sides, which evaluate when the submission is accepted. This is an
interactive initialization policy, not support for the v1+ `STANDALONE` pragma
in source files. Value and monomorphism restrictions still apply; signatures
cannot generalize expansive expressions. Cyclic initializers and implementation
members retain their ordinary non-expansiveness and recursive-read checks.

A later submission may rebind a value or type name. New lookups see the newest
binding; old closures, values, and inferred schemes retain their original
identities and captures. A strict value rebinding such as `x = x + 1` reads the
previous `x` on its right-hand side. Functions with written parameters retain
ordinary recursive scope. Duplicate declarations within one submission remain
errors.

Redefining a type creates a fresh nominal identity. Its new constructors may
reuse names owned by the previous version of that same type, but cannot take
constructor names owned by an unrelated visible type. Constructors omitted by
the replacement type leave interactive scope, including those originally
provided by implicit Prelude. Values of the old type remain usable through
previously defined functions. Ordinary source files retain their existing
name, constructor ownership, and top-level initialization rules.

The commands `:load FILE` / `:l FILE`, `:type NAME` / `:t NAME`, `:help` / `:h`,
and `:quit` / `:q` load or reload a file, inspect a name, show command help,
and exit. Type inspection shows a type or trait's inferred kind, together with
the source declaration for a trait (including superclasses and method signatures).
Otherwise it shows a value or constructor's inferred scheme. Type names take
precedence over constructor names when both are visible with the same spelling.
Qualified names follow ordinary resolution rules. Inspection does not evaluate
the named entity. End of input also exits. A successful load replaces interactive
imports and declarations and brings the module's exported names into scope.
Loading rereads the selected file and its dependencies. Failed loads, imports,
declarations, type queries, and expression evaluation leave the last successful
environment available; in particular, division by zero reports a primitive
failure and returns to the prompt. Previously accepted right-hand sides are not
replayed by later commands. Effects already performed before an error are not
rolled back.

Interactive `use` declarations follow ordinary source import rules. As a REPL
convenience, `import Module` means `use Module (..)`, while `import` with a
selection or alias is translated to the corresponding `use` declaration. This
convenience does not add an `import` keyword to source files. Failed optional
startup loads report diagnostics and leave an empty interactive session.

## 23. v0 exclusions

The initial language excludes:

- expression interpolation beyond a variable or qualified variable;
- comma-style record literals and record punning;
- record patterns;
- empty type bodies and empty `with` matches;
- the `forall` keyword and higher-rank quantified signatures;
- deriving, including the reserved `DERIVE` pragma;
- lazy arrows `~>`, which replace the earlier prefix-`~` proposal;
- private, deprecation, and compiler-option pragmas, and inline expression-level pragmas;
- multiparameter traits, associated types, and type families;
- GADTs, higher-rank polymorphism, and dependent types;
- unrestricted mutable references and mutable arrays;
- effect systems, concurrency, and async syntax;
- macros, ownership types, and custom memory management.

The exclusions do not settle future syntax or semantics. Planned v1+ designs are grouped in Section 24; later work is listed in Section 25.

## 24. Planned v1+ language features and libraries

These features are excluded from v0. “Settled” means a selected design; draft proposals may change. Unspecified details remain open.

### 24.1 Types and patterns

#### Empty types and empty matching

v1+ accepts empty record/type bodies and empty `with` blocks:

```text
type Void = {}

absurd : Void -> a
absurd x = with x {}
```

An empty record body and an empty ADT body share the form `type T = {}` and have the same meaning.

An empty body defines an uninhabited nominal type and introduces no constructor, including no positional record constructor named `T`. Consequently, `Void with {}` is invalid: an empty record body does not provide a constructor for named construction. This differs from `type T = { T }`, which explicitly declares a nullary constructor.

An optional warning may suggest `type Token = { Token }` for a unit-like type; intentional empty types remain valid.

An empty `with` eliminates an impossible scrutinee and may have any result type. These source definitions replace the v0 builtin-backed `Void` and `absurd` while preserving their Prelude API.

An empty match is exhaustive only for an uninhabited scrutinee type. Treatment of uninhabited types inside other patterns and diagnostic policy remain open. v1+ extends the nonempty v0 type-body and match-block productions to admit `{}`.

#### Record patterns

Record patterns use explicit braces and mirror named construction without punning, for example `Point with { x = px; y = py }`. Fields may be omitted: `Point with { x = px }` ignores `y`, and `Point with {}` ignores every field. Omitted fields introduce no bindings; supplied labels must be distinct and belong to the record. They are allowed in `with` clauses, lambda/function arguments, non-recursive value bindings, and both forms of `do` binding: `pattern <- expr` and `pattern = expr`. They are not allowed in recursive `let` groups. At top level or inside `where`, reject a binding headed by a record pattern when it participates in a recursive binding group; the error should suggest matching with `with` inside a named function instead. In `do`, a record pattern may appear on the left of either `<-` or `=`, for example:

```text
do
    Point with { x = px; y = py } <- nextPoint
    Point with { x = qx; y = qy } = otherPoint
    consume px py qx qy
```

Record-pattern refutability is checked against the resolved record type and the supplied value-field patterns; omitted fields impose no restriction. A pattern with only irrefutable supplied fields is irrefutable, including `Point with {}`. A supplied refutable subpattern makes it refutable and invalid for `<-`. Opening a hidden type member does not test its identity and does not by itself make the pattern refutable. Record punning is unsupported; every supplied field needs an explicit pattern.

### 24.2 Evaluation and state

#### Mutable references (settled)

The mutable-reference design is settled for v1+ as written. An explicit builtin-backed state module provides:

```text
{-# BUILTIN REF Ref #-}
Ref : Type -> Type

{-# BUILTIN NEW_REF newRef #-}
newRef : a -> Ref a

{-# BUILTIN MODIFY_REF modifyRef #-}
modifyRef : Ref a -> (a -> a) -> Unit

{-# BUILTIN READ_REF readRef #-}
readRef : Ref a -> a
```

`newRef` allocates a mutable cell. `readRef` returns its current value. `modifyRef ref f` reads the current value, applies `f`, stores the result, and returns `()`.

The v1+ `Ref` design retains the v0 value restriction: expansive bindings such as `ref = newRef []` must not be generalized. Atomicity and interaction with fibers remain unspecified.

### 24.3 Exceptions (proposed interfaces)

#### Exception primitives

The initial v1+ Prelude defines the marker trait:

```text
trait Exception e = {}
```

An explicit v1+ builtin-backed exception module provides:

```text
{-# BUILTIN THROW throw #-}
throw : Exception e => e -> a

{-# BUILTIN CATCH catch #-}
catch : Exception e => (Unit -> a) -> (e -> a) -> a
```

`throw` does not return normally. `catch action handler` runs `action ()`; it invokes `handler` for an exception of the statically selected type `e` and propagates other exceptions.

`Exception e` has no source-level methods. Typed `catch` distinguishes nominal exception types, including through polymorphic `Exception e` uses, even when those types have identical value representations.

These interfaces may change if existential errors are adopted (Section 24.6). Cleanup, nesting, interaction with effects, and standard `Exception` instances remain open.

### 24.4 Pragmas

#### Definition pragmas and eta expansion

v1+ permits pragmas at declaration boundaries inside `impl` bodies, `where` groups, expression blocks, and `do` declaration sequences, as well as top level. These contexts extend the generic grammar to admit pragma items alongside their existing declarations. They do not admit pragmas as arbitrary expressions or enable local trait implementations. Module pragmas remain restricted to the module header; other directives keep their individual target restrictions.

The argument-free `{-# ETA #-}` annotates the following named value definition, including an implementation member or local definition. It applies only to that definition, never as a module-wide or scope-wide flag, and is not inherited by sibling or nested definitions. Its initializer must have a function type. Before non-expansiveness checks, expand the complete initializer `e : A -> B` to `x -> e x` with a fresh parameter. Expand one outer arrow, not every arrow in a curried result type. Any immediately evaluated attached `where` group is part of `e` and is delayed with it:

```text
printer : String -> Unit
{-# ETA #-}
printer = makePrinter ()
```

The resulting function initializer is non-expansive; check initialization safety and value-restriction eligibility after expansion. Recursive groups still require lambda-protected references, and ordinary type, constraint, and monomorphism rules still apply. The pragma is not an exemption from these checks. Non-function targets, bodyless declarations, unnamed pattern declarations, and pragma arguments are errors.

Eta expansion intentionally changes strict evaluation timing: `makePrinter ()` above runs when `printer` is applied, and runs again on each application. It does not pre-evaluate or memoize the original initializer. This is an explicit source transformation, not an automatically applied optimization. `ETA` is unavailable in v0.

#### Private pragmas

The v1+ form is `{-# PRIVATE [member] #-}`, where brackets denote the optional literal identifier `member`. It is excluded from v0. These examples record the intended future distinction:

```text
{-# PRIVATE #-}
foo x = x

-- hide the type and its members
{-# PRIVATE #-}
type Local a =
    Local a

-- hide constructors only
{-# PRIVATE member #-}
type Map k a = { Leaf k a; Node (Map k a) (Map k a) }

-- hide the record constructor and fields
{-# PRIVATE member #-}
type Complex =
    real : Float
    imaginary : Float
```

`PRIVATE member` leaves the type public but hides its ADT constructors or, for a record, its constructor and fields.

Definition pragmas may appear in the v1+ declaration contexts described above. Individual directive targets, including private constructors and local definitions, still need targeting rules; arbitrary inline expression pragmas remain unsupported.

#### Deprecation pragma

v1+ adds:

```text
{-# DEPRECATED ident+ "<message>" #-}
```

Here `ident+` denotes one or more identifier arguments. The final string supplies the deprecation message for use-site diagnostics. Argument counts and target validity are checked semantically. For example:

```text
{-# DEPRECATED oldName olderName "Use newName instead" #-}
```

Detailed name-targeting, placement, and warning-policy rules remain to be specified.

#### Standalone modules

v1+ adds an argument-free module pragma, placed before imports:

```text
{-# STANDALONE #-}
answer = 40 + 2
```

A standalone module may have expansive initializers for acyclic top-level definitions, including immediately evaluated attached `where` groups. Initialization still follows dependency order with source-order ties. Recursive binding groups retain the existing non-expansive and lambda-protection requirements; implementation-member initializers remain non-expansive. The value restriction, monomorphism restriction, and ordinary type checking still apply.

No other module may import a standalone module, whether through a bare, aliased, selective, re-exporting, or implicit import. A standalone module may import ordinary modules. This keeps its potentially effectful initialization out of other modules' import graphs.

`STANDALONE` neither selects an entry module nor requires a `main` declaration. Compilation may accept a standalone module without `main`; if it is explicitly selected for program execution, the ordinary entry-point requirements still apply. It does not disable implicit Prelude. Pragma arguments and placement are checked semantically under the generic pragma grammar. The pragma is unavailable in v0.

#### Module compiler-options pragma

v1+ adds the module-level pragma:

```text
{-# OPTIONS "<compiler options>" #-}
```

Compiler options use ordinary identifier or string arguments; the quoted text above is a placeholder. This module pragma appears before imports. Accepted options, flags, warnings, and precedence relative to command-line options remain open; their interpretation does not change pragma parsing.

#### Structural deriving

The v1+ form is an argument-free pragma attached to the following top-level declaration, which must be an `impl`:

```text
{-# DERIVE #-}
impl Show Point = {}

{-# DERIVE #-}
impl Show a => Show (Box a) = {}
```

The compiler generates all members for the trait and type in the ordinary implementation header. The body must be empty; any handwritten members, including a partial implementation, are a static error. Mixed generated and handwritten implementations are unsupported. Without `DERIVE`, ordinary member-completeness checks apply; an empty implementation is valid only when the trait has no members.

The written context must suffice for the generated methods; deriving does not silently add constraints. Generated implementations follow ordinary scope, ownership, overlap, superclass, and type-checking rules. A non-`impl` target, pragma arguments, an unsupported trait, or an implementation that cannot be generated is a static error. Each trait needs a separate annotated implementation.

Initial support is limited to structural `Show` and `Eq` implementations; detailed generation rules remain open. `DERIVE` has no semantics in v0. Parsing remains the generic pragma grammar; attachment, argument count, and generation are checked later.

### 24.5 Interpolation and libraries

#### Expression interpolation

v1+ extends string interpolation to expressions inside `{...}`. Its precise delimiter and escaping rules remain to be specified.

#### Expanded libraries

The v0 standard-library layout and selective Prelude API are described in
Section 20 and [PRELUDE.md](PRELUDE.md#1-organization). Future releases extend
that layout with modules such as `System.Environment`, `Data.Map`, and
`Control.Exception`; these modules are unavailable in v0. `System.IO` remains an
operations module and does not imply an `IO` type. All library modules continue
to use `NO_IMPLICIT_PRELUDE` and explicit dependencies. Future additions do not
silently expand Prelude or change declaration identity and instance ownership.
JSON and regular-expression support are planned; their APIs remain open.

### 24.6 Existential type abstraction (proposal)

#### Existential record type members (v1+ proposal)

A proposed declaration mixes an uppercase abstract type member with lowercase value fields in one record body:

```text
type SomeException =
    Err : Type
    showErr : Err -> String
```

Here `Err` names a hidden representation type, while `showErr` is a runtime operation over values of that type. This is an existential package in the style of *Types and Programming Languages*, not a path-dependent type.

When record patterns and existential type members are both available, the proposed unpacking pattern is:

```text
SomeException with { Err = e; showErr = se } = ...
```

`Err = e` introduces a fresh named local **type variable** `e` for the hidden witness; it does not compare or match the member against a concrete type. `showErr = se` binds the runtime operation as a value. The type variable is scoped to use of the unpacked package; the value binder follows the enclosing pattern binding. A type member cannot be matched as a value or constructor, and type checking must prevent `e` from escaping the unpacking scope. Packaged operations remain callable through the hidden type's interface.

Type members can be supplied or opened only through named `with` fields. Uppercase labels identify type-member slots: their construction right-hand sides are type expressions, and their pattern right-hand sides bind lowercase type-variable names. No `@` marker is used inside these slots:

```text
SomeException with { Err = String; showErr = (e : String) -> e }
with package { SomeException with { Err = e; showErr = se } -> ... }
```

The v1+ grammar extends record field blocks with `upper_ident, "=", type_expr`. In pattern contexts, a record pattern is `(upper_name | qualified_constructor), "with", block(record_pattern_field)`, where `record_pattern_field = ident, "=", pattern`; it is a self-delimiting binder pattern. Parse field patterns uniformly, then require an uppercase type-member slot to contain a bare lowercase type binder during semantic validation. This preserves ordinary constructor patterns in lowercase value fields. Explicit braces delimit record patterns; record construction retains its existing explicit/layout field blocks. Type-expression arrows in uppercase construction fields stay inside the field until its separator or closing delimiter.

All supplied labels must be distinct and belong to the record. In construction, check each supplied type against the member's kind and check value fields against that witness, irrespective of field order. In a pattern, `Err = e` binds a fresh abstract witness, never tests for equality with a concrete type; `Err = String` is invalid there. Type members are not ordinary record type parameters, so `SomeException @String` cannot supply the hidden witness. Ordinary `@` type application still applies to explicitly quantified parameters, not record members.

Type members occupy no positional constructor or pattern slots. Value fields retain their positional slots in declaration order: `SomeException ((e : String) -> e)` infers the witness, and `SomeException se` opens it anonymously without binding a type name. Named patterns may omit type members and value fields; `SomeException with { showErr = se }` also leaves the witness unnamed. Every unpacking enforces witness non-escape. Only a named `with` type-member pattern can give that witness a source name. The previous alternative of positional type-member arguments is excluded; positional value-only matching is retained. Detailed witness inference and records with only type members remain open. Updates of existential records remain open. See [TAPL, Chapter 24](https://www.cis.upenn.edu/~bcpierce/tapl/contents.pdf).

Existentials could also support a `SomeException`-like package for heterogeneous errors in v1+. If adopted, it may change the v1+ exception interface above and the v2+ concurrency interface (Section 25.4), including the current `Fiber e a`/`join` result types. That possibility does not commit to an existential error API yet.

## 25. v2+ language and library work

### 25.1 Lazy arrows (v2+)

The planned v2+ lazy function arrow is `~>`. When introduced, it will be type punctuation rather than an ordinary symbolic operator and will associate right like `->`. It is distinct from the strict arrow; neither `A ~> B` nor `A -> B` is a subtype of the other, and there is no implicit coercion between them. Type equality and unification distinguish the two arrows. Inference defaults to `->`, and every lazy arrow must be written explicitly in a signature.

```text
and : Bool ~> Bool ~> Bool
and x y = with x
    True -> y
    False -> False
```

Lazy arrows use **call-by-name**, without memoization. Each demanded use of a lazy parameter evaluates the original argument expression again in its captured lexical environment. An unused argument is not evaluated. Effects, errors, and divergence therefore recur at each demanded use; the results of separate demands are not shared. Each demanded evaluation follows the ordinary strict, left-to-right rules, and surrounding strict arguments retain their ordinary evaluation order. An explicit strict local binding can evaluate a demand once and reuse its result.

Matching a lazy argument against a variable or wildcard does not demand it. Any other parameter pattern demands the argument once for that matching attempt; its bound value components come from that evaluated value. Repeated references to a variable parameter demand it separately. Pattern coverage proofs do not remove observable demands. No automatic sharing, eager evaluation, or arrow coercion may change this behavior.

### 25.2 JavaScript backend and tail calls

v2+ adds a simple JavaScript backend and tail-call optimization. The backend must preserve strict left-to-right evaluation, nominal identities, and initialization semantics. Tail-call coverage and the scope of any constant-stack guarantee remain to be specified; do not assume JavaScript engines provide the needed optimization. Backend implementation choices are recorded in IMPL.md.

### 25.3 Packages and foreign interfaces

v2+ plans include libraries beyond Prelude and a foreign-function interface (FFI). Its proposed declaration form mirrors builtin annotations:

```text
{-# FOREIGN JS "console.log" log #-}
log : String -> Unit
```

`FOREIGN LANG "<name>" ident` associates an external implementation with an ordinarily declared local value. Its type comes from the ordinary declaration; the pragma need not be adjacent to it. Like all pragmas, it uses the generic grammar and is interpreted during semantic checking. Scope rules and implicit Prelude remain unchanged.

`FOREIGN` is unavailable in v0. Accepted backends, symbol validation, type conversions, calling conventions, and exception behavior remain open. Backend and symbol designators are metadata, not local bindings. Backend plans, the build system, dependency resolution, and foreign calling conventions are documented in [IMPL.md](IMPL.md#9-further-versioned-work).

### 25.4 Concurrency primitives (proposed interfaces)

An explicit v2+ library module exposes builtin-backed fibers and channels:

```text
{-# BUILTIN FIBER Fiber #-}
Fiber : Type -> Type -> Type

{-# BUILTIN CHAN Chan #-}
Chan : Type -> Type

{-# BUILTIN FORK fork #-}
fork : Exception e => (Unit -> a) -> Fiber e a

{-# BUILTIN JOIN join #-}
join : Fiber e a -> Result e a

{-# BUILTIN NEW_CHAN newChan #-}
newChan : Unit -> Chan a

{-# BUILTIN SEND send #-}
send : Chan a -> a -> Unit

{-# BUILTIN RECV recv #-}
recv : Chan a -> a
```

At call sites, `Unit` is introduced with `()`, for example `fork (() -> work)` and `newChan ()`.

`fork` schedules its thunk concurrently. An uncaught fiber exception is preserved as the `e` parameter of `Fiber e a` and returned by `join` as `Err e`. Its first type parameter records the exception type. In the current v2+ interface, `join` waits and returns either `Ok value` or `Err exception` without existentially hiding that type. `send` and `recv` communicate through a typed channel; whether channels are buffered and how cancellation works remain unspecified.

These declarations are not part of implicit Prelude. The v0 value restriction already prevents generalization of expansive bindings such as `channel = newChan ()`.

## 26. v3+ backend work

v3+ considers a WebAssembly GC backend or an LLVM backend. Selection, runtime representation, memory management, and foreign integration remain open. Either backend must preserve the language's evaluation and typing contracts.

## 27. Remaining open design decisions

Open language decisions include updates of existential records, existential record syntax, exhaustiveness for uninhabited subpatterns, and reference atomicity and interaction with fibers. The value restriction applies from v0 onward.

Entry-point argument, reporting, and exit-status conventions remain open. Compiler artifact schemas and other implementation questions are tracked in [IMPL.md](IMPL.md).

Integer division, literal ranges, conversions, floating-point display, and the remaining lexical details in `PLAN.md` remain unsettled.
