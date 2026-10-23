-- | Resolved, untyped syntax. This module never imports Concrete syntax.
module Ficus.Syntax.Abstract (module Ficus.Syntax.Abstract, Entity (..), FieldDescriptor (..), NameSummary) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Ficus.Syntax.Literal (Literal)
import Ficus.Syntax.Name
import Ficus.Syntax.Pragma (ModuleOptions)
import Ficus.Util.Source

data Node a = Node {nodeId :: NodeId, nodeSpan :: Span, nodeOrigin :: Provenance, nodeValue :: a} deriving (Eq, Show)

type Binder = Node (LocalId, Text)

type TypeBinder = Node (TypeVarId, Text, Maybe KindSyntax)

type Expr = Node ExprF

data ExprF
  = Ref Reference
  | Constructor GlobalId
  | Method GlobalId
  | Literal Literal
  | Hole HoleId
  | Apply Expr Expr
  | TypeApply Expr [TypeArgument]
  | Annotated Expr [TypeBinder] TypeSyntax
  | Lambda Binder Expr
  | TypeLambda [TypeBinder] Expr
  | Match Coverage Expr [MatchClause]
  | Conditional [IfClause]
  | Sequence [Statement] Expr
  | Where WherePlan BindingGroup Expr
  | Project Expr (Node Text)
  | ConstructRecord GlobalId [FieldAssignment]
  | PackRecord GlobalId [Node (Text, TypeSyntax)] [FieldAssignment]
  | UpdateRecord Expr [FieldAssignment]
  | Product [Expr]
  | List [Expr]
  | Unit
  | Negate Expr
  deriving (Eq, Show)

data Coverage = WarningCoverage | RequiredTotal deriving (Eq, Show)

type MatchClause = Node (Pattern, Maybe Expr, Expr)

type IfClause = Node (Maybe Expr, Expr)

type FieldAssignment = Node (Text, Expr)

type Statement = Node StatementF

data StatementF = Effect Expr | BindStatement BindingGroup deriving (Eq, Show)

type Pattern = Node PatternF

data PatternF = Bind Binder | Wildcard | ConstructorPattern GlobalId [Pattern] | LiteralPattern Literal | ProductPattern [Pattern] | ListPattern [Pattern] | UnitPattern | AnnotatedPattern Pattern TypeSyntax | NegatedPattern Pattern | OpenPattern [(Text, TypeBinder)] Pattern deriving (Eq, Show)

type TypeSyntax = Node TypeF

-- Retain the @-argument site separately from the enclosed type's location.
type TypeArgument = Node TypeSyntax

data TypeF = TypeVariable TypeVarId | TypeConstructor GlobalId | TypeApplication TypeSyntax TypeSyntax | ArrowType TypeSyntax TypeSyntax | LazyArrowType TypeSyntax TypeSyntax | QualifiedType [Predicate] TypeSyntax | TypeHole HoleId deriving (Eq, Show)

type KindSyntax = Node KindF

data KindF = TypeKindSyntax | KindVariable TypeVarId | KindArrow KindSyntax KindSyntax | KindHole HoleId deriving (Eq, Show)

type Predicate = Node (GlobalId, TypeSyntax)

type Scheme = Node ([TypeBinder], [TypeBinder], TypeSyntax)

data WherePlan = AtInitialization | AfterValueParameters Int deriving (Eq, Show)

data ScopeMode = Recursive | Sequential deriving (Eq, Show)

data BindingGroup = BindingGroup {scopeMode :: ScopeMode, declarations :: [Declaration]} deriving (Eq, Show)

type Clause = Node ClauseF

data ClauseF = Clause {clauseTypes :: [TypeBinder], clausePatterns :: [Pattern], clauseBody :: Expr, clauseWhere :: BindingGroup, clauseWherePlan :: WherePlan} deriving (Eq, Show)

data ValueBody = ClausesBody Int (NonEmpty Clause) | BuiltinBody Text deriving (Eq, Show)

type Declaration = Node DeclarationF

data DeclarationF
  = ValueDefinition Reference (Maybe Scheme) ValueBody
  | PatternDefinition Pattern Expr
  | AliasDefinition GlobalId [TypeBinder] (Maybe KindSyntax) TypeSyntax
  | DataDefinition GlobalId [TypeBinder] (Maybe KindSyntax) [Node (GlobalId, [TypeSyntax])]
  | RecordDefinition GlobalId [TypeBinder] (Maybe KindSyntax) GlobalId [Node (Text, TypeSyntax)] [TypeBinder]
  | OpaqueBuiltinType GlobalId Text KindSyntax
  | TraitDefinition GlobalId TypeBinder [Predicate] [Declaration]
  | MethodDefinition GlobalId Scheme
  | ImplementationDefinition ImplementationId [TypeBinder] [Predicate] Predicate [Declaration]
  deriving (Eq, Show)

data Occurrence = Occurrence {occurrenceSpan :: Span, occurrenceSpelling :: Text, occurrenceReference :: Reference, occurrenceRoutes :: [Span]} deriving (Eq, Show)

data AbstractModule = AbstractModule
  { abstractId :: ModuleId,
    abstractSpan :: Span,
    abstractOrigin :: Provenance,
    abstractOptions :: ModuleOptions,
    implicitPrelude :: Bool,
    abstractDeclarations :: BindingGroup,
    abstractExports :: NameSummary,
    abstractEntities :: Map GlobalId Entity,
    abstractFields :: Map (GlobalId, Text) FieldDescriptor,
    visibleImplementations :: [ImplementationId],
    abstractOccurrences :: [Occurrence],
    builtinAssociations :: Map Text GlobalId,
    builtinMemberAssociations :: Map Text FieldDescriptor
  }
  deriving (Eq, Show)

-- Named witnesses are scoped over the value patterns and their continuation.
patternTypeBinders :: Pattern -> [TypeBinder]
patternTypeBinders source = case nodeValue source of
  OpenPattern witnesses body -> map snd witnesses ++ patternTypeBinders body
  ConstructorPattern _ ps -> concatMap patternTypeBinders ps
  ProductPattern ps -> concatMap patternTypeBinders ps
  ListPattern ps -> concatMap patternTypeBinders ps
  AnnotatedPattern p _ -> patternTypeBinders p
  NegatedPattern p -> patternTypeBinders p
  _ -> []
