module Ficus.Infer.Declaration (Declarations (..), TraitDeclaration (..), ImplementationDeclaration (..), emptyDeclarations, prepareDeclarations, prepareDeclarationsWithConfig, sameImplementationHead, exceptionDisplayTrait) where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.CompilationConfig
import Ficus.Error.Type qualified as E
import Ficus.Infer.Kind qualified as K
import Ficus.Infer.Monad
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Infer.Unify qualified as U
import Ficus.Primitive.Registry qualified as P
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Dependencies
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S

data TraitDeclaration = TraitDeclaration
  { traitParameter :: Quantifier,
    traitSuperclasses :: [Predicate InferType],
    traitMethods :: Map GlobalId (Scheme InferType),
    traitException :: Bool
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
    builtinRecordMembers :: Map Text A.FieldDescriptor,
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
emptyDeclarations = Declarations Map.empty Map.empty emptyTypes Map.empty Set.empty Map.empty Map.empty Map.empty Map.empty

prepareDeclarations :: Declarations -> A.AbstractModule -> Infer Declarations
prepareDeclarations = prepareDeclarationsWithConfig defaultCompilationConfig

prepareDeclarationsWithConfig :: CompilationConfig -> Declarations -> A.AbstractModule -> Infer Declarations
prepareDeclarationsWithConfig config imported tree = do
  let declarations = A.declarations (A.abstractDeclarations tree)
      summary = K.inferKinds (typeKinds (declarationTypes imported)) tree
      localAliases = [(ident, d) | d <- declarations, A.AliasDefinition ident _ _ _ <- [A.nodeValue d]]
      aliasIds = Set.fromList (map fst localAliases)
      environment = (withKinds summary (declarationTypes imported)) {aliasNames = aliasNames (declarationTypes imported) `Set.union` aliasIds}
      orderedAliases = stronglyConnComp [(d, ident, Set.toList (typeDependencies (declarationDependencies d) `Set.intersection` aliasIds)) | (ident, d) <- localAliases]
  mapM_ emit (K.kindDiagnostics summary)
  preparedTypes <- foldM prepareAlias environment orderedAliases
  let localException = Map.lookup "EXCEPTION" (A.builtinAssociations tree)
      dataKeys = P.builtinDataKeys
      localData = Map.restrictKeys (A.builtinAssociations tree) (Set.fromList dataKeys)
      associations = localData `Map.union` maybe (builtinTypeAssociations imported) (\ident -> Map.insert "EXCEPTION" ident (builtinTypeAssociations imported)) localException
  prepared <- foldM prepare (imported {declarationTypes = preparedTypes, builtinTypeAssociations = associations, builtinRecordMembers = A.builtinMemberAssociations tree `Map.union` builtinRecordMembers imported}) declarations
  forM_ localException $ \ident -> do
    let location = maybe (maybe (A.abstractSpan tree) A.entitySpan (Map.lookup ident (A.abstractEntities tree))) C.nodeSpan (Map.lookup ident (traitDeclarations prepared))
    unless
      (exceptionDisplayTrait prepared ident /= Nothing)
      (emit (E.diagnostic E.BuiltinContractMismatch location "EXCEPTION requires one Type parameter, no methods, and a rendering superclass"))
  when
    (length (filter (traitException . C.nodeValue) (Map.elems (traitDeclarations prepared))) > 1)
    (emit (E.diagnostic E.BuiltinContractMismatch (A.abstractSpan tree) "conflicting visible EXCEPTION trait associations"))
  forM_ (Map.toList localData) $ \(key, ident) -> do
    let location = maybe (A.abstractSpan tree) A.entitySpan (Map.lookup ident (A.abstractEntities tree))
        validType = Map.lookup ident (typeKinds (declarationTypes prepared)) == Just TypeKind && any ((== ident) . C.constructorOwner . C.nodeValue) (Map.elems (constructorDeclarations prepared)) && any (\source -> case A.nodeValue source of A.DataDefinition owner _ _ _ -> owner == ident; A.RecordDefinition owner _ _ _ _ _ -> owner == ident; _ -> False) declarations
        validConstructor owner fields = case (Map.lookup owner associations, Map.lookup (C.DataConstructor ident) (constructorDeclarations prepared)) of
          (Just ty, Just node) -> let descriptor = C.nodeValue node; scheme = C.constructorScheme descriptor in null (quantifiers scheme) && null (schemePredicates scheme) && schemeType scheme == foldr function (Constructor ty TypeKind) (map primitive fields)
          _ -> False
        valid = if key `elem` P.builtinDataTypes then validType else or [validConstructor owner fields | (constructor, owner, fields) <- P.builtinConstructors, constructor == key]
    unless valid (emit (E.diagnostic E.BuiltinContractMismatch location "builtin data or constructor association has an incompatible declaration"))
    when (maybe False (/= ident) (Map.lookup key (builtinTypeAssociations imported))) (emit (E.diagnostic E.BuiltinContractMismatch location "conflicting visible builtin associations"))
  validateExceptionPackage prepared tree
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
          let descriptor = C.ConstructorDescriptor (Scheme [] quantified [] (foldr function result arguments)) (length arguments) ident []
          pure (C.DataConstructor name, coreNode constructor descriptor)
        pure environment {constructorDeclarations = Map.fromList entries `Map.union` constructorDeclarations environment, uninhabitedTypes = if null constructors then Set.insert ident (uninhabitedTypes environment) else uninhabitedTypes environment}
      A.RecordDefinition ident parameters _ constructor fields members -> do
        (quantified, scope) <- bindQuantifiers (declarationTypes environment) parameters
        (hidden, hiddenScope) <- bindQuantifiers (declarationTypes environment) members
        let result = appliedType environment ident quantified
            completeScope = hiddenScope `Map.union` scope
        entries <- forM fields $ \field -> do
          let (name, sourceType) = A.nodeValue field
          ty <- readTypeAt (declarationTypes environment) completeScope False TypeKind sourceType
          pure (field, name, ty)
        let package = Map.lookup "SOMEEXCEPTION" (builtinTypeAssociations environment) == Just ident
            evidence = [Predicate exception (Variable (Bound (quantifierId q)) (quantifierKind q)) | package, Just exception <- [Map.lookup "EXCEPTION" (builtinTypeAssociations environment)], q <- hidden]
            scheme = Scheme [] (quantified ++ hidden) evidence (foldr function result [ty | (_, _, ty) <- entries])
            descriptor = C.ConstructorDescriptor scheme (length fields) ident hidden
            record = C.RecordDescriptor (C.DataConstructor constructor) [coreNode field (name, Scheme [] (quantified ++ [q | q <- hidden, Bound (quantifierId q) `Set.member` freeVariables ty]) [] (function result ty)) | (field, name, ty) <- entries] [coreNode member (quantifierName q, q) | (member, q) <- zip members hidden]
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
        let exception = Map.lookup "EXCEPTION" (A.builtinAssociations tree) == Just ident
        when exception $
          unless
            (length superclasses == 1 && null members && map quantifierKind parameters == [TypeKind])
            (emit (E.diagnostic E.BuiltinContractMismatch (A.nodeSpan source) "EXCEPTION requires one Type parameter, no methods, and one rendering superclass"))
        case parameters of
          [quantifier] ->
            pure
              environment
                { valueSignatures = Map.fromList [(GlobalRef method, signature) | (method, signature) <- methods] `Map.union` valueSignatures environment,
                  traitDeclarations = Map.insert ident (coreNode source (TraitDeclaration quantifier superclasses (Map.fromList [(method, signatureScheme signature) | (method, signature) <- methods]) exception)) (traitDeclarations environment)
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
        when (maybe False (traitException . C.nodeValue) (Map.lookup (predicateTrait predicate') (traitDeclarations environment))) $
          unless
            (all (\argument -> kindOf argument == Right TypeKind && Predicate (predicateTrait predicate') argument `elem` predicates) arguments)
            (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan head') "exception head parameters require their own Exception evidence and kind Type"))
        unless validHead (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan head') "implementation head must apply a nominal constructor to distinct bare variables"))
        forM_ (zip context predicates) $ \(predicateSource, p) ->
          unless (validContext p) (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan predicateSource) "implementation context must constrain a head variable"))
        unless (not (checkOrphanImplementations config) || owns (predicateTrait predicate') || case base of Constructor constructor _ -> owns constructor; _ -> False) (emit (E.diagnostic E.OrphanImplementation (A.nodeSpan head') "an implementation must be declared by the trait or type constructor's module"))
        unless (Map.keysSet required == Map.keysSet methods) (emit (E.diagnostic E.InvalidImplementation (A.nodeSpan source) "an implementation must supply every declared method exactly once"))
        let implementation = ImplementationDeclaration quantified predicates predicate' methods
            keep previousId previous = case previousId of
              ImplementationId (previousOwner, _) -> not (allowImportedImplementationOverrides config) || previousOwner == owner || not (sameImplementationHead implementation (C.nodeValue previous))
            retained = Map.filterWithKey keep (implementationDeclarations environment)
        pure environment {implementationDeclarations = Map.insert ident (coreNode source implementation) retained}
      _ -> pure environment

-- Valid heads apply a nominal constructor to distinct bare variables, so the
-- trait and outer constructor determine overlap, independently of binder IDs.
sameImplementationHead :: ImplementationDeclaration -> ImplementationDeclaration -> Bool
sameImplementationHead left right =
  let a = implementationHead left
      b = implementationHead right
   in predicateTrait a == predicateTrait b && case (fst (semanticSpine (predicateArgument a)), fst (semanticSpine (predicateArgument b))) of
        (Constructor x _, Constructor y _) -> x == y
        _ -> False

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
      A.RecordDefinition owner _ _ constructor fields _ -> Just (owner, [(constructor, map (A.nodeSpan . snd . A.nodeValue) fields)])
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

-- The superclass is resolved structurally, preserving renamed trait identities.
exceptionDisplayTrait :: Declarations -> GlobalId -> Maybe GlobalId
exceptionDisplayTrait environment ident = do
  source <- Map.lookup ident (traitDeclarations environment)
  let trait = C.nodeValue source
      q = traitParameter trait
      a = Variable (Bound (quantifierId q)) (quantifierKind q)
  parent <- case traitSuperclasses trait of [p] | predicateArgument p == a -> Just p; _ -> Nothing
  displaySource <- Map.lookup (predicateTrait parent) (traitDeclarations environment)
  let display = C.nodeValue displaySource
      parameter = traitParameter display
      expected = function (Variable (Bound (quantifierId parameter)) TypeKind) (primitive StringType)
  method <- case Map.elems (traitMethods display) of [scheme] -> Just scheme; _ -> Nothing
  if traitException trait
    && quantifierKind q == TypeKind
    && Map.null (traitMethods trait)
    && quantifierKind parameter == TypeKind
    && null (traitSuperclasses display)
    && null (explicitQuantifiers method)
    && implicitQuantifiers method == [parameter]
    && schemePredicates method == [Predicate (predicateTrait parent) (Variable (Bound (quantifierId parameter)) TypeKind)]
    && schemeType method == expected
    then Just (predicateTrait parent)
    else Nothing

validateExceptionPackage :: Declarations -> A.AbstractModule -> Infer ()
validateExceptionPackage environment tree = do
  let local = Map.member "SOMEEXCEPTION" (A.builtinAssociations tree) || not (Map.null (A.builtinMemberAssociations tree))
      package = Map.lookup "SOMEEXCEPTION" (builtinTypeAssociations environment)
      members = builtinRecordMembers environment
      origin = A.abstractSpan tree
      valid = do
        owner <- package
        record <- C.nodeValue <$> Map.lookup owner (recordDeclarations environment)
        q <- case C.recordTypeMembers record of [member] -> Just (snd (C.nodeValue member)); _ -> Nothing
        hidden <- Map.lookup "SOMEEXCEPTION_ERR" members
        value <- Map.lookup "SOMEEXCEPTION_VALUE" members
        renderer <- Map.lookup "SOMEEXCEPTION_SHOWERR" members
        let fields = [(name, schemeType scheme) | field <- C.recordFields record, let (name, scheme) = C.nodeValue field]
            witness = Variable (Bound (quantifierId q)) TypeKind
            result = Constructor owner TypeKind
        pure
          ( map A.fieldOwner [hidden, value, renderer] == replicate 3 owner
              && A.fieldLabel hidden == quantifierName q
              && quantifierKind q == TypeKind
              && Map.lookup owner (typeKinds (declarationTypes environment)) == Just TypeKind
              && length fields == 2
              && lookup (A.fieldLabel value) fields == Just (function result witness)
              && lookup (A.fieldLabel renderer) fields == Just (function result (function witness (primitive StringType)))
          )
  when (local && valid /= Just True) (emit (E.diagnostic E.BuiltinContractMismatch origin "SOMEEXCEPTION requires one hidden Type member, its value, and a renderer for that same member; associate every member key"))
