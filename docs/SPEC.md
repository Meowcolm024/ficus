# Ficus Language Specification

## 1. Scope

Ficus is an opinionated, minimalist, strict, impure, expression-oriented functional language for scripting. It deliberately favors a small, predictable core over a broad feature set. It provides global Hindley–Milner inference, nominal algebraic data types, structural products and lists, pattern matching, and single-parameter traits.

This document specifies the initial language. Library APIs are non-normative unless stated otherwise. Implementation architecture is documented separately in `IMPL.md`.

## 2. Source files and modules

Each file defines one module. Its path and filename determine its module name; there is no `module` declaration.

Relative to a configured source root, directory and file components form the dotted module path. For example, `Data/Map.ficus` defines `Data.Map`. Every component must be an uppercase identifier.

```text
use Foo
use Foo as F
use Foo (x, y, Z)
use Foo (..)

use Data.Map
use Data.Map (Map)
use Data.Map (..) pub
```

`use Foo` imports only the module name. `as` selects a local alias. An import list introduces its named public members; `..` introduces all public members.

Modules and types occupy separate namespaces. A module component and an imported type may therefore have the same spelling. `use Data.Map` introduces the module name; `use Data.Map (Map)` may also introduce its `Map` type.

A bare or aliased import brings its module name or alias into the local module-name scope. An import list brings only the selected members into local scope. Primitive type names and `Type` may occur in a module path, but cannot be bound as local module names:

```text
use Data.Int        -- invalid: binds the module name Int
use Data.Int (add)  -- valid: binds only add
use Data.Int as I   -- valid: binds the module name I
```

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

Imports are initialized once, in source order, before the importing module. Import cycles are static errors.

All top-level declarations are public in v0. Private pragmas, including `{-# PRIVATE #-}` and `{-# PRIVATE members #-}`, are deferred.

The v0 parser accepts pragmas only at global declaration level, never inside expressions or local declarations. Pragmas before imports are module pragmas. A pragma block may contain multiple comma-separated pragmas. Every pragma has an uppercase name followed by zero or more literal or identifier arguments. `NO_IMPLICIT_PRELUDE` disables the implicit Prelude and its dependent sugar. `MAGIC` enables compiler bindings and implies `NO_IMPLICIT_PRELUDE`. `DERIVE` is reserved syntax with no initial semantics; `Show` is one possible argument.

## 3. Lexical structure

Source is Unicode and case-sensitive. Lowercase identifiers name values, fields, and type variables. A lowercase identifier starts with a lowercase Unicode letter or `_`, followed by identifier characters; `_` and names such as `_value` are both lexed as ordinary lowercase identifiers. Uppercase identifiers name modules, types, constructors, and traits. A symbolic name beginning with `:` belongs to the uppercase namespace and may name a constructor or type. Name resolution gives the exact spelling `_` its wildcard or hole meaning according to position; names beginning with `_` have no special meaning.

Hard keywords are:

```text
use type trait impl with if where do
```

`as` and `pub` are soft keywords in import declarations. `True` and `False` are lexed and parsed as ordinary uppercase identifiers; their constructor meanings are reserved semantically.

Line comments begin with `--` only when it is not followed by another operator character; `-->` is one operator token, while `-- text` is a comment. A bare `--` at end of line is a comment. Block comments begin at every `{-` outside a string or character literal and end at the next `-}`; they do not nest. Thus `{-x}` starts an unterminated block comment, not a braced expression. Pragmas use `{-#` and `#-}` and take precedence over ordinary block comments.

Literals include decimal integers and floats, characters in single quotes, and strings in double quotes. An integer literal such as `1` has type `Int`; a literal with a decimal point such as `1.0` has type `Float`. Numeric literals are not overloaded. `Int` values are signed 64-bit integers, and integer arithmetic wraps modulo 2^64. `Float` values use IEEE 754 binary64. Character and string escapes include `\\`, `\'`, `\"`, `\n`, `\r`, and `\t`. Strings additionally accept `\{` and `\}` for literal braces.

A symbolic operator is a nonempty sequence of operator characters, using maximal munch after comment and reserved-token recognition. A dot may occur within an operator only when flanked on both sides by non-dot operator characters, as in `+.+`; it cannot begin or end one. A colon-led operator is an upper operator; every other operator is a value operator. Bare `:`, `=`, `->`, `<-`, `=>`, and `.` are reserved in their grammatical roles. `..` is reserved for import lists and is invalid as an expression operator. `::` is lexed and parsed as an ordinary upper operator but has reserved list-constructor semantics.

A qualification or field-projection dot has no surrounding whitespace. `x.field` is syntactically a projection; `x . field` is invalid. `1.foo` is syntactically a projection but fails typing because `Int` has no fields. A dot inside a symbolic operator is never a qualification separator.

## 4. Layout

Layout is parser-driven. When the parser reaches a grammar position requiring `block1` or `block`, it opens an indentation block if the next token is not `{` and supplies virtual `{`, `;`, and `}` tokens while parsing that block. Layout is not a separate token-rewriting pass before parsing.

A layout block begins where the grammar requires `block1` or `block`, and the next token is not `{`. Its first token sets the block indentation. A later token at the same indentation starts an item; smaller indentation ends the block; greater indentation continues the current item. Blank lines and comments do not affect layout.

Explicit blocks use braces and semicolons:

```text
f x = { y = g x; h y }
```

A block is either layout-controlled or explicitly braced. Nested blocks choose independently. Every expression block is nonempty and ends in an expression.

An expression block starts only with explicit `{` or with a newline and greater indentation immediately after an expression introducer: `=` in a value, pattern, or record-field declaration; `<-` in a `do` bind; or `->` in a lambda, `if` clause, or match clause. A single expression on the current line, such as `1`, is an `operator_expr`, not a one-item layout block. The parser opens the layout block before parsing its items; nested blocks have their own layout depth, so a `=` or `<-` inside one cannot classify a surrounding item.

For prefix `with`, the scrutinee ends at the following explicit `{` or at the newline that opens a more-indented match-clause block. Tokens in that new block cannot continue the scrutinee as application arguments. An unparenthesized multiline scrutinee must use an explicit enclosing expression block or parentheses. For `if` and `do`, the keyword itself is followed by an explicit or layout block. A postfix record `with` likewise requires `{` or a newline and greater indentation for its field block; the closing `}` or dedent ends the record expression before a following application argument.

## 5. Grammar

The parser introduces virtual block tokens on demand as described in Section 4. Section 14 defines operator grouping.

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

