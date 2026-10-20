module Ficus.Infer.Declaration (Declarations (..), TraitDeclaration (..), ImplementationDeclaration (..), emptyDeclarations, prepareDeclarations) where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Error.Type qualified as E
import Ficus.Infer.Kind qualified as K
import Ficus.Infer.Monad
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Infer.Unify qualified as U
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Dependencies
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S

data TraitDeclaration = TraitDeclaration
  { traitParameter :: Quantifier,
    traitSuperclasses :: [Predicate InferType],
    traitMethods :: Map GlobalId (Scheme InferType)
  }
  deriving (Eq, Show)

data ImplementationDeclaration = ImplementationDeclaration
  { implementationParameters :: [Quantifier],
    implementationContext :: [Predicate InferType],
    implementationHead :: Predicate InferType,
    implementationMembers :: Map GlobalId A.Declaration
  }
  deriving (Eq, Show)

data Declarations = Declarations
  { builtinTypeAssociations :: Map Text GlobalId,
    declarationTypes :: TypeEnvironment,
    valueSignatures :: Map Reference Signature,
    uninhabitedTypes :: Set.Set GlobalId,
    constructorDeclarations :: Map C.ConstructorId (C.Node (C.ConstructorDescriptor InferType)),
    recordDeclarations :: Map GlobalId (C.Node (C.RecordDescriptor InferType)),
    traitDeclarations :: Map GlobalId (C.Node TraitDeclaration),
    implementationDeclarations :: Map ImplementationId (C.Node ImplementationDeclaration)
  }
  deriving (Eq, Show)

emptyDeclarations :: Declarations
emptyDeclarations = Declarations Map.empty emptyTypes Map.empty Set.empty Map.empty Map.empty Map.empty Map.empty

