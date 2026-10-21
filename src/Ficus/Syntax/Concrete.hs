-- | A raw, source-oriented syntax with separate syntactic categories, following
-- the approach of Agda.Syntax.Concrete. Nothing here resolves names or desugars.
module Ficus.Syntax.Concrete
  ( module Ficus.Util.Source,
    module Ficus.Syntax.Token,
    Located (..),
    at,
    Delimiter (..),
    Block (..),
    Name (..),
    NameSpace (..),
    NameNotation (..),
    Literal (..),
    Expr,
    ExprF (..),
    Pattern,
    PatternF (..),
    PatternField,
    PatternFieldF (..),
    TypeExpr,
    TypeF (..),
    KindExpr,
    KindF (..),
    Declaration,
    DeclarationF (..),
    TypeBody (..),
    TypeParameter,
    TypeParameterF (..),
    TypeBinder,
    TypeBinderF (..),
    TypeArgument,
    TypeArgumentF (..),
    Quantifier,
    QuantifierF (..),
    SignatureType,
    SignatureTypeF (..),
    Constraint,
    ConstraintF (..),
    WhereClause,
    WhereClauseF (..),
    Field,
    FieldF (..),
    Constructor,
    ConstructorF (..),
    FieldSignature,
    FieldSignatureF (..),
    IfClause,
    IfClauseF (..),
    MatchClause,
    MatchClauseF (..),
    BlockItem,
    BlockItemF (..),
    DoStatement,
    DoStatementF (..),
    Pragma,
    PragmaF (..),
    PragmaArgument (..),
    Import,
    ImportF (..),
    ImportMode (..),
    ImportItem,
    ImportItemF (..),
    MemberSelection (..),
    ConcreteModule (..),
    validateConcrete,
    renderSource,
  )
where

import Data.Text (Text)
import Ficus.Syntax.Token
import Ficus.Util.Source

data Located a = Located
  {location :: Span, origin :: Provenance, concrete :: a}
  deriving (Eq, Show)

at :: Span -> a -> Located a
at s = Located s (SourceOrigin s)

data Delimiter = Explicit | Layout deriving (Eq, Show)

data Block a = Block
  { blockLocation :: Span,
    blockOrigin :: Provenance,
    blockDelimiter :: Delimiter,
    blockItems :: [a]
  }
  deriving (Eq, Show)

data NameSpace = LowerName | UpperName deriving (Eq, Show)

data NameNotation = Alphabetic | ParenthesizedOperator | BareOperator deriving (Eq, Show)

data Name = Name
  { nameLocation :: Span,
    nameOrigin :: Provenance,
    nameText :: Text,
    nameSpace :: NameSpace,
    nameNotation :: NameNotation
  }
  deriving (Eq, Show)

-- Keep the exact literal token, including escapes/interpolation, for faithful
-- rendering and later literal elaboration. No primitive/constructor semantics.
data Literal = IntegerLiteral Text | FloatLiteral Text | CharLiteral Text | StringLiteralText Text
  deriving (Eq, Show)

type Expr = Located ExprF

data ExprF
  = Ident Name
  | Lit Literal
  | App Expr Expr
  | StaticApp Expr [TypeArgument]
  | OpApp Expr Name Expr
  | Negate Expr
  | Lam [TypeBinder] [Pattern] Expr
  | If (Block IfClause)
  | With Expr (Block MatchClause)
  | Do (Block DoStatement)
  | ExprBlock (Block BlockItem)
  | RecordWith Expr (Block Field)
  | Dotted Expr [Name]
  | Paren Expr
  | Annotated Expr TypeExpr
  | Unit
  | Product [Expr]
  | List [Expr]
  deriving (Eq, Show)

type Pattern = Located PatternF

data PatternF
  = IdentP Name
  | LitP Literal
  | NegateP Pattern
  | ConstructorP Pattern [Pattern]
  | RecordP Pattern (Block PatternField)
  | OpAppP Pattern Name Pattern
  | ParenP Pattern
  | AnnotatedP Pattern TypeExpr
  | UnitP
  | ProductP [Pattern]
  | ListP [Pattern]
  | DottedP [Name]
  deriving (Eq, Show)

type PatternField = Located PatternFieldF

data PatternFieldF = PatternField Name Pattern deriving (Eq, Show)

type TypeExpr = Located TypeF

data TypeF
  = IdentT Name
  | DottedT [Name]
  | AppT TypeExpr TypeExpr
  | OpAppT TypeExpr Name TypeExpr
  | ArrowT TypeExpr TypeExpr
  | ProductT TypeExpr TypeExpr
  | ConstrainedT [Constraint] TypeExpr
  | ParenT TypeExpr
  | ListT TypeExpr
  | ListConstructor
  | ProductConstructor
  | FunctionConstructor
  deriving (Eq, Show)

type KindExpr = Located KindF

data KindF = IdentK Name | DottedK [Name] | ArrowK KindExpr KindExpr | ParenK KindExpr
  deriving (Eq, Show)

type TypeParameter = Located TypeParameterF