pragma          = "{-#", pragma_item,
                  { ",", pragma_item }, "#-}" ;
pragma_item     = upper_ident, { pragma_arg } ;
pragma_arg      = literal | lower_ident | upper_ident ;
signature       = signature_name, ":", type_expr ;
value_decl      = pattern_head, "=", expr, [ where_clause ] ;
pattern_head    = binding_name, { binder_pattern } ;
where_clause    = "where", block1(local_decl) ;
local_decl      = signature | value_decl | pattern_decl ;
pattern_decl    = binding_pattern, "=", expr, [ where_clause ] ;
binding_pattern = pattern excluding a bare binding_name or infix head ;

type_alias      = upper_name, { lower_ident }, "=", type_expr ;
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
lambda_expr     = binder_pattern, { binder_pattern }, "->", expr ;
operator_expr   = prefix_expr,
                  { (value_operator | upper_operator), prefix_expr } ;
prefix_expr     = "-", prefix_expr | application ;
application     = postfix_expr, { postfix_expr } ;
postfix_expr    = postfix_head, { ".", ident } ;
postfix_head    = atom | record_expr ;

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
record_expr     = record_constructor, "with", block1(record_field) ;
record_constructor = upper_ident | module_name, ".", upper_ident ;
record_field    = lower_ident, "=", expr, [ where_clause ] ;

pattern         = simple_pattern, { upper_operator, simple_pattern } ;
simple_pattern  = lower_ident | literal_pattern | "()"
                | constructor_pattern | product_pattern
                | list_pattern | "(", pattern, ")" ;
binder_pattern  = lower_ident | literal_pattern | "()"
                | upper_ident | product_pattern | list_pattern
                | "(", pattern, ")" ;
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
                | type_literal | list_constructor | product_constructor | function_constructor | list_type
                | "(", type_expr, ")" ;
type_literal    = integer | char | string ;
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

`non_lambda_expr` prevents an unparenthesized lambda arrow from competing with the structural arrow of an `if` clause or pattern guard. This restriction applies only at those two positions. A lambda remains usable there when parenthesized, because `paren_expr` contains a full `expr`. A nested condition such as `if { if { _ -> True } -> True; _ -> False }` is valid; the inner `if` has its own delimited clause block. The undelimited `if if if _ -> True -> True -> True` is invalid because those blocks are missing.

The parser treats `_` as a lowercase identifier in terms, types, kinds, and patterns. Name resolution interprets the exact name `_` as a wildcard in binder and pattern positions, as the unconditional `if` fallback when it is the whole clause condition, and as a hole in permitted expression, type, or kind positions. The clause arrow is structural because its condition is a `non_lambda_expr`, not because `_` receives special parser treatment.

`binder_pattern` is deliberately self-delimiting so adjacent function parameters remain unambiguous. Atomic, product, and list patterns may be binders directly. A constructor application or infix pattern must be parenthesized to form one binder:

```text
fromMaybe fallback (Just value) = value
uncons (x :: xs) = (x, xs)
mapPair f (x, y) = (f x, f y)

mapper = (Just value) fallback -> value
```

Without parentheses, adjacent atomic patterns denote separate binders.

An infix pattern is never a declaration head, even when parenthesized. `value_decl` starts with a `binding_name`; a local or `do` `=` `pattern_decl` may instead use a non-infix pattern such as `(a, b)`, `Just x`, or `[x, y]`. A bare lowercase name is a `value_decl`. Top-level declarations remain named. Thus `x :: xs = value` is invalid at top level, in a local block, in `where`, and in `do` `=`. A parenthesized infix pattern remains valid as a function argument, as in `uncons (x :: xs) = ...`. A `do` `<-` statement is a pattern bind rather than a declaration, but v0 rejects its infix pattern because `<-` accepts only irrefutable patterns. Parenthesized symbolic **value operator names**, such as `(++) xs ys = ...`, are binding names, not infix pattern heads.

### 5.1 Parsing decisions

The Concrete AST retains a postfix expression as a base atom followed by an uncommitted list of dotted identifier segments. In an upper-identifier-led chain ending in an uppercase name, name resolution takes the preceding uppercase components as a module path and the final one as an exported constructor. When a lowercase segment follows an uppercase prefix, the whole uppercase prefix is a module path and the first lowercase segment is its exported value; any later lowercase segments are field projections of that value. A constructor cannot be projected from directly, so `Person.name` is never a field projection of `Person`; it must resolve as value `name` from module `Person` or be rejected. `A.B.c` means `c` from module `A.B`, never field `c` of constructor `B` from module `A`. A module is never a runtime value. To project a constructed value, write `(Person "Ada" 36).name` or bind it to a lowercase variable.

Several productions share a syntactic prefix. They are resolved by token lookahead at the current nesting depth, not by name resolution:

- In a `do` block, `<-` selects a pattern bind, `=` selects a named or pattern declaration, and the absence of either selects an expression statement. Declaration statements use the same strict sequential binding semantics as expression blocks, including ordinary generalization rules; they do not desugar to immediately applied lambdas.
- In an expression block, `:` selects a local signature, `=` selects a named or pattern declaration, and the absence of either selects an expression.
- At top level, an initial upper name followed by optional lower identifiers is scanned through the first top-level `:` or `=`. `:` selects a signature and `=` selects a type alias. Integer, character, and string type literals make compiler-backed declarations such as `Byte = magic "u8"` ordinary type aliases syntactically.
- At the start of an expression, a sequence that can be parsed as binder patterns is parsed speculatively. A following top-level `->` commits it as a lambda; otherwise the parser rewinds to an operator expression.
- Prefix `with expr block1(match_clause)` is pattern matching. After a bare or module-qualified uppercase record constructor, `with block1(record_field)` is postfix record construction. Their token positions distinguish them without name resolution. An explicit `{` or the newline and indentation that opens the expected block ends the scrutinee or record receiver. The initial language restricts the postfix receiver to a constructor name; a future record-update feature may relax it.

The lookahead above observes tokens only at the current parser-driven layout depth. It never scans into a nested record, `with`, `if`, `do`, or expression block to find `=` or `<-` for an outer item. For example, `Person with` followed by an indented `name = "x"` is one record expression, not an outer declaration. These rules may be implemented with lookahead, backtracking, or a shared prefix representation. They must produce the same Concrete AST.

## 6. Names and scope

