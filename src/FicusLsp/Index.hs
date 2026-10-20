-- | Read-only editor indexes over ordinary compiler results. No protocol data
-- is inserted into source, inference, Core, or checked interfaces.
module FicusLsp.Index where

import Data.List (find, nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile qualified as Compile
import Ficus.Elaborate qualified as E
import Ficus.Resolve (frontendModules)
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Intrinsic (constructorSignature)
import Ficus.Syntax.Core.Validate (validatedModule)
import Ficus.Syntax.Name
import Ficus.Syntax.Parser.Lexer (lexSource)
import Ficus.Syntax.Token qualified as Token
import Ficus.Type qualified as Ty
import Ficus.Util.Source hiding (Comment)

data TokenClass = Namespace | TypeName | TypeParameter | Parameter | Variable | Function | Property | Constructor | Trait | Keyword | Operator | Number | String | Comment | Pragma
  deriving (Eq, Ord, Show, Enum, Bounded)

data Symbol = Symbol
  { symbolSpan :: Span,
    symbolName :: Text,
    symbolType :: Maybe Text,
    symbolDefinition :: Maybe Span,
    symbolClass :: Maybe TokenClass,
    symbolDeclared :: Bool
  }
  deriving (Eq, Show)

type Index = Map FilePath [Symbol]

buildIndex :: Compile.CompileResult -> Index
buildIndex result = Map.fromListWith (++) [(sourceFile (symbolSpan symbol), [symbol]) | symbol <- concatMap moduleSymbols modules]
  where
    modules = Map.elems (frontendModules (Compile.compileFrontend result))
    cores = map (validatedModule . E.checkedCore) (Map.elems (Compile.compileModules result))
    publicTypes = Map.unions (map E.checkedTypes (Map.elems (Compile.compileModules result)))
    entities = Map.unions (map A.abstractEntities modules)
    kinds = Map.unions (map C.coreKinds cores)
    constructors = Map.unions [Map.fromList [(GlobalRef ident, C.constructorScheme (C.nodeValue descriptor)) | (C.DataConstructor ident, descriptor) <- Map.toList (C.coreConstructors core)] | core <- cores]
    tokens = Map.mapWithKey (\file text -> either (const []) fst (lexSource file text)) (Compile.compileSources result)
    precise name location = case find (\token -> Token.tokenText token == name && within location (Token.tokenSpan token)) (Map.findWithDefault [] (sourceFile location) tokens) of
      Just token -> Token.tokenSpan token
      Nothing -> location
    globalType ident = case Map.lookup (GlobalRef ident) (publicTypes `Map.union` constructors) of
      Just scheme -> Just (renderScheme scheme)
      Nothing -> case constructorSignature (C.DataConstructor ident) of
        Just (scheme, _) -> Just (renderScheme scheme)
        Nothing -> renderKind ident <$> case ident of IntrinsicId intrinsic -> Just (Ty.primitiveKind intrinsic); _ -> Map.lookup ident kinds
    globalRole ident = case Map.lookup ident entities of
      Just entity -> A.entityRole entity
      Nothing -> case [role | (_, _, actual, role) <- primitiveNames, actual == ident] of role : _ -> role; [] -> ValueRole
    globalClass ident = roleClass (globalRole ident) (globalType ident)
    renderKind ident kind = case (globalRole ident, kind) of
      (TraitRole, Ty.KindArrow input _) -> (case input of Ty.TypeKind -> "Type"; _ -> "(" <> Ty.renderKind input <> ")") <> " -> Constraint"
      _ -> Ty.renderKind kind
    definition ident = do
      entity <- Map.lookup ident entities
      let location = precise (globalName ident) (A.entitySpan entity)
      if Map.member (sourceFile location) (Compile.compileSources result) then Just location else Nothing
    moduleSymbols tree = declaredGlobals ++ declaredLocals ++ uses ++ fieldDeclarations ++ projections ++ typedExpressions
      where
        own = A.abstractId tree
        core = validatedModule . E.checkedCore <$> Map.lookup own (Compile.compileModules result)
        bindings = maybe [] (concatMap (concatMap coreBindings . C.groupBindings) . C.coreBindings) core
        localTypes = Map.fromList [(C.bindingReference (C.nodeValue binding), sourceScheme binding) | binding <- bindings]
        expressions = maybe [] (concatMap (concatMap (allExpressions . C.bindingBody . C.nodeValue) . C.groupBindings) . C.coreBindings) core
        expressionTypes = Map.fromListWith (\_ first -> first) [(C.nodeSpan expression, C.typeOf expression) | expression <- expressions]
        localDefinitions = Map.fromList [(reference, (name, precise name location, role)) | (reference, name, location, role) <- declarations tokens (A.abstractDeclarations tree)]
        declaredGlobals =
          [ Symbol location (globalName ident) (globalType ident) (Just location) (Just (roleClass (A.entityRole entity) (globalType ident))) True
          | (ident@(GlobalId owner _ _), entity) <- Map.toList (A.abstractEntities tree),
            owner == own,
            A.entityRole entity /= RecordConstructorRole,
            Just location <- [definition ident]
          ]
        declaredLocals =
          [ Symbol location name (localType reference location) (Just location) (Just role) True
          | (reference@(LocalRef _), (name, location, role)) <- Map.toList localDefinitions
          ]
        localType reference location = case Map.lookup reference localTypes of
          Just scheme -> Just (renderScheme scheme)
          Nothing -> renderType <$> Map.lookup location expressionTypes
        uses =
          [ let reference = A.occurrenceReference occurrence
                location = A.occurrenceSpan occurrence
                (ty, target, role) = case reference of
                  GlobalRef ident -> (globalType ident, definition ident, globalClass ident)
                  LocalRef _ -> (localType reference location, (\(_, span', _) -> span') <$> Map.lookup reference localDefinitions, maybe Variable (\(_, _, kind) -> kind) (Map.lookup reference localDefinitions))
             in Symbol location (A.occurrenceSpelling occurrence) ty target (Just role) False
          | occurrence <- A.abstractOccurrences tree
          ]
        recordTable = maybe Map.empty C.coreRecords core
        fieldDeclarations =
          [ let location = precise name (C.nodeSpan field)
                fieldScheme = case Ty.functionParts (Ty.schemeType scheme) of Just (_, ty) -> scheme {Ty.schemeType = ty}; Nothing -> scheme
             in Symbol location name (Just (renderScheme fieldScheme)) (Just location) (Just Property) True
          | record <- Map.elems recordTable,
            field <- C.recordFields (C.nodeValue record),
            sourceFile (C.nodeSpan field) == sourceFile (A.abstractSpan tree),
            let (name, scheme) = C.nodeValue field
          ]
        projections =
          [ let target = precise name (C.nodeSpan field)
             in Symbol (Token.tokenSpan token) name (Just (renderType (C.typeOf expression))) (Just target) (Just Property) False
          | expression <- expressions,
            SourceOrigin _ <- [C.nodeOrigin expression],
            C.SelectField _ (C.FieldId owner slot) <- [C.formOf expression],
            Just record <- [Map.lookup owner recordTable],
            field : _ <- [drop slot (C.recordFields (C.nodeValue record))],
            let (name, _) = C.nodeValue field,
            token : _ <- [reverse [value | value <- Map.findWithDefault [] (sourceFile (C.nodeSpan expression)) tokens, Token.tokenText value == name, within (C.nodeSpan expression) (Token.tokenSpan value)]]
          ]
        typedExpressions =
          [ let location = C.nodeSpan expression
                text = Map.findWithDefault "" (sourceFile location) (Compile.compileSources result)
                spelling = T.take (offset (end location) - offset (start location) + 1) (T.drop (offset (start location)) text)
             in Symbol location spelling (Just (renderType (C.typeOf expression))) Nothing Nothing False
          | expression <- expressions,
            SourceOrigin _ <- [C.nodeOrigin expression]
          ]

globalName :: GlobalId -> Text
globalName = Ty.renderConstructor

roleClass :: Role -> Maybe Text -> TokenClass
roleClass role ty = case role of
  ValueRole -> if maybe False (T.isInfixOf " -> ") ty then Function else Variable
  MethodRole -> Function
  AliasRole -> TypeName
  DataRole -> TypeName
  RecordRole -> TypeName
  RecordConstructorRole -> Constructor
  ConstructorRole -> Constructor
  TraitRole -> Trait
  KindRole -> TypeName

within :: Span -> Span -> Bool
within outer inner = sourceFile outer == sourceFile inner && offset (start outer) <= offset (start inner) && offset (end inner) <= offset (end outer)

allExpressions :: C.Expr ty -> [C.Expr ty]
allExpressions expression = expression : concatMap allExpressions (C.children expression)

coreBindings :: C.Binding ty -> [C.Binding ty]
coreBindings binding = binding : concatMap nested (allExpressions (C.bindingBody (C.nodeValue binding)))
  where
    nested expression = case C.formOf expression of
      C.Let value _ -> [value]
      C.LetRec values _ -> foldr (:) [] values
      _ -> []

-- Recover qualified source schemes from local Core bindings. Evidence arrows
-- describe calling convention, not the type the editor should display.
sourceScheme :: C.Binding C.CoreType -> Ty.Scheme C.CoreType
sourceScheme binding = remove (C.bindingBody value) (C.bindingScheme value)
  where
    value = C.nodeValue binding
    remove expression scheme = case C.formOf expression of
      C.ScopeTypes _ body -> remove body scheme
      C.Lambda binder body
        | (_, _, C.EvidenceBinder, _) <- C.nodeValue binder,
          Just (Ty.Application (Ty.Constructor trait _) argument, rest) <- Ty.functionParts (Ty.schemeType scheme) ->
            remove body (scheme {Ty.schemeType = rest, Ty.schemePredicates = Ty.schemePredicates scheme ++ [Ty.Predicate trait argument]})
      _ -> scheme

renderScheme :: Ty.Scheme C.CoreType -> Text
renderScheme scheme = explicit <> constraints <> Ty.renderType variable (Ty.schemeType scheme)
  where
    variables = nub (map Ty.quantifierId (Ty.quantifiers scheme) ++ [ident | C.BoundVariable ident <- foldr (:) [] (Ty.schemeType scheme)])
    names = Map.fromList (zip variables (map variableName [0 ..]))
    variable (C.BoundVariable ident) = Map.findWithDefault (Ty.renderBound ident) ident names
    variable (C.DiagnosticVariable _) = "_"
    explicit = T.concat ["{" <> variable (C.BoundVariable (Ty.quantifierId q)) <> "} -> " | q <- Ty.explicitQuantifiers scheme]
    predicates = [Ty.renderConstructor (Ty.predicateTrait predicate) <> " " <> Ty.renderType variable (Ty.predicateArgument predicate) | predicate <- Ty.schemePredicates scheme]
    constraints = case predicates of [] -> ""; [predicate] -> predicate <> " => "; _ -> "(" <> T.intercalate ", " predicates <> ") => "

renderType :: C.CoreType -> Text
renderType ty = Ty.renderType (\variable -> Map.findWithDefault "_" variable names) ty
  where
    names = Map.fromList (zip (foldr (:) [] (Ty.freeVariables ty)) (map variableName [0 ..]))

variableName :: Int -> Text
variableName index = if index < 26 then T.singleton (toEnum (fromEnum 'a' + index)) else "a" <> T.pack (show index)

-- Local identities are scoped to a module. Source binders supply definition
-- locations, while Core supplies types after inference and generalization.
declarations :: Map FilePath [Token.Token] -> A.BindingGroup -> [(Reference, Text, Span, TokenClass)]
declarations tokens group = concatMap declaration (A.declarations group)
  where
    declaration source = case A.nodeValue source of
      A.ValueDefinition reference _ body ->
        named reference source ++ case body of
          A.BuiltinBody _ -> []
          A.ClausesBody _ clauses -> concatMap (\clause -> let value = A.nodeValue clause in concatMap patternBinders (A.clausePatterns value) ++ declarations tokens (A.clauseWhere value) ++ expression (A.clauseBody value)) clauses
      A.PatternDefinition pattern' body -> patternBinders pattern' ++ expression body
      A.TraitDefinition _ _ _ members -> concatMap declaration members
      A.ImplementationDefinition _ _ _ _ members -> concatMap declaration members
      _ -> []
    named reference source = case [token | token <- Map.findWithDefault [] (sourceFile (A.nodeSpan source)) tokens, within (A.nodeSpan source) (Token.tokenSpan token), Token.tokenKind token `elem` [Token.Lower, Token.Symbol]] of
      token : _ -> [(reference, Token.tokenText token, Token.tokenSpan token, Variable)]
      [] -> []
    binder source = let (ident, name) = A.nodeValue source in [(LocalRef ident, name, A.nodeSpan source, Parameter) | not ("$" `T.isPrefixOf` name)]
    patternBinders pattern' = case A.nodeValue pattern' of
      A.Bind value -> binder value
      A.ConstructorPattern _ patterns -> concatMap patternBinders patterns
      A.ProductPattern patterns -> concatMap patternBinders patterns
      A.ListPattern patterns -> concatMap patternBinders patterns
      A.AnnotatedPattern inner _ -> patternBinders inner
      A.NegatedPattern inner -> patternBinders inner
      _ -> []
    expression source = case A.nodeValue source of
      A.Apply a b -> expression a ++ expression b
      A.TypeApply a _ -> expression a
      A.Annotated a _ _ -> expression a
      A.Lambda parameter body -> binder parameter ++ expression body
      A.TypeLambda _ body -> expression body
      A.Match _ receiver clauses -> expression receiver ++ concatMap (\clause -> let (pattern', guard', body) = A.nodeValue clause in patternBinders pattern' ++ foldMap expression guard' ++ expression body) clauses
      A.Conditional clauses -> concatMap (\clause -> let (guard', body) = A.nodeValue clause in foldMap expression guard' ++ expression body) clauses
      A.Sequence statements body -> concatMap (\statement -> case A.nodeValue statement of A.Effect value -> expression value; A.BindStatement bindings -> declarations tokens bindings) statements ++ expression body
      A.Where _ bindings body -> declarations tokens bindings ++ expression body
      A.Project receiver _ -> expression receiver
      A.ConstructRecord _ fields -> concatMap (expression . snd . A.nodeValue) fields
      A.UpdateRecord receiver fields -> expression receiver ++ concatMap (expression . snd . A.nodeValue) fields
      A.Product values -> concatMap expression values
      A.List values -> concatMap expression values
      A.Negate value -> expression value
      _ -> []

semanticSpans :: FilePath -> Text -> [Symbol] -> [(Span, TokenClass, Bool)]
semanticSpans file source symbols = case lexSource file source of
  Left _ -> []
  Right (tokens, comments) -> sortOn (offset . start . first) (mapMaybe classify tokens ++ [(commentSpan comment, Comment, False) | comment <- comments])
  where
    first (location, _, _) = location
    classify token =
      let matching = sortOn (\symbol -> (not (symbolDeclared symbol), offset (end (symbolSpan symbol)) - offset (start (symbolSpan symbol)))) [symbol | symbol <- symbols, Just _ <- [symbolClass symbol], within (symbolSpan symbol) (Token.tokenSpan token)]
          lexical = case Token.tokenKind token of
            Token.Lower -> Just Variable
            Token.Upper -> Just (if "." `T.isPrefixOf` T.stripStart (T.drop (offset (end (Token.tokenSpan token)) + 1) source) then Namespace else TypeName)
            Token.Symbol -> Just Operator
            Token.Keyword -> Just Keyword
            Token.PragmaName -> Just Pragma
            Token.NumberLiteral -> Just Number
            Token.CharacterLiteral -> Just String
            Token.StringLiteral -> Just String
            Token.Punctuation -> Nothing
       in case matching of
            symbol : _ -> (\kind -> (Token.tokenSpan token, kind, symbolDeclared symbol)) <$> symbolClass symbol
            [] -> (\kind -> (Token.tokenSpan token, kind, False)) <$> lexical