data TypeParameterF = TypeParameter Name (Maybe KindExpr) deriving (Eq, Show)

type TypeBinder = Located TypeBinderF

data TypeBinderF = TypeBinder Name (Maybe KindExpr) deriving (Eq, Show)

type TypeArgument = Located TypeArgumentF

data TypeArgumentF = TypeArgument TypeExpr deriving (Eq, Show)

type Quantifier = Located QuantifierF

data QuantifierF = Quantifier Name (Maybe KindExpr) deriving (Eq, Show)

type SignatureType = Located SignatureTypeF

data SignatureTypeF = SignatureType [Quantifier] TypeExpr deriving (Eq, Show)

type Constraint = Located ConstraintF

data ConstraintF = Constraint Name TypeExpr deriving (Eq, Show)

type Declaration = Located DeclarationF

data DeclarationF
  = TypeSignature Name SignatureType
  | KindSignature Name KindExpr
  | FunctionClause Name [TypeBinder] [Pattern] Expr (Maybe WhereClause)
  | PatternBinding Pattern Expr (Maybe WhereClause)
  | TypeAlias Name [TypeParameter] TypeExpr
  | DataDeclaration Name [TypeParameter] TypeBody
  | TraitDeclaration [Constraint] Name TypeParameter (Block Declaration)
  | Implementation [Constraint] Constraint (Block Declaration)
  | PragmaDeclaration Pragma
  deriving (Eq, Show)

data TypeBody = Constructors (Block Constructor) | Fields (Block FieldSignature)
  deriving (Eq, Show)

type Constructor = Located ConstructorF

data ConstructorF = Constructor Name [TypeExpr] deriving (Eq, Show)

type FieldSignature = Located FieldSignatureF

data FieldSignatureF = FieldSignature Name TypeExpr deriving (Eq, Show)

type WhereClause = Located WhereClauseF

data WhereClauseF = WhereClause (Block Declaration) deriving (Eq, Show)

type Field = Located FieldF

data FieldF = Field Name Expr (Maybe WhereClause) deriving (Eq, Show)

type IfClause = Located IfClauseF

data IfClauseF = IfClause Expr Expr deriving (Eq, Show)

type MatchClause = Located MatchClauseF

data MatchClauseF = MatchClause Pattern (Maybe Expr) Expr deriving (Eq, Show)

type BlockItem = Located BlockItemF

data BlockItemF = LocalDeclaration Declaration | Expression Expr deriving (Eq, Show)

type DoStatement = Located DoStatementF

data DoStatementF = PatternBind Pattern Expr | DoDeclaration Declaration | DoExpression Expr
  deriving (Eq, Show)

type Pragma = Located PragmaF

data PragmaF = Pragma Name [Located PragmaArgument] deriving (Eq, Show)

data PragmaArgument = IdentifierArgument Name | StringArgument Text deriving (Eq, Show)

type Import = Located ImportF

data ImportF = Import [Name] ImportMode deriving (Eq, Show)

data ImportMode = ModuleOnly | Aliased Name | Selected [ImportItem] Bool | AllMembers Bool
  deriving (Eq, Show)

type ImportItem = Located ImportItemF

data ImportItemF = ImportItem Name (Maybe MemberSelection) deriving (Eq, Show)

data MemberSelection = AllConstructors | SelectedConstructors [Name] deriving (Eq, Show)

data ConcreteModule = ConcreteModule
  { moduleLocation :: Span,
    moduleOrigin :: Provenance,
    modulePragmas :: [Pragma],
    moduleImports :: [Import],
    moduleDeclarations :: [Declaration],
    moduleTokens :: [Token],
    moduleComments :: [Comment],
    moduleSource :: Text
  }
  deriving (Eq, Show)

-- Lossless source rendering, not a canonical formatter.
renderSource :: ConcreteModule -> Text
renderSource = moduleSource