Values, constructors, fields, and modules have their respective namespaces; types and traits share one namespace. A type and a trait with the same name cannot coexist in one scope. Multiple pattern clauses defining one value form a single binding and are matched in source order. Duplicate declarations in one namespace and scope, other than clauses of that binding, are errors.

Scope is lexical and innermost-first. Sequential bindings in an expression or `do` block may shadow earlier local bindings, including bindings in the same block; each later right-hand side still sees the previous binding until its own initializer finishes. Shadowing emits a warning. Names within one mutually visible `where` or top-level group, and duplicate names within one pattern, remain duplicate-declaration errors. Import collisions require qualification or selective imports.

Lambda parameters scope over their body. Pattern variables scope over the corresponding guard and branch. A sequential binding scopes over later block items only. A `where` name scopes over its whole group and the expression preceding `where`.

All top-level declarations in a module are mutually visible. Name resolution precedes type inference.

Compiler-known library entities are identified by their defining module and declared name, not by the spelling used to import or qualify them. Aliases, selective imports, and re-exports preserve that identity. This applies to Prelude-dependent sugar and compiler-backed library bindings; the reserved primitive entities keep their own built-in identities.

## 7. Types

The primitive atomic types are:

```text
Int Float Bool Char String Unit
```

`Int`, `Float`, `Bool`, `Char`, `String`, and `Unit` are reserved primitive type names and are in scope in every module, including modules with `NO_IMPLICIT_PRELUDE` or `MAGIC`. `Type` is the reserved kind name for ordinary types. These names cannot be rebound in their respective namespaces or introduced into the local module-name scope by a bare or aliased import. They may still occur as components of a module path, as in `Data.Int`.

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

`[]`, `(*)`, and `(->)` are reserved built-in type-constructor names and cannot be rebound in the type namespace. This does not reserve the value-level multiplication operator `(*)`. Their runtime representations remain the ordinary list, binary-product, and function representations.

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

An ADT with exactly one constructor and exactly one field uses the runtime representation of that field, like Haskell's `newtype`: construction introduces no runtime tag, wrapper allocation, or boxing. The type remains nominal and distinct from its field type; constructor application and pattern matching retain ordinary Ficus strict semantics. This rule also applies to single-field nominal records. It does not make the declaration a transparent type alias.

```text
type UserId = UserId Int
```

`UserId` and `Int` remain distinct types even though their values have the same runtime representation. Trait ownership and implementation selection use the nominal type, not the erased representation.

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

