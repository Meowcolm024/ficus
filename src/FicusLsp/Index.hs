-- | Read-only editor indexes over ordinary compiler results. No protocol data
-- is inserted into source, inference, Core, or checked interfaces.
module FicusLsp.Index where

import Data.List (find, mapAccumL, nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
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
    interpolationLocations =
      Map.fromList
        [ (Token.tokenSpan token, interpolationNames source token)
        | (file, values) <- Map.toList tokens,
          let source = Map.findWithDefault "" file (Compile.compileSources result),
          token <- values,
          Token.tokenKind token == Token.StringLiteral,
          hasStringInterpolation (Token.tokenText token)
        ]
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
    moduleSymbols tree = declaredGlobals ++ declaredValueClauses ++ declaredLocals ++ uses ++ fieldDeclarations ++ projections ++ typedExpressions
      where
        own = A.abstractId tree
        core = validatedModule . E.checkedCore <$> Map.lookup own (Compile.compileModules result)
        bindings = maybe [] (concatMap (concatMap coreBindings . C.groupBindings) . C.coreBindings) core
        localTypes = Map.fromList [(C.bindingReference (C.nodeValue binding), sourceScheme binding) | binding <- bindings]
        expressions = maybe [] (concatMap (concatMap (allExpressions . C.bindingBody . C.nodeValue) . C.groupBindings) . C.coreBindings) core
        expressionTypes = Map.fromListWith (\_ first -> first) [(C.nodeSpan expression, C.typeOf expression) | expression <- expressions]
        referenceTypes = Map.fromListWith (\_ first -> first) [(reference, C.typeOf expression) | expression <- expressions, C.Var reference _ <- [C.formOf expression]]
        sourceDefinitions = declarations tokens (A.abstractDeclarations tree)
        localDefinitions = Map.fromListWith (\_ first -> first) [(reference, (name, precise name location, role)) | (reference, name, location, role) <- sourceDefinitions]
        declaredGlobals =
          [ Symbol location (globalName ident) (globalType ident) (Just location) (Just (roleClass (A.entityRole entity) (globalType ident))) True
          | (ident@(GlobalId owner _ _), entity) <- Map.toList (A.abstractEntities tree),
            owner == own,
            A.entityRole entity /= RecordConstructorRole,
            Just location <- [definition ident]
          ]
        -- The entity's canonical location may be its signature. Clause names
        -- still need their own index entries with the same type and role.
        declaredValueClauses =
          [ Symbol location name (globalType ident) (definition ident) (Just (globalClass ident)) True
          | (GlobalRef ident, name, location, _) <- sourceDefinitions,
            definition ident /= Just location
          ]
        declaredLocals =
          [ Symbol location name (localType reference location) (Just location) (Just role) True
          | (reference@(LocalRef _), (name, location, role)) <- Map.toList localDefinitions
          ]
        localType reference location = case Map.lookup reference localTypes of
          Just scheme -> Just (renderScheme scheme)
          Nothing ->
            renderType <$> case Map.lookup reference referenceTypes of
              Just ty -> Just ty
              Nothing -> Map.lookup location expressionTypes
        -- Match generated references to source interpolation segments in order.
        -- Repeated terminal names can refer to different qualified bindings.
        locatedUses = mapMaybe id (snd (mapAccumL locateUse interpolationLocations (A.abstractOccurrences tree)))
        locateUse remaining occurrence =
          let original = A.occurrenceSpan occurrence
           in case Map.lookup original remaining of
                Nothing -> (remaining, Just (occurrence, original))
                Just ((name, location) : rest)
                  | name == A.occurrenceSpelling occurrence -> (Map.insert original rest remaining, Just (occurrence, location))
                Just _ -> (remaining, Nothing)
        uses =
          [ let reference = A.occurrenceReference occurrence
                original = A.occurrenceSpan occurrence
                (ty, target, role) = case reference of
                  GlobalRef ident -> (globalType ident, definition ident, globalClass ident)
                  LocalRef _ -> (localType reference original, (\(_, span', _) -> span') <$> Map.lookup reference localDefinitions, maybe Variable (\(_, _, kind) -> kind) (Map.lookup reference localDefinitions))
             in Symbol location (A.occurrenceSpelling occurrence) ty target (Just role) False
          | (occurrence, location) <- locatedUses
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
      A.ValueDefinition reference _ body -> case body of
        A.BuiltinBody _ -> named reference (A.nodeSpan source)
        A.ClausesBody _ clauses -> concatMap (\clause -> let value = A.nodeValue clause in named reference (A.nodeSpan clause) ++ concatMap patternBinders (A.clausePatterns value) ++ declarations tokens (A.clauseWhere value) ++ expression (A.clauseBody value)) clauses
      A.PatternDefinition pattern' body -> patternBinders pattern' ++ expression body
      A.TraitDefinition _ _ _ members -> concatMap declaration members
      A.ImplementationDefinition _ _ _ _ members -> concatMap declaration members
      _ -> []
    named reference location = case [token | token <- Map.findWithDefault [] (sourceFile location) tokens, within location (Token.tokenSpan token), Token.tokenKind token `elem` [Token.Lower, Token.Symbol]] of
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
  Right (tokens, comments) -> sortOn (offset . start . first) (mapMaybe (classify (recordFieldLabels tokens)) tokens ++ [(commentSpan comment, Comment, False) | comment <- comments])
  where
    first (location, _, _) = location
    -- Interpolation references inherit the complete literal's source span.
    -- Let the lexical grammar color its escapes, braces, and embedded names;
    -- a semantic token for the whole literal would override those scopes.
    classify _ token
      | Token.tokenKind token == Token.StringLiteral,
        hasStringInterpolation (Token.tokenText token) =
          Nothing
    classify labels token =
      let matching = sortOn (\symbol -> (not (symbolDeclared symbol), offset (end (symbolSpan symbol)) - offset (start (symbolSpan symbol)))) [symbol | symbol <- symbols, Just _ <- [symbolClass symbol], within (symbolSpan symbol) (Token.tokenSpan token)]
          lexical = case Token.tokenKind token of
            -- The lexer treats import soft keywords as ordinary identifiers.
            -- Without a resolved symbol, keep the editor's contextual scope.
            Token.Lower
              | Token.tokenSpan token `Set.member` labels -> Just Property
              | Token.tokenText token `elem` ["as", "pub"] -> Nothing
              | otherwise -> Just Variable
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

-- Explicit named record blocks share field-label syntax in constructions,
-- updates and patterns. Track braces so nested expression blocks retain their
-- ordinary binding scopes, including when semantic checking is incomplete.
recordFieldLabels :: [Token.Token] -> Set.Set Span
recordFieldLabels = Set.fromList . scan []
  where
    scan scopes (receiver : intro : open : rest)
      | (Token.tokenKind receiver `elem` [Token.Upper, Token.Lower] || Token.tokenText receiver == ")"),
        Token.tokenText intro == "with",
        Token.tokenText open == "{" =
          scan (True : scopes) rest
    scan scopes (token : rest)
      | Token.tokenText token == "{" = scan (False : scopes) rest
      | Token.tokenText token == "}" = scan (drop 1 scopes) rest
    scan scopes@(True : _) (label : equals : rest)
      | Token.tokenKind label == Token.Lower,
        Token.tokenText equals == "=" =
          Token.tokenSpan label : scan scopes (equals : rest)
    scan scopes (_ : rest) = scan scopes rest
    scan _ [] = []

-- The lexer has already validated the literal. Consume escape pairs before
-- looking for an interpolation opener, including escaped backslashes.
hasStringInterpolation :: Text -> Bool
hasStringInterpolation = scan . T.unpack
  where
    scan ('\\' : _ : rest) = scan rest
    scan ('{' : '{' : rest) = scan rest
    scan ('{' : _) = True
    scan (_ : rest) = scan rest
    scan [] = False

-- Only editor ranges are refined; compiler nodes retain their origin's span.
-- The lexer has validated names and braces, so this scan only recovers offsets.
interpolationNames :: Text -> Token.Token -> [(Text, Span)]
interpolationNames source token = scan 0 (T.unpack (Token.tokenText token))
  where
    original = Token.tokenSpan token
    positionAt relative = end (sourceEndSpan (sourceFile original) (T.take (offset (start original) + relative) source))
    scan index ('\\' : _ : rest) = scan (index + 2) rest
    scan index ('{' : '{' : rest) = scan (index + 2) rest
    scan index ('}' : '}' : rest) = scan (index + 2) rest
    scan index ('{' : rest) =
      let (characters, closing) = break (== '}') rest
          spelling = T.pack characters
          (prefix, name) = T.breakOnEnd "." spelling
          first = index + 1 + T.length prefix
          location = Span (sourceFile original) (positionAt first) (positionAt (first + T.length name - 1))
       in (name, location) : scan (index + length characters + 2) (drop 1 closing)
    scan index (_ : rest) = scan (index + 1) rest
    scan _ [] = []