prepareDeclarations :: Declarations -> A.AbstractModule -> Infer Declarations
prepareDeclarations imported tree = do
  let declarations = A.declarations (A.abstractDeclarations tree)
      summary = K.inferKinds (typeKinds (declarationTypes imported)) tree
      localAliases = [(ident, d) | d <- declarations, A.AliasDefinition ident _ _ _ <- [A.nodeValue d]]
      aliasIds = Set.fromList (map fst localAliases)
      environment = (withKinds summary (declarationTypes imported)) {aliasNames = aliasNames (declarationTypes imported) `Set.union` aliasIds}
      orderedAliases = stronglyConnComp [(d, ident, Set.toList (typeDependencies (declarationDependencies d) `Set.intersection` aliasIds)) | (ident, d) <- localAliases]
  mapM_ emit (K.kindDiagnostics summary)
  preparedTypes <- foldM prepareAlias environment orderedAliases
  prepared <- foldM prepare (imported {declarationTypes = preparedTypes}) declarations
  mapM_ emit (regularityDiagnostics prepared declarations)
  mapM_ emit (superclassDiagnostics prepared)
  implementations <- foldM prepareImplementation prepared declarations
  checkOverlap implementations
  pure implementations
  where
    prepareAlias environment component = case component of
      CyclicSCC members -> do
        forM_ members $ \member -> emit (E.diagnostic E.CyclicAlias (A.nodeSpan member) "type aliases may not form a cycle")
        pure environment
      AcyclicSCC source -> case A.nodeValue source of
        A.AliasDefinition ident parameters _ body -> do
          (quantified, scope) <- bindQuantifiers environment parameters
          ty <- readType environment scope False body
          pure environment {aliases = Map.insert ident (Alias quantified ty (A.nodeSpan source)) (aliases environment)}
        _ -> pure environment
    prepare environment source = case A.nodeValue source of
      A.OpaqueBuiltinType ident key _ -> pure environment {builtinTypeAssociations = Map.insert key ident (builtinTypeAssociations environment)}
      A.ValueDefinition reference annotation _ -> case annotation of
        Nothing -> pure environment
        Just signature -> do
          checked <- readScheme (declarationTypes environment) Map.empty True signature
          pure environment {valueSignatures = Map.insert reference checked (valueSignatures environment)}
      A.DataDefinition ident parameters _ constructors -> do
        (quantified, scope) <- bindQuantifiers (declarationTypes environment) parameters
        let result = appliedType environment ident quantified
        entries <- forM constructors $ \constructor -> do
          let (name, fields) = A.nodeValue constructor
          arguments <- mapM (readTypeAt (declarationTypes environment) scope False TypeKind) fields
          let descriptor = C.ConstructorDescriptor (Scheme [] quantified [] (foldr function result arguments)) (length arguments) ident
          pure (C.DataConstructor name, coreNode constructor descriptor)
        pure environment {constructorDeclarations = Map.fromList entries `Map.union` constructorDeclarations environment, uninhabitedTypes = if null constructors then Set.insert ident (uninhabitedTypes environment) else uninhabitedTypes environment}
      A.RecordDefinition ident parameters _ constructor fields -> do
        (quantified, scope) <- bindQuantifiers (declarationTypes environment) parameters
        let result = appliedType environment ident quantified
        entries <- forM fields $ \field -> do
          let (name, sourceType) = A.nodeValue field
          ty <- readTypeAt (declarationTypes environment) scope False TypeKind sourceType
          pure (field, name, ty)
        let scheme = Scheme [] quantified [] (foldr function result [ty | (_, _, ty) <- entries])
            descriptor = C.ConstructorDescriptor scheme (length fields) ident
            record = C.RecordDescriptor (C.DataConstructor constructor) [coreNode field (name, Scheme [] quantified [] (function result ty)) | (field, name, ty) <- entries]
        pure environment {constructorDeclarations = Map.insert (C.DataConstructor constructor) (coreNode source descriptor) (constructorDeclarations environment), recordDeclarations = Map.insert ident (coreNode source record) (recordDeclarations environment)}
      A.TraitDefinition ident parameter supers members -> do
        (parameters, scope) <- bindQuantifiers (declarationTypes environment) [parameter]
        superclasses <- mapM (readPredicate (declarationTypes environment) scope False) supers
        forM_ (zip supers superclasses) $ \(predicateSource, predicate') ->
          unless (predicateArgument predicate' `elem` Map.elems scope) (emit (E.diagnostic E.InvalidTrait (A.nodeSpan predicateSource) "a supertrait must constrain the trait's own parameter"))
        checked <- forM members $ \member -> case A.nodeValue member of
          A.MethodDefinition method sourceScheme -> do
            signature <- readScheme (declarationTypes environment) scope False sourceScheme
            let ownerPredicates = [Predicate ident (Variable (Bound (quantifierId q)) (quantifierKind q)) | q <- parameters]
                scheme = signatureScheme signature
                complete = scheme {implicitQuantifiers = parameters ++ implicitQuantifiers scheme, schemePredicates = ownerPredicates ++ schemePredicates scheme}
            unless (all (\q -> Bound (quantifierId q) `Set.member` freeVariables (schemeType scheme)) parameters) (emit (E.diagnostic E.InvalidTrait (A.nodeSpan sourceScheme) "a method's value type must mention the trait parameter"))
            pure (Just (method, signature {signatureScheme = complete}))
          _ -> pure Nothing
        let methods = [(method, signature) | Just (method, signature) <- checked]
        case parameters of
          [quantifier] ->
            pure
              environment
                { valueSignatures = Map.fromList [(GlobalRef method, signature) | (method, signature) <- methods] `Map.union` valueSignatures environment,
                  traitDeclarations = Map.insert ident (coreNode source (TraitDeclaration quantifier superclasses (Map.fromList [(method, signatureScheme signature) | (method, signature) <- methods]))) (traitDeclarations environment)
                }
          _ -> pure environment
      A.ImplementationDefinition _ _ _ _ _ -> pure environment
      _ -> pure environment
    prepareImplementation environment source = case A.nodeValue source of
      A.ImplementationDefinition ident parameters context head' members -> do
        (quantified, scope) <- bindQuantifiers (declarationTypes environment) parameters
        predicates <- mapM (readPredicate (declarationTypes environment) scope False) context
        predicate' <- readPredicate (declarationTypes environment) scope False head'
        let (base, arguments) = semanticSpine (predicateArgument predicate')
            variables = [v | Variable v _ <- arguments]
            validHead = case base of Constructor _ _ -> length variables == length arguments && length variables == Set.size (Set.fromList variables); _ -> False
            validContext p = case predicateArgument p of Variable v _ -> v `elem` variables; _ -> False
            methods = Map.fromList [(method, member) | member <- members, A.ValueDefinition (GlobalRef method) _ _ <- [A.nodeValue member]]
            required = maybe Map.empty (traitMethods . C.nodeValue) (Map.lookup (predicateTrait predicate') (traitDeclarations environment))
            ImplementationId (owner, _) = ident
            owns (GlobalId module' _ _) = module' == owner
            owns (IntrinsicId _) = False
        unless validHead (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan head') "implementation head must apply a nominal constructor to distinct bare variables"))
        forM_ (zip context predicates) $ \(predicateSource, p) ->
          unless (validContext p) (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan predicateSource) "implementation context must constrain a head variable"))
        unless (owns (predicateTrait predicate') || case base of Constructor constructor _ -> owns constructor; _ -> False) (emit (E.diagnostic E.OrphanImplementation (A.nodeSpan head') "an implementation must be declared by the trait or type constructor's module"))
        unless (Map.keysSet required == Map.keysSet methods) (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan source) "an implementation must supply every declared method exactly once"))
        let implementation = ImplementationDeclaration quantified predicates predicate' methods
        pure environment {implementationDeclarations = Map.insert ident (coreNode source implementation) (implementationDeclarations environment)}
      _ -> pure environment

appliedType :: Declarations -> GlobalId -> [Quantifier] -> InferType
appliedType environment ident parameters = foldl Application (Constructor ident kind) [Variable (Bound (quantifierId q)) (quantifierKind q) | q <- parameters]
  where
    kind = Map.findWithDefault TypeKind ident (typeKinds (declarationTypes environment))

coreNode :: A.Node a -> b -> C.Node b
coreNode source = C.Node (A.nodeId source) (A.nodeSpan source) (A.nodeOrigin source)

semanticSpine :: Type v -> (Type v, [Type v])
semanticSpine = collect []
  where
    collect supplied (Application f x) = collect (x : supplied) f
    collect supplied base = (base, supplied)

superclassDiagnostics :: Declarations -> [E.Diagnostic]
superclassDiagnostics environment = concatMap check components
  where
    components = stronglyConnComp [(node, ident, map predicateTrait (traitSuperclasses (C.nodeValue node))) | (ident, node) <- Map.toList (traitDeclarations environment)]
    check (AcyclicSCC _) = []
    check (CyclicSCC members) = [E.diagnostic E.CyclicSupertraits (C.nodeSpan node) "supertrait requirements form a cycle" | node <- members]

checkOverlap :: Declarations -> Infer ()
checkOverlap environment = forM_ pairs $ \(left, right) -> do
  let a = C.nodeValue left
      b = C.nodeValue right
  when (predicateTrait (implementationHead a) == predicateTrait (implementationHead b)) $ do
    (x, _, _) <- instantiate (C.nodeSpan left) (Scheme [] (implementationParameters a) [] (predicateArgument (implementationHead a)))
    (y, _, _) <- instantiate (C.nodeSpan right) (Scheme [] (implementationParameters b) [] (predicateArgument (implementationHead b)))
    case U.unify x y of
      Left _ -> pure ()
      Right _ -> emit ((E.diagnostic E.OverlappingImplementations (C.nodeSpan right) "visible implementation heads overlap") {E.diagnosticRelated = [(C.nodeSpan left, "other implementation")]})
  where
    entries = Map.elems (implementationDeclarations environment)
    pairs = [(a, b) | (index, a) <- zip [0 :: Int ..] entries, b <- drop (index + 1) entries]

-- | Follow recursive occurrences with the actual parameter substitution. This
-- also detects a changed parameter carried around a mutual recursion cycle,
-- without requiring different declarations to use the same binder names.
regularityDiagnostics :: Declarations -> [A.Declaration] -> [E.Diagnostic]
regularityDiagnostics environment sources = nub (concatMap check (Map.toList definitions))
  where
    definitions =
      Map.fromList
        [ (owner, fields)
        | source <- sources,
          Just (owner, constructors) <- [nominal source],
          let fields =
                [ (quantifiers scheme, zip locations (arguments (schemeType scheme)))
                | (constructor, locations) <- constructors,
                  Just descriptor <- [Map.lookup (C.DataConstructor constructor) (constructorDeclarations environment)],
                  let scheme = C.constructorScheme (C.nodeValue descriptor)
                ]
        ]
    nominal source = case A.nodeValue source of
      A.DataDefinition owner _ _ constructors -> Just (owner, [(ident, map A.nodeSpan fields) | constructor <- constructors, let (ident, fields) = A.nodeValue constructor])
      A.RecordDefinition owner _ _ constructor fields -> Just (owner, [(constructor, map (A.nodeSpan . snd . A.nodeValue) fields)])
      _ -> Nothing
    arguments ty = case functionParts ty of Nothing -> []; Just (input, output) -> input : arguments output
    check (owner, entries) =
      concat
        [ walk (Map.singleton owner actual) origin ty
        | (parameters, fields) <- entries,
          let actual = [Variable (Bound (quantifierId q)) (quantifierKind q) | q <- parameters],
          (origin, ty) <- fields
        ]
    walk active origin ty =
      let (base, supplied) = spine ty
          nested = concatMap (walk active origin) supplied
       in nested ++ case base of
            Constructor owner _ -> case Map.lookup owner active of
              Just original | supplied /= original -> [E.diagnostic E.NonRegularData origin "recursive occurrence changes the declared type parameters"]
              Just _ -> []
              Nothing ->
                concat
                  [ walk (Map.insert owner supplied active) location (S.apply mapping field)
                  | (parameters, fields) <- Map.findWithDefault [] owner definitions,
                    let mapping = binderSubstitution parameters supplied,
                    (location, field) <- fields
                  ]
            _ -> []
    spine = collect []
    collect supplied (Application f x) = collect (x : supplied) f
    collect supplied base = (base, supplied)