Data.People.Person with { name = "Ada"; age = 36 }
```

Named fields may appear in any order and evaluate in source order. `person.name` projects a field. Record patterns are deferred; initial-language matching uses the positional constructor.

Field labels are local to their nominal record type, so different record types may reuse a label. Projection chains associate left:

```text
person.address.city
= (person.address).city
```

For each projection `e.field`, inference collects a field constraint on the receiver and result. Type variables mentioned by a pending field constraint stay monomorphic until that constraint is solved; they cannot be generalized when an inner `where` or other binding group closes. The compiler solves pending field constraints after ordinary constraints from the enclosing group and its use sites have fixed receiver types, but no later than the end of the containing module. If the receiver is then a known nominal record, it looks up `field` and unifies the result with the field type. A label alone does not select or infer a record type. An unresolved receiver, a known non-record receiver, or a record without the field is a type error; field constraints are never generalized. Thus `getName p = p.name` without a constraining use or signature is an error, while a `where`-bound projection may wait for the enclosing function body to determine `p`'s type.

Dotted module qualification is resolved before projection. A qualified value expression consists of a known module path, one exported lowercase value, then zero or more lowercase field projections. Qualified constructors are allowed in construction and patterns but cannot be projected from directly:

```text
Data.People.default.address.city
```

Here `Data.People` is the module, `default` is its exported value, and `address.city` is a projection chain. As specified in Section 5.1, the Concrete AST keeps the dotted chain uncommitted and name resolution selects the qualified value boundary.

Postfix `with` explicitly introduces the layout block for named construction. A record block may therefore use layout or explicit braces, but an upper identifier followed only by an indented line never starts a record block. Prefix `with` remains pattern matching and does not conflict with this postfix use. Each field initializer may have its own `where` clause; its local declarations scope only over that field's expression. The receiver is a bare or module-qualified uppercase record constructor, whose identity fixes the record type. A record cannot declare the same label twice. Field labels are not standalone values. Record update is unsupported; a future update form may reuse postfix `with` with a less restrictive receiver.

The record field block must start with `{` or on a more-indented next line. `f Person with x = 1 y` is invalid because no field block starts after `with`. In `f (Person with { x = 1 }) y`, the braces delimit construction before `y` is parsed as the next argument.

### 7.3 Aliases, signatures, and annotations

A declaration without `type` normally defines a transparent, non-recursive alias:

```text
Point = Int * Int
Parser a = String -> [a * String]
```

Type expressions admit integer, character, and string literals as compile-time type arguments. Floating-point literals are excluded from type expressions. The validity and kind of an admitted literal are checked during elaboration. This permits a compiler-backed type binding such as `Byte = magic "u8"` to use the ordinary type-alias grammar. Such a binding elaborates to an opaque compiler type rather than a transparent alias.

Signatures constrain inferred types. An annotation `(e : T)` constrains `e`; it does not pass a runtime type argument.

Type aliases may have an optional top-level kind signature, checked against the definition. Their parameters remain bare names: annotations in alias arguments, such as `Parser (a : Type) = ...`, are invalid. An alias must always be fully applied where used, and aliases may not form direct or indirect cycles. Type parameters of ADTs, records, and traits may carry optional kind signatures; bare parameters still have their kinds inferred:

```text
Parser : Type -> Type
Parser a = String -> [a * String]

type Box (a : Type) = Box a

type Container (f : Type -> Type) a = Wrap (f a)

trait Functor (f : Type -> Type) =
    map : (a -> b) -> f a -> f b
```

The parser treats `Type` in a kind expression as an ordinary uppercase name; name resolution and kind checking give the reserved kind name its meaning. It must not be hardcoded as a special kind token or parser branch. A kind annotation on an ADT, record, or trait parameter does not introduce a runtime type argument. As with other type-only declarations, aliases still require a definition. A kind signature may use `_` as an inference hole, for example `type Box (a : _) = Box a` or `Parser : _ -> Type`. Each kind hole is inferred from the declaration. After kind inference, any unconstrained kind variable, including an unsolved kind hole, defaults to `Type` with a warning.

Recursive ADT definitions must be regular: a recursive occurrence uses that ADT's declared type parameters unchanged and in the same order. Non-regular recursion such as `type Nest a = Wrap (Nest [a])` is a static error, including when it passes through a mutually recursive group.

### 7.4 Type signature holes

`_` in a value signature or expression annotation is a fresh type hole. Each occurrence is independent and may stand for a type of any inferred kind, including a type constructor. Inference unifies the written skeleton with the inferred principal type, fills the holes, retains any residual inferred predicates, and then applies the ordinary signature checks and v0 value restriction.

```text
double : Int -> _
double x = x + x
-- completed as Int -> Int

foo : _ -> _ _ Int
foo x = (1, x)
-- completed as Int -> (Int * Int)
```

The second example is valid: the constructor-position hole is inferred as `(*)`, and the following hole as `Int`. Type holes are permitted in value signatures and expression annotations where there is an expression or definition to infer from, and kind holes are permitted in kind signatures as described above. Type holes remain invalid in alias right-hand sides, data bodies, trait member signatures, implementation heads, and other type-only positions. Holes do not denote named variables and two holes need not infer the same type.

Name resolution classifies a standalone `_` in an expression position as an expression hole, and `_` in a binder or pattern position as a wildcard. An expression hole is accepted by the parser but always causes a hard compilation error after inference. The diagnostic must show the hole's inferred type (including any remaining type variables) and its source location; a hole is never executable or silently filled.

## 8. Built-in algebraic forms

`Unit` has the sole value and pattern `()`.

`Bool` has the predefined nullary constructors `True` and `False`. Like `::`, they use ordinary grammar—in this case `upper_ident` and ordinary constructor patterns—but name resolution gives them reserved built-in meanings. They are always available and cannot be declared, imported as different entities, shadowed, or rebound. Conditions require `Bool`; truthiness is not overloadable.

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

List literals elaborate to `::` and `[]`. Elements evaluate left-to-right.

`::` is the predefined list constructor:

```text
(::) : a -> [a] -> [a]
```

It is always available and cannot be declared, imported as a different entity, shadowed, or rebound. Parsing gives it no special case: it is an ordinary colon-led constructor operator in expressions and patterns, with the precedence and right associativity determined by its spelling.

## 9. Expressions and bindings

Evaluation is strict, call-by-value, deterministic, and left-to-right.

Application binds tighter than infix operators. In `f a b`, evaluate `f`, then `a`, apply, then evaluate `b` and apply again. A definition `f x y = body` is equivalent to `f = x -> y -> body`, except that its attached `where` group is placed after all written parameters as specified in Section 12. By contrast, `f x = y -> body` has only one written parameter, so its attached `where` group runs after `x` is supplied and before the resulting lambda is returned. Any work between curried applications remains observable; arity raising may combine calls only when it preserves that timing and strict left-to-right effects. Lambdas capture their lexical environment. A failed parameter pattern is a runtime match error.

An expression block evaluates items in order and returns its last expression. A local named declaration evaluates its right side immediately and binds the name; a local pattern declaration evaluates its right side once, matches the non-infix head pattern, then binds its variables for later items. A failed local pattern is a runtime match error. Sequential shadowing is permitted with a warning as specified in Section 6.

```text
swap pair =
    (a, b) = pair
    (b, a)
```

Constructors, products, lists, positional record fields, and named record fields evaluate left-to-right. Field projection evaluates its receiver first.

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

For a v0 `do` `<-` bind, only variable patterns, `_`, `()`, and products whose elements are all irrefutable are irrefutable. All other patterns, including constructors, lists, literals, and infix constructor patterns, are refutable and rejected in this position.

Symbolic uppercase constructors may be used in prefix or infix patterns:

```text
(:+) x xs  -> ...
x :+ xs    -> ...
x :: xs    -> ...
Data.People.Person name age -> ...
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

`if` remains a distinct conditional through Abstract and Core AST; it is not desugared to `with`. Its eventual Runtime AST lowering may choose an appropriate branch representation.

Conditions run top-to-bottom until one is `True`; only its result runs. `_` is unconditional and must be last. Reaching the end is a runtime match error. Conditions and guards have type `Bool`.

## 12. Recursion and `where`

Ordinary expression-block and `do` `=` bindings are sequential and non-recursive, including local pattern declarations.

`where` introduces a mutually visible group. Before the enclosing function body runs, the compiler evaluates the group's declarations in dependency order. Among declarations whose dependencies are satisfied, source order decides which is evaluated first.

The compiler forms a dependency graph across mutually visible top-level declarations, `where` groups, and `impl` dictionaries and their members, then checks each strongly connected component (SCC). A cyclic SCC is accepted only when each initializer is non-expansive and every intra-SCC reference is beneath a lambda in its initializer after written parameters are desugared. Non-expansive initializers are the forms listed for `impl` members in Section 16; in particular they cannot call a captured closure during initialization. A variable reference to another slot in the same SCC is not protected merely because some later use is beneath a lambda. Other cycles are static errors.

When a cyclic SCC is reached, its slots are allocated first. Its right-hand sides are then evaluated in source order. The non-expansive check prevents a captured reference from being invoked during this phase; the lambda-protection check prevents an eager read of another uninitialized slot. An acyclic `impl` member initialized from a top-level variable reads it only after its dependency has been initialized. After every required `where` declaration has been initialized, the enclosing body runs. Top-level and `impl` initialization follow the same dependency-order and SCC rules.

For `f x y = body where ...`, the `where` group runs after both written parameters have been supplied, immediately before `body`. For `f x = y -> body where ...`, it runs after `x` has been supplied, before the returned lambda is created. A declaration with no written parameters runs its `where` group before its right-hand side is evaluated. These positions are observable and cannot be moved by arity raising.

An explicitly signed binding may be used polymorphically within its recursive SCC: each recursive reference instantiates its signature independently. An unsigned binding has one monotype throughout the SCC. This typing distinction does not relax either cyclic-initializer check.

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

Tail-call optimization depends on the backend. v0 does not guarantee constant stack use for tail-recursive calls.

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

Qualified operator references use a module path followed by a parenthesized operator, for example `Data.List.(++)`. Bare operators are infix only, and v0 has no operator sections: `(x +)` and `(+ y)` are invalid.

Infix declaration heads are invalid. Thus `xs ++ ys = ...` is not a function definition. Constructor declarations follow the same rule: `(:+) a (Chain a)` is valid in a type body, while an infix constructor declaration is not.

Colon-led operators inhabit the uppercase namespace. At the value level they construct values rather than naming ordinary functions; at the type level they construct types. Bare `:` is grammatical punctuation; `::` is a reserved constructor name.

Precedence follows Scala's symbol categories and is determined by the first character of an operator. The same grouping rules apply to expression operators, type operators, and infix constructor patterns where those forms admit the operator. The complete table is ordered from highest to lowest precedence:

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

`::` follows the table exactly like every other colon-led operator: it has the `:` group's precedence and is right-associative because its name ends in `:`. Only name resolution and typing reserve its list-construction meaning.

Type-level `*` forms products and is unrelated to value-level `*`.

## 15. Type inference

Ficus uses Hindley–Milner inference with qualified types.

- Polymorphic uses instantiate fresh variables.
- Equality constraints use unification with an occurs check.
- Generalization follows the v0 value and monomorphism restrictions below.
- A signature may be less general than the inferred type, but not more general.
- An annotation unifies its written and inferred types.
- A signature or annotation hole introduces a fresh metavariable, which may have a higher kind and is completed from the inferred type.

Inference covers the complete module after name resolution. Accepted unconstrained definitions have principal types, subject to trait ambiguity.

At each binding-group boundary, the v0 value restriction generalizes variables not free in the environment only when the initializer is non-expansive: a lambda (including a definition with written parameters), literal, variable, constructor, or aggregate of non-expansive values. Applications, including partial applications, projections, conditionals, matches, `do`, and expression blocks are expansive. Their result variables remain monomorphic. A signature cannot override this restriction; in particular, `inc = (+) 1` cannot acquire a polymorphic type merely by adding one.

The v0 monomorphism restriction further keeps an **unsigned**, constrained binding monomorphic when it has no written parameters or outer lambda, even if its initializer is non-expansive. A complete signature may override this extra restriction when the value restriction permits generalization and the definition checks against it; a signature with holes cannot. Otherwise, unresolved trait predicates must be solved for the binding's one monotype. This restriction concerns constrained bindings only; it does not prevent generalizing an unconstrained non-expansive value.

Within a recursive group, signed bindings may be used polymorphically at their declared schemes, while unsigned bindings use one monotype until the group boundary. Each definition must satisfy its signature and the value restriction. Missing parts of a signature containing holes are inferred without assuming polymorphic recursive use of those parts. The separate non-expansive and lambda-protection checks for cyclic initialization still apply.

```text
displayFn x = show x  -- may generalize under Show a
displayMono = show    -- unsigned: monomorphic; Show must resolve for one type

displayPoly : Show a => a -> String
displayPoly = show    -- signed: polymorphic despite having no lambda parameter
```

Weak type variables left by the value or monomorphism restriction may be fixed by later uses within the module, but are never generalized implicitly. Any weak variable still unresolved when module inference ends is a static error, even when it has no trait predicate (for example, an unused `r = newRef []` once references are available).

`(->)` is a built-in type constructor of kind `Type -> Type -> Type`. It may be partially applied, so `(->) r` has kind `Type -> Type` and may appear in higher-kinded holes and implementation heads such as `impl Functor ((->) r)`. The infix `a -> b` is its right-associative notation.

A constrained type is ambiguous when a variable used by a predicate does not occur in the unconstrained value type:

```text
foo : C a => Int  -- invalid: a does not occur in Int
```

Version 0 rejects every such type, whether inferred or explicitly written. Signatures and annotations do not provide an escape hatch.

## 16. Traits and qualified types

A trait has one parameter and optional supertraits:

```text
trait Show a =
    show : a -> String

trait Functor f =
    map : (a -> b) -> f a -> f b

trait Pure f =
    pure : a -> f a

trait Apply f =
    ap : f (a -> b) -> f a -> f b

trait (Functor f, Pure f, Apply f) => Applicative f = {}

trait Bind f =
    bind : f a -> (a -> f b) -> f b

trait (Applicative f, Bind f) => Monad f = {}
```

Qualified types place predicates before `=>`. An `impl` supplies every method exactly once.

A trait method signature may add constraints on method-level variables other than the trait parameter. For example, `Traversable t` may declare `traverse : Applicative f => (a -> f b) -> t a -> f (t b)`; `f` is constrained by the method even though the trait is parameterized by `t`. These constraints are checked and supplied at method use sites alongside the trait's own constraint. Every method's value type must mention its trait parameter; `trait C a = { foo : Int }` is invalid because no use of `foo` can determine `a`.

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

For a module, visible implementations are those declared locally or in the transitive closure of its explicit and implicit imports, including Prelude unless disabled. Merely existing elsewhere in a build does not make an implementation visible. For any ground predicate among visible implementations, at most one implementation may match. Resolution recursively resolves its context and supertraits. Failure, overlap, or an implementation-resolution cycle is a static error. Trait use is therefore coherent and independent of import order within that visibility set.

Trait implementations are selected by these rules regardless of runtime representation. Trait bodies contain signatures only, and every `impl` supplies every declared member. Default member bodies and fallback instance implementations are unsupported. Local implementations are unsupported.

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

An `impl Eq T` does not define `(/=)`, and an `impl Ord T` does not define `(<)`. Callers use these functions directly with the corresponding trait constraint; no forwarding definition inside an `impl` is required. The functions use ordinary trait resolution and never fill missing declared members.

A trait or implementation may use an explicit empty block `{}`. This supports marker traits that bundle only supertrait requirements, such as Prelude's `Applicative` and `Monad`. Layout-controlled trait and implementation blocks remain nonempty.

Every member supplied by an `impl` must have a non-expansive right-hand side after its written parameters are desugared to lambdas. This applies whether or not the member belongs to a recursive group; a signature cannot override it. Non-expansive forms are:

- variables, literals, and constructors;
- lambdas;
- products, lists, and records whose components are non-expansive;
- constructor applications whose arguments are non-expansive;
- annotations around non-expansive expressions.

General function application, blocks, conditionals, matching, `do`, projection, and primitive calls are expansive. They are rejected as immediate implementation-member initializers, although they may appear inside a member's lambda body.

```text
impl Show Person =
    show person = computeAndPrint person  -- allowed: effect occurs on call

impl Monoid Log =
    empty = makeInitialLog ()             -- invalid: call runs during initialization
```

This restriction makes trait dictionary initialization observationally pure and independent of initialization order.

## 17. `do` notation

`do` is Prelude-dependent surface syntax for the Prelude's `Bind` abstraction, lambdas, and strict sequential bindings, not special IO sequencing:

```text
do { p <- e; rest }  => bind e (p -> do { rest })
do { declaration; rest } => strict sequential binding of declaration, then do { rest }
do { e; rest }       => bind e (_ -> do { rest })
do { e }             => e
```

Here `declaration` may be a named definition with parameters or a local non-infix pattern declaration. It uses the same evaluation, pattern matching, generalization, and shadowing rules as a declaration in an expression block; it is not encoded as an immediately applied lambda. Thus `do { f a = a; rest }` binds the closure `f`, and `do { x <- action; x <- next x; rest }` is valid, with a shadowing warning for the second `x`. `bind` comes from the Prelude's `Bind` trait. In v0, `<-` accepts only the irrefutable patterns defined in Section 10; every refutable pattern is a static error. In a `NO_IMPLICIT_PRELUDE` or `MAGIC` module, use of `do` is a static error rather than a desugaring.

## 18. String interpolation

In v0, `{name}` embeds one variable, and `{Module.name}` embeds one qualified variable. A qualified name has one or more uppercase module components followed by one lowercase value name. The braces cannot contain operators, applications, field projections, or other expressions. `{{` and `\{` produce a literal `{`; `}}` and `\}` produce a literal `}`. An escaped opening brace never begins interpolation. Any unmatched, unescaped single brace is a lexical error.

```text
"hello {name}"
"hello {Data.Greetings.name}"
"literal \{name\}"
"sum {x + y}"  -- invalid in v0
```

Interpolation elaborates to left-associated concatenation of literal segments and `show` calls on the referenced variables. Segments and variable uses evaluate left-to-right. Each embedded variable adds its required `Show` constraint. `Show String` is the identity, so interpolating a `String` does not add quotation marks. A string without interpolation is a plain `String`.

The `Show` method and concatenation operation come from the Prelude. In a `NO_IMPLICIT_PRELUDE` or `MAGIC` module, an interpolated string is a static error; ordinary string literals remain available.

## 19. Magic modules

`{-# MAGIC #-}` is a module-level pragma that:

- implies `{-# NO_IMPLICIT_PRELUDE #-}`;
- brings the compiler-provided identifier `magic` into scope;
- permits explicitly signed type and value bindings to compiler internals.

Conceptually:

```text
magic : {k : Sort} -> StringLiteral -> k
```

`Sort` is the compiler-level collection of classifiers accepted for a binding. It covers both ordinary value types and kinds:

```text
classifier          classifies
Int                 integer values
Int -> Int          functions
Type                proper types
Type -> Type        unary type constructors
```

The notation `k : Sort` is meta-notation meaning “`k` may be any such type or kind”; it is not an ordinary Ficus typing judgment. It lets `magic` produce either a value with an ordinary type or a type constructor with a kind. It does not add first-class kinds, dependent types, or a user-visible `Sort` type to Ficus.

`StringLiteral` means one string token known at compile time. It is distinct from the runtime type `String`: a variable, computed string, concatenation, or interpolated string cannot be passed to `magic`. The literal is a compiler key, not a runtime argument.

`Sort`, `StringLiteral`, and the implicit binder notation describe the compiler interface; they are not ordinary Ficus types. `magic` is lexed and parsed as a normal lowercase identifier. In a type alias, `magic "key"` is an ordinary type application because strings are type atoms; in a value binding, it is an ordinary expression application. In a `MAGIC` module, name resolution supplies the compiler binding in the applicable namespace. It takes exactly one string literal, and a declaration initialized from it must have an explicit signature. During elaboration, the compiler checks that use is confined to such a declaration and validates the expected type or kind from its signature against the selected key. Invalid placement or arguments, unknown keys, and signature mismatches are static errors reported during elaboration.

```text
{-# MAGIC #-}

Handle : Type
Handle = magic "handle"

Byte : Type
Byte = magic "u8"

Vec : Type -> Type
Vec = magic "array"

addInt : Int -> Int -> Int
addInt = magic "addInt"
```

Only the compiler-provided `magic` binding has this behavior; the spelling is not a keyword and has no special parsing rule. Uses that resolve to this binding parse normally and are rejected during elaboration when they do not satisfy the restrictions above. An unrelated identifier with the same spelling has ordinary language semantics. Opaque types such as `Byte`, `Handle`, and `Vec`, together with primitive functions, are supplied by ordinary library modules written this way. They are not primitive language types. The compiler registry recognizes each such declaration by its defining module and name, irrespective of an import alias or re-export.

## 20. Prelude

The Prelude is a library, not core semantics. It should provide arithmetic traits, `Eq`, `Ord`, `Show`, `Bind`, list and string operations, IO helpers, `Void`, `absurd : Void -> a`, and common combinators, backed where necessary by imports from `MAGIC` modules.

The Prelude is imported implicitly unless the module has `NO_IMPLICIT_PRELUDE` or `MAGIC`. The six reserved primitive types remain in scope either way.

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
- expansive cyclic initializers or unprotected recursive references;
- invalid record fields or constructor arity;
- invalid or forbidden refutable patterns;
- use of Prelude-dependent sugar when the implicit Prelude is disabled;
- invalid `magic` placement, key, argument, or signature during elaboration.

Runtime errors include failed pattern matches and primitive failures. Diagnostics should follow the detailed style of `rustc`: a clear explanation, source excerpts, and labeled spans identifying the relevant expressions or declarations. Exact wording is unspecified; suggested fixes are deferred.

A limited set of humorous diagnostics is acceptable when it still explains the error accurately. For example, `foo : Int -> Type` may explain that Ficus is not dependently typed; `bar : Type -> Bool` may additionally suggest expressing the intended behavior through traits. These are explanatory hints, not automated fixes.

## 22. Deferred features

The initial language excludes:

- expression interpolation beyond a variable or qualified variable;
- record update and comma-style record literals;
- record patterns, including record punning;
- empty type bodies and empty `with` matches;
- visible type application and explicit `forall`;
- deriving, including the reserved `DERIVE` pragma;
- lazy arrows `~>`, which replace the earlier prefix-`~` proposal;
- private, deprecation, and compiler-option pragmas, and inline expression-level pragmas;
- multiparameter traits, associated types, and type families;
- GADTs, higher-rank polymorphism, and dependent types;
- unrestricted mutable references and mutable arrays;
- effect systems, concurrency, and async syntax;
- macros, ownership types, and custom memory management.

Private pragmas, lazy arrows, concurrency, exceptions, empty type bodies and matches, and mutable references are planned for v1+ with the designs below. Initial deriving support is limited to structural implementations such as `Show` and `Eq`; arbitrary trait derivation is outside that initial scope. These features remain excluded from v0. Other excluded features remain open design decisions; excluding them from v0 does not settle their future syntax or semantics.

v1+ extends string interpolation to expressions inside `{...}`. Its precise delimiter and escaping rules remain to be specified.

### v1+ empty types and empty matching

v1+ accepts empty record/type bodies and empty `with` blocks:

```text
type Void = {}

absurd : Void -> a
absurd x = with x {}
```

Empty records and empty ADTs share exactly the same syntactic form: `type T = {}`. With no fields or constructor declarations, the parser cannot distinguish the record and ADT alternatives from their contents. This case requires special care in parsing and must have the same meaning whichever alternative would otherwise be selected.

An empty body defines an uninhabited nominal type and introduces no constructor, including no positional record constructor named `T`. Consequently, `Void with {}` is invalid: an empty record body does not provide a constructor for named construction. This differs from `type T = { T }`, which explicitly declares a nullary constructor.

As an optional diagnostic, the compiler may warn that an empty body is uninhabited and suggest a single-constructor ADT with no fields when the intended type is unit-like, for example `type Token = { Token }`. This is advisory only: an intentionally empty type such as `Void` remains valid.

An empty `with` eliminates an impossible scrutinee and may have any result type. These source definitions replace the v0 magic-backed `Void` and `absurd` while preserving their Prelude API.

Exhaustiveness checking must account for uninhabited types: an empty match on `Void` is exhaustive. An empty match must not be accepted as exhaustive merely because it has no clauses when its scrutinee type may be inhabited. The detailed treatment of uninhabited types inside other patterns and the diagnostic policy remain open. The v0 grammar continues to require nonempty type bodies and match blocks; v1+ extends those productions to admit `{}`.

### v1+ record patterns

Record patterns use explicit braces and mirror named construction without punning, for example `Point with { x = px; y = py }`. They are allowed in `with` clauses, lambda/function arguments, non-recursive value bindings, and both forms of `do` binding: `pattern <- expr` and `pattern = expr`. They are not allowed in recursive `let` groups. At top level or inside `where`, reject a binding headed by a record pattern when it participates in a recursive strongly connected component; the error should suggest matching with `with` inside a named function instead. The parser must distinguish pattern syntax from record construction by context. In `do`, a record pattern may appear on the left of either `<-` or `=`, for example:

```text
do
    Point with { x = px; y = py } <- nextPoint
    Point with { x = qx; y = qy } = otherPoint
    consume px py qx qy
```

Whether record punning is supported remains undecided.

### Deferred lazy arrows

The reserved lazy function arrow is `~>`. When introduced, it will be type punctuation rather than an ordinary symbolic operator and will associate right like `->`. It is distinct from the strict arrow; inference defaults to `->`, and every lazy arrow must be written explicitly in a signature.

```text
and : Bool ~> Bool ~> Bool
and x y = with x
    True -> y
    False -> False
```

Both parameters are passed as thunks. Elaboration inserts a thunk at each lazy call argument and forces a parameter at its first demanded use, sharing the result thereafter. Schematically, `and a b` becomes `and' (_ -> a) (_ -> b)`, where `and'` accepts `Unit -> Bool` thunks. The exact Core representation, sharing behavior, and interaction with effects require the later revision.

### Deferred concurrency primitives

An explicit v1+ library module exposes magic-backed fibers and channels:

```text
Fiber : Type -> Type -> Type
Fiber = magic "fiber"

Chan : Type -> Type
Chan = magic "chan"

fork : Exception e => (Unit -> a) -> Fiber e a
fork = magic "fork"

join : Fiber e a -> Result e a
join = magic "join"

newChan : Unit -> Chan a
newChan = magic "newChan"

send : Chan a -> a -> Unit
send = magic "send"

recv : Chan a -> a
recv = magic "recv"
```

At call sites, `Unit` is introduced with `()`, for example `fork (() -> work)` and `newChan ()`.

`fork` schedules its thunk concurrently. Its first type parameter records the exception type. In the current v1+ interface, `join` waits and returns either `Ok value` or `Err exception` without existentially hiding that type. `send` and `recv` communicate through a typed channel; whether channels are buffered and how cancellation works remain unspecified.

These declarations are not part of implicit Prelude. The v0 value restriction already prevents generalization of expansive bindings such as `channel = newChan ()`.

### Deferred exception primitives

The initial v1+ Prelude defines the marker trait:

```text
trait Exception e = {}
```

An explicit v1+ magic-backed exception module provides:

```text
throw : Exception e => e -> a
throw = magic "throw"

catch : Exception e => (Unit -> a) -> (e -> a) -> a
catch = magic "catch"
```

`throw` does not return normally. `catch action handler` runs `action ()`; it invokes `handler` for an exception of the statically selected type `e` and propagates other exceptions. An uncaught fiber exception is preserved as the `e` parameter of `Fiber e a` and returned by `join` as `Err e`.

`Exception e` has no source-level methods, but typed `catch` needs a runtime identity for `e`. Nominal types such as `UserId` and `Int` can have identical erased value representations, and a polymorphic `Exception e => ...` cannot reconstruct `e` from a value after erasure. The runtime representation of this evidence is therefore **unsettled**. A correct implementation must preserve a nominal type token, either in non-erased exception evidence or in another runtime type representation carried through `throw`, `catch`, and fibers. Erasing `Exception e` to unit without such a token is invalid. The exact representation and matching mechanism remain open.

The v1+ exception and concurrency signatures above remain the proposed initial interfaces, subject to the possible existential-error change described below. Exception type discrimination is an unresolved implementation and representation requirement, so the exception operations cannot be considered implementable until it is settled. Cleanup, nesting, interaction with effects, and standard `Exception` instances also need operational detail.

### v1+ mutable references

The mutable-reference design is settled for v1+ as written. An explicit magic-backed state module provides:

```text
Ref : Type -> Type
Ref = magic "ref"

newRef : a -> Ref a
newRef = magic "newRef"

modifyRef : Ref a -> (a -> a) -> Unit
modifyRef = magic "modifyRef"

readRef : Ref a -> a
readRef = magic "readRef"
```

`newRef` allocates a mutable cell. `readRef` returns its current value. `modifyRef ref f` reads the current value, applies `f`, stores the result, and returns `()`.

The v1+ `Ref` design retains the v0 value restriction: expansive bindings such as `ref = newRef []` must not be generalized. Atomicity and interaction with fibers remain unspecified.

## 23. Program entry point

v0 supports exactly these `main` signatures:

```text
main : [String] -> Unit
main : [String] -> Result String Unit
```

The entry function takes command-line arguments and either returns `Unit` directly or reports a string error through `Result`. `main : Unit` and a polymorphic `Show a => [String] -> Result a Unit` entry point are unsupported. Argument conventions, error reporting, and exit-status details remain to be specified. Exception handling at the entry point belongs to v1+.

## 24. v1+ compiler artifacts, CLI, pragmas, and libraries

### Compiler artifacts

The compiler will generate both a module interface file and an object file, using Lisp-like syntax for both. Until the v2+ WebAssembly GC backend is available, the object file is a textual representation of Runtime AST. The concrete schema, file extensions, and compatibility/versioning details remain to be specified.

### Initial v1+ CLI

```text
ficus compile FILES
ficus run FILE
ficus repl [FILE]
ficus format [-f FILE]
ficus lsp
```

- `compile FILES` generates interface files and textual Runtime AST object files only, until the v2+ WebAssembly GC backend is available.
- `run FILE` executes a source file.
- `repl [FILE]` starts an interactive session, optionally loading a source file.
- `format [-f FILE]` provides the naive formatter based on Concrete AST and accepts an optional file argument.
- `lsp` starts the language server, initially supporting semantic highlighting, jumping to definitions, and showing types.

Output paths, REPL loading details, and formatter input/output behavior remain open; the command surface does not settle those choices.

### Deprecation pragma

v1+ adds:

```text
{-# DEPRECATED ident+ ["<message>"] #-}
```

Here `ident+` means one or more identifiers, and the bracketed string is an optional message; `+` and the brackets are notation, not literal pragma tokens. The pragma marks the listed identifiers as deprecated and may provide a message for diagnostics at their use sites. For example:

```text
{-# DEPRECATED oldName olderName "Use newName instead" #-}
```

Detailed name-targeting, placement, and warning-policy rules remain to be specified.

### Module compiler-options pragma

v1+ adds the module-level pragma:

```text
{-# OPTIONS [compiler options] #-}
```

The bracketed phrase is a placeholder for compiler options, not a settled argument grammar. The actual options, flags, and warnings remain to be specified. This pragma appears with module pragmas before imports. Its option syntax and interaction with command-line options require a later grammar revision; the v0 generic pragma-argument production does not define them.

### Expanded libraries

v1+ provides a larger Prelude in the style of Haskell, together with JSON and regular-expression support. JSON and regex facilities may be backed by `MAGIC` modules. Their APIs, module organization, and implicit re-export policy remain open; this plan does not replace the existing fine-grained control-trait design.

### Deferred private pragmas

The v1+ syntax is `{-# PRIVATE [mod] #-}`, where the optional modifier is `members`. It is excluded from v0. These examples record the intended future distinction:

```text
{-# PRIVATE #-}
foo x = x

-- hide the type and its members
{-# PRIVATE #-}
type Local a =
    Local a

-- hide constructors only
{-# PRIVATE members #-}
type Map k a = { Leaf k a; Node (Map k a) (Map k a) }

-- hide fields only
{-# PRIVATE members #-}
type Complex =
    real : Float
    imaginary : Float
```

Inline pragmas for individual constructors or local definitions are also deferred and may remain unsupported.

### Draft v1+ explicit type variables and application

A tentative syntax introduces type variables in signatures with curly-braced binders, each optionally kind-annotated, and applies them positionally with explicit braces:

```text
foo : {a} -> Show a => a -> String
foo {Int} 1
```

For example, `{f : Type -> Type}` would bind a higher-kinded variable. The order of binders determines the order of explicit type arguments. This syntax is draft only and may change if it causes parsing ambiguity; it is not part of v0.

### Existential record type members (v1+ or v2+)

A proposed declaration mixes an uppercase abstract type member with lowercase value fields in one record body:

```text
type SomeException =
    Err : Type
    showErr : Err -> String
```

Here `Err` names a hidden representation type, while `showErr` is a runtime operation over values of that type. This is an existential package in the style of *Types and Programming Languages*, not a path-dependent type. The v1+/v2+ parser must distinguish `Err : Type` from an ADT constructor declaration and accept both member categories in one record body.

When record patterns and existential type members are both available, the proposed unpacking pattern is:

```text
SomeException with { Err = e; showErr = se } = ...
```

`Err = e` introduces a fresh named local **type variable** `e` for the hidden witness; it does not compare or match the member against a concrete type. `showErr = se` binds the runtime operation as a value. The type variable is scoped to use of the unpacked package; the value binder follows the enclosing pattern binding. A type member cannot be matched as a value or constructor, and type checking must prevent `e` from escaping the unpacking scope. Runtime representation and dispatch through `showErr` and other packaged operations are required. The declaration and unpacking patterns above are proposed; package construction syntax and the release version remain open. See [TAPL, Chapter 24](https://www.cis.upenn.edu/~bcpierce/tapl/contents.pdf).

Existentials could also support a `SomeException`-like package for heterogeneous errors in v1+. If adopted, it may change the exception and concurrency interfaces above, including the current `Fiber e a`/`join` result types. That possibility does not commit to an existential error API yet.

## 25. v2+ backend, build system, and FFI

v2+ adds:

- a WebAssembly GC backend;
- a simple build system with support for libraries beyond Prelude and dependency resolution;
- a foreign-function interface (FFI).

Build configuration, package/dependency formats, resolution rules, and the FFI syntax, targets, and calling conventions remain to be specified.

## 26. Remaining open design decisions

Record update remains an open design decision, including its syntax, receiver forms, and evaluation behavior. The other previously open choices not settled by this revision remain open as well, including record punning, the release and syntax of existential record type members, and the detailed exhaustiveness treatment of uninhabited types. The value restriction starts in v0 and also applies to the v1+ mutable-reference API; atomicity and interaction with fibers remain unspecified. Other v1+ feature plans likewise preserve details already identified as unspecified.

The exact compiler artifact schemas and entry-point argument, reporting, and exit-status conventions also remain open. This revision does not select defaults for those details.

The v1+ exception runtime identity mechanism remains open: typed `catch` must distinguish nominal types after newtype erasure, including through polymorphic `Exception e` uses. Integer division, literal range, conversions, floating-point display, and the remaining lexical details listed in `PLAN.md` also remain unsettled.