-- The source token stream is the parser/Concrete boundary's source map. All
-- typed syntax carries an origin; recursive validation is defined below.
validateConcrete :: ConcreteModule -> Either Text ()
validateConcrete m = do
  check (moduleLocation m) (moduleOrigin m)
  mapM_ (\t -> checkWithin (moduleLocation m) (tokenSpan t)) (moduleTokens m)
  mapM_ (\c -> checkWithin (moduleLocation m) (commentSpan c)) (moduleComments m)
  mapM_ pragma (modulePragmas m)
  mapM_ importNode (moduleImports m)
  mapM_ decl (moduleDeclarations m)
  where
    check s o
      | start s > end s = Left "reversed span"
      | o /= SourceOrigin s = Left "invalid source provenance"
      | otherwise = Right ()
    checkWithin p s
      | sourceFile p /= sourceFile s || start s < start p || end s > end p = Left "span outside module"
      | otherwise = Right ()
    node :: (a -> Either Text ()) -> Located a -> Either Text ()
    node f n = check (location n) (origin n) *> checkWithin (moduleLocation m) (location n) *> f (concrete n)
    name n = check (nameLocation n) (nameOrigin n) *> checkWithin (moduleLocation m) (nameLocation n)
    block :: (a -> Either Text ()) -> Block a -> Either Text ()
    block f b = check (blockLocation b) (blockOrigin b) *> mapM_ f (blockItems b)
    optional :: (a -> Either Text ()) -> Maybe a -> Either Text ()
    optional f = maybe (Right ()) f
    pragma = node (\(Pragma n args) -> name n *> mapM_ (node (\case IdentifierArgument x -> name x; StringArgument _ -> Right ())) args)
    importNode =
      node
        ( \(Import ns mode) ->
            mapM_ name ns *> case mode of
              ModuleOnly -> Right ()
              Aliased n -> name n
              AllMembers _ -> Right ()
              Selected is _ -> mapM_ (node (\(ImportItem n sel) -> name n *> optional (\case AllConstructors -> Right (); SelectedConstructors xs -> mapM_ name xs) sel)) is
        )
    parameter = node (\(TypeParameter n k) -> name n *> optional kindExpr k)
    binder = node (\(TypeBinder n k) -> name n *> optional kindExpr k)
    argument = node (\(TypeArgument t) -> typeExpr t)
    quantifier = node (\(Quantifier n k) -> name n *> optional kindExpr k)
    constraint = node (\(Constraint n t) -> name n *> typeExpr t)
    signature = node (\(SignatureType qs t) -> mapM_ quantifier qs *> typeExpr t)
    whereNode = node (\(WhereClause b) -> block decl b)
    decl = node $ \case
      TypeSignature n t -> name n *> signature t
      KindSignature n k -> name n *> kindExpr k
      FunctionClause n bs ps e w -> name n *> mapM_ binder bs *> mapM_ pat ps *> expr e *> optional whereNode w
      PatternBinding p e w -> pat p *> expr e *> optional whereNode w
      TypeAlias n ps t -> name n *> mapM_ parameter ps *> typeExpr t
      DataDeclaration n ps body ->
        name n *> mapM_ parameter ps *> case body of
          Constructors b -> block (node (\(Constructor c ts) -> name c *> mapM_ typeExpr ts)) b
          Fields b -> block (node (\(FieldSignature f t) -> name f *> typeExpr t)) b
      TraitDeclaration cs n p b -> mapM_ constraint cs *> name n *> parameter p *> block decl b
      Implementation cs c b -> mapM_ constraint cs *> constraint c *> block decl b
      PragmaDeclaration p -> pragma p
    expr = node $ \case
      Ident n -> name n
      Lit _ -> Right ()
      App f x -> expr f *> expr x
      StaticApp f ts -> expr f *> mapM_ argument ts
      OpApp a op b -> expr a *> name op *> expr b
      Negate e -> expr e
      Lam bs ps e -> mapM_ binder bs *> mapM_ pat ps *> expr e
      If b -> block (node (\(IfClause c e) -> expr c *> expr e)) b
      With e b -> expr e *> block (node (\(MatchClause p g r) -> pat p *> optional expr g *> expr r)) b
      Do b -> block (node (\case PatternBind p e -> pat p *> expr e; DoDeclaration d -> decl d; DoExpression e -> expr e)) b
      ExprBlock b -> block (node (\case LocalDeclaration d -> decl d; Expression e -> expr e)) b
      RecordWith e b -> expr e *> block (node (\(Field n r w) -> name n *> expr r *> optional whereNode w)) b
      Dotted e ns -> expr e *> mapM_ name ns
      Paren e -> expr e
      Annotated e t -> expr e *> typeExpr t
      Unit -> Right ()
      Product es -> mapM_ expr es
      List es -> mapM_ expr es
    pat = node $ \case
      IdentP n -> name n
      LitP _ -> Right ()
      NegateP p -> pat p
      ConstructorP p ps -> pat p *> mapM_ pat ps
      RecordP p fields -> do
        pat p
        if blockDelimiter fields /= Explicit
          then Left "record patterns require explicit braces"
          else block (node (\(PatternField n q) -> name n *> pat q)) fields
      OpAppP a op b -> pat a *> name op *> pat b
      ParenP p -> pat p
      AnnotatedP p t -> pat p *> typeExpr t
      UnitP -> Right ()
      ProductP ps -> mapM_ pat ps
      ListP ps -> mapM_ pat ps
      DottedP ns -> mapM_ name ns
    typeExpr = node $ \case
      IdentT n -> name n
      DottedT ns -> mapM_ name ns
      AppT a b -> typeExpr a *> typeExpr b
      OpAppT a op b -> typeExpr a *> name op *> typeExpr b
      ArrowT a b -> typeExpr a *> typeExpr b
      ProductT a b -> typeExpr a *> typeExpr b
      ConstrainedT cs t -> mapM_ constraint cs *> typeExpr t
      ParenT t -> typeExpr t
      ListT t -> typeExpr t
      ListConstructor -> Right ()
      ProductConstructor -> Right ()
      FunctionConstructor -> Right ()
    kindExpr = node $ \case
      IdentK n -> name n
      DottedK ns -> mapM_ name ns
      ArrowK a b -> kindExpr a *> kindExpr b
      ParenK k -> kindExpr k
