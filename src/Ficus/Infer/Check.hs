-- | Source type inference. Its work tables retain source identities for the
-- elaborator; they are not a second checked expression AST. Residual evidence
-- obligations must be discharged before a module can cross the Core boundary.
module Ficus.Infer.Check (Inference (..), inferModule) where

import Control.Monad (foldM, forM, forM_, unless, void, when)
import Control.Monad.State.Strict (gets, modify')
import Data.List (elemIndex, nub)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Type qualified as E
import Ficus.Infer.Coverage
import Ficus.Infer.Declaration
import Ficus.Infer.Evidence
import Ficus.Infer.Goal
import Ficus.Infer.Initialization
import Ficus.Infer.Monad
import Ficus.Infer.Restriction
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Intrinsic (constructorSignature, literalType, primitiveFromKey, primitiveSignature)
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source

data Inference = Inference
  { inferredDeclarations :: Declarations,
    inferredValues :: Map Reference (Scheme InferType),
    remainingWanteds :: [Wanted],
    inferenceState :: InferState
  }
  deriving (Eq, Show)

data Context = Context
  { contextDeclarations :: Declarations,
    contextValues :: Map Reference (Scheme InferType),
    contextTypes :: TypeScope,
    contextNames :: Map Reference (Text, Span),
    visibleNames :: Map Text Reference,
    contextGivens :: [(Predicate InferType, Evidence)]
  }

data Judgement = Judgement {judgementType :: InferType, judgementWanteds :: [Wanted]}

inferModule :: Declarations -> A.AbstractModule -> Inference
inferModule imported tree =
  let action = do
        prepared <- prepareDeclarations imported tree
        let names = Map.fromList [(A.occurrenceReference occurrence, (A.occurrenceSpelling occurrence, A.occurrenceSpan occurrence)) | occurrence <- A.abstractOccurrences tree]
            importedValues = Map.map signatureScheme (valueSignatures imported)
            methods = Map.fromList [(GlobalRef method, scheme) | trait <- Map.elems (traitDeclarations prepared), (method, scheme) <- Map.toList (traitMethods (C.nodeValue trait))]
            context = Context prepared (methods `Map.union` importedValues) Map.empty names Map.empty []
        (checked, wanteds) <- bindingGroup True context (A.abstractDeclarations tree)
        solveFields checked
        checkImplementations checked tree
        constraints <- resolveWanteds checked wanteds
        mapM_ missingEvidence constraints
        unresolved <- Infer (gets pendingFields)
        forM_ unresolved $ \field -> emit (E.diagnostic E.UnresolvedWeakType (fieldSite field) "record receiver remains unknown at module completion")
        negations <- Infer (gets pendingNegations)
        forM_ (Map.elems negations) $ \node -> do
          operand <- zonk (C.nodeValue node)
          case operand of
            Variable (Meta _) _ -> pure ()
            _ -> checkNegation (C.nodeSpan node) operand
        finishWeakVariables
        prepareGoals constraints
        goals <- Infer (gets checkedGoals)
        reportGoals goals
        values <- mapM zonkScheme (contextValues checked)
        pure (prepared, values, constraints)
      ((finalDeclarations, finalValues, finalWanteds), state) = runInferFrom (initialState {nextVariable = importedFreshStart imported}) action
   in Inference finalDeclarations finalValues finalWanteds state

-- Imported schemes have independent scopes, but specialization can place an
-- imported method underneath new local binders. Keep new identities disjoint
-- so substituting an instance parameter cannot capture a method quantifier.
importedFreshStart :: Declarations -> Int
importedFreshStart environment = 1 + foldr max (-1) [ident | q <- allQuantifiers, let BoundId ident = quantifierId q]
  where
    allQuantifiers =
      concatMap (quantifiers . signatureScheme) (Map.elems (valueSignatures environment))
        ++ concatMap (quantifiers . C.constructorScheme . C.nodeValue) (Map.elems (constructorDeclarations environment))
        ++ concatMap (concatMap (quantifiers . snd . C.nodeValue) . C.recordFields . C.nodeValue) (Map.elems (recordDeclarations environment))
        ++ concatMap aliasParameters (Map.elems (aliases (declarationTypes environment)))
        ++ concat [traitParameter trait : concatMap quantifiers (Map.elems (traitMethods trait)) | node <- Map.elems (traitDeclarations environment), let trait = C.nodeValue node]
        ++ concatMap (implementationParameters . C.nodeValue) (Map.elems (implementationDeclarations environment))

recordType :: A.Node a -> InferType -> Infer ()
recordType source ty = Infer (modify' (\s -> s {checkedNodeTypes = Map.insert (A.nodeId source) ty (checkedNodeTypes s)}))

bindValue :: Reference -> Text -> Span -> Scheme InferType -> Context -> Context
bindValue reference name origin scheme context =
  context
    { contextValues = Map.insert reference scheme (contextValues context),
      contextNames = Map.insert reference (name, origin) (contextNames context),
      visibleNames = Map.insert name reference (visibleNames context)
    }

bindLocal :: A.Binder -> InferType -> Context -> Infer Context
bindLocal binder ty context = do
  recordType binder ty
  let (ident, name) = A.nodeValue binder
  pure (bindValue (LocalRef ident) name (A.nodeSpan binder) (monomorphic ty) context)

expression :: Context -> Maybe InferType -> A.Expr -> Infer Judgement
expression context expected source = do
  result <- inferForm
  forM_ expected $ \ty -> void (equate (A.nodeSpan source) ty (judgementType result))
  recordType source (judgementType result)
  pure result
  where
    origin = A.nodeSpan source
    newType = fresh origin TypeKind
    resultType = maybe newType pure expected
    types = declarationTypes (contextDeclarations context)
    inferForm = case A.nodeValue source of
      A.Ref reference -> referenceUse context source reference []
      A.Method ident -> referenceUse context source (GlobalRef ident) []
      A.Constructor ident -> constructorUse context source ident []
      A.Literal literal -> pure (Judgement (literalType literal) [])
      A.Hole ident -> do
        ty <- resultType
        let entries = [C.Node (NodeId (-n - 1)) location (SourceOrigin location) (name, scheme) | (n, (name, reference)) <- zip [0 :: Int ..] (Map.toAscList (visibleNames context)), LocalRef _ <- [reference], Just scheme <- [Map.lookup reference (contextValues context)], Just (_, location) <- [Map.lookup reference (contextNames context)]]
            goal = C.Node (A.nodeId source) origin (A.nodeOrigin source) (C.HoleGoal ident ty entries [])
        Infer (modify' (\s -> s {checkedGoals = Map.insert ident goal (checkedGoals s)}))
        pure (Judgement ty [])
      A.Apply {} | Just (constructor, ident, arguments, applications) <- constructorApplication source -> do
        use <- constructorUse context constructor ident arguments
        recordType constructor (judgementType use)
        (output, fields) <- foldM constructorArgument (judgementType use, []) applications
        forM_ expected $ \ty -> void (equate origin ty output)
        -- Infer fields in source order. Solve their equalities from the known
        -- tail back toward the head, so e.g. True :: anIntList blames True.
        inferred <- forM fields $ \(_, _, argument) -> expression context Nothing argument
        forM_ (reverse (zip fields inferred)) $ \((input, _, argument), value) -> void (equate (A.nodeSpan argument) input (judgementType value))
        pure (Judgement output (judgementWanteds use ++ concatMap judgementWanteds inferred))
      A.Apply f x -> do
        functionResult <- expression context Nothing f
        functionType <- zonk (judgementType functionResult)
        let functionWanted = [wanted {wantedOrigin = origin} | wanted <- judgementWanteds functionResult]
        case functionParts functionType of
          Just (input, output) -> do
            argument <- expression context (Just input) x
            pure (Judgement output (functionWanted ++ judgementWanteds argument))
          Nothing -> do
            argument <- expression context Nothing x
            output <- resultType
            let equalityOrigin = case functionType of Variable (Meta _) _ -> origin; _ -> A.nodeSpan x
            void (equate equalityOrigin functionType (function (judgementType argument) output))
            pure (Judgement output (functionWanted ++ judgementWanteds argument))
      A.TypeApply body arguments -> case A.nodeValue body of
        A.Ref reference -> referenceUse context source reference arguments
        A.Method ident -> referenceUse context source (GlobalRef ident) arguments
        A.Constructor ident -> constructorUse context source ident arguments
        _ -> do
          inferred <- expression context Nothing body
          forM_ arguments $ \argument -> emit (E.diagnostic E.ExcessTypeArguments (A.nodeSpan argument) "expression has no addressable explicit type binders")
          pure inferred
      A.Annotated body binders annotation -> do
        scope <- freshTypeScope context binders
        (predicates, written) <- readQualified types (scope `Map.union` contextTypes context) True annotation
        inferred <- expression context Nothing body
        void (equateWith E.InvalidAnnotation origin written (judgementType inferred))
        pure inferred {judgementType = written, judgementWanteds = judgementWanteds inferred ++ [Wanted (A.nodeId source) origin predicate | predicate <- predicates]}
      A.Lambda binder body -> do
        input <- newType
        output <- newType
        forM_ expected $ \ty -> void (equate origin ty (function input output))
        inner <- bindLocal binder input context
        result <- expression inner (Just output) body
        pure (Judgement (function input output) (judgementWanteds result))
      A.TypeLambda binders body -> do
        (quantified, _) <- bindQuantifiers types binders
        skolems <- mapM (freshSkolem . quantifierKind) quantified
        inner <- scopedTypes context binders skolems
        result <- expression inner Nothing body
        checkEscape context origin skolems
        arguments <- mapM (fresh origin . quantifierKind) quantified
        let mapping = S.fromBindings [(variable, ty) | (Variable variable _, ty) <- zip skolems arguments]
        resolved <- zonk (judgementType result)
        wanted <- mapM zonkWanted (judgementWanteds result)
        Infer (modify' (\s -> s {expressionSubstitutions = Map.insert (A.nodeId source) mapping (expressionSubstitutions s)}))
        pure (Judgement (S.apply mapping resolved) [w {wantedPredicate = fmap (S.apply mapping) (wantedPredicate w)} | w <- wanted])
      A.Match coverage receiver clauses -> do
        value <- expression context Nothing receiver
        result <- resultType
        wanted <- forM clauses $ \clause -> do
          let (pattern', guard, body) = A.nodeValue clause
          inner <- patternCheck context (judgementType value) pattern'
          guardResult <- traverse (expression inner (Just (primitive BoolType))) guard
          branch <- expression inner (Just result) body
          when (coverage == A.RequiredTotal) $ do
            total <- patternTotal (contextDeclarations inner) (judgementType value) pattern'
            unless total (emit (E.diagnostic E.RefutablePattern (A.nodeSpan pattern') "do-bind pattern does not cover every possible value"))
          pure (foldMap judgementWanteds guardResult ++ judgementWanteds branch)
        when (coverage == A.WarningCoverage) (checkCoverage (contextDeclarations context) origin [judgementType value] [([pattern'], maybe False (const True) guard, A.nodeSpan clause) | clause <- clauses, let (pattern', guard, _) = A.nodeValue clause])
        pure (Judgement result (judgementWanteds value ++ concat wanted))
      A.Conditional clauses -> do
        result <- resultType
        constraints <- forM clauses $ \clause -> do
          let (condition, body) = A.nodeValue clause
          test <- traverse (expression context (Just (primitive BoolType))) condition
          branch <- expression context (Just result) body
          pure (foldMap judgementWanteds test ++ judgementWanteds branch)
        pure (Judgement result (concat constraints))
      A.Sequence statements body -> do
        (inner, constraints) <- foldM statement (context, []) statements
        result <- expression inner expected body
        pure result {judgementWanteds = constraints ++ judgementWanteds result}
      A.Where _ bindings body -> do
        (inner, constraints) <- bindingGroup False context bindings
        result <- expression inner expected body
        pure result {judgementWanteds = constraints ++ judgementWanteds result}
      A.Product components -> do
        results <- mapM (expression context Nothing) components
        pure (Judgement (tupleType (map judgementType results)) (concatMap judgementWanteds results))
      A.List components -> do
        element <- newType
        results <- mapM (expression context (Just element)) components
        pure (Judgement (list element) (concatMap judgementWanteds results))
      A.Unit -> pure (Judgement (primitive UnitType) [])
      A.Negate body -> do
        result <- expression context expected body
        ty <- zonk (judgementType result)
        case ty of
          Variable (Meta _) _ -> do
            markWeak origin PendingNegation ty
            Infer (modify' (\s -> s {pendingNegations = Map.insert (A.nodeId source) (C.Node (A.nodeId source) origin (A.nodeOrigin source) ty) (pendingNegations s)}))
          _ -> checkNegation origin ty
        pure result
      A.Project receiver label -> do
        value <- expression context Nothing receiver
        result <- resultType
        addField context (A.nodeId source) (A.nodeSpan label) origin origin (judgementType value) (A.nodeValue label) result False
        pure (Judgement result (judgementWanteds value))
      A.ConstructRecord constructor fields -> constructRecord context source constructor fields
      A.UpdateRecord receiver fields -> do
        value <- expression context Nothing receiver
        checkDuplicateFields fields
        constraints <- forM fields $ \field -> do
          let (name, body) = A.nodeValue field
          result <- expression context Nothing body
          addField context (A.nodeId field) (labelSpan field) (A.nodeSpan receiver) (A.nodeSpan body) (judgementType value) name (judgementType result) True
          pure (judgementWanteds result)
        pure (Judgement (judgementType value) (judgementWanteds value ++ concat constraints))
    statement (current, constraints) sourceStatement = case A.nodeValue sourceStatement of
      A.Effect body -> do
        result <- expression current Nothing body
        pure (current, constraints ++ judgementWanteds result)
      A.BindStatement group -> do
        (inner, wanted) <- bindingGroup False current group
        pure (inner, constraints ++ wanted)
    constructorArgument (ty, fields) (application, argument) = do
      (input, output) <- case functionParts ty of
        Just parts -> pure parts
        Nothing -> do
          input <- fresh (A.nodeSpan argument) TypeKind
          output <- fresh (A.nodeSpan application) TypeKind
          void (equate (A.nodeSpan argument) ty (function input output))
          pure (input, output)
      recordType application output
      pure (output, fields ++ [(input, application, argument)])

constructorApplication :: A.Expr -> Maybe (A.Expr, GlobalId, [A.TypeArgument], [(A.Expr, A.Expr)])
constructorApplication = collect []
  where
    collect arguments source = case A.nodeValue source of
      A.Apply f x -> collect ((source, x) : arguments) f
      A.Constructor ident -> Just (source, ident, [], arguments)
      A.TypeApply body types -> case A.nodeValue body of A.Constructor ident -> Just (source, ident, types, arguments); _ -> Nothing
      _ -> Nothing

checkNegation :: Span -> InferType -> Infer ()
checkNegation origin ty = unless (ty == primitive IntType || ty == primitive FloatType) (emit (E.diagnostic E.TypeMismatch origin "negation requires Int or Float"))

referenceUse :: Context -> A.Expr -> Reference -> [A.TypeArgument] -> Infer Judgement
referenceUse context source reference arguments = case Map.lookup reference (contextValues context) of
  Nothing -> do
    emit (E.diagnostic E.InvalidCoreTree (A.nodeSpan source) "resolved value has no type in the inference environment")
    ty <- fresh (A.nodeSpan source) TypeKind
    pure (Judgement ty [])
  Just scheme -> instantiateUse context source scheme arguments

constructorUse :: Context -> A.Expr -> GlobalId -> [A.TypeArgument] -> Infer Judgement
constructorUse context source ident arguments = do
  scheme <- constructorScheme context (A.nodeSpan source) ident
  instantiateUse context source scheme arguments

instantiateUse :: Context -> A.Node a -> Scheme InferType -> [A.TypeArgument] -> Infer Judgement
instantiateUse context source scheme supplied = do
  (ty, predicates, arguments) <- instantiate (A.nodeSpan source) scheme
  let explicit = explicitQuantifiers scheme
  forM_ (drop (length explicit) supplied) $ \argument -> emit (E.diagnostic E.ExcessTypeArguments (A.nodeSpan argument) "too many explicit type arguments")
  forM_ (zip3 explicit arguments supplied) $ \(quantifier, inferred, written) -> do
    let writtenType = A.nodeValue written
    suppliedType <- readTypeAt (declarationTypes (contextDeclarations context)) (contextTypes context) True (quantifierKind quantifier) writtenType
    void (equate (A.nodeSpan writtenType) inferred suppliedType)
  Infer (modify' (\s -> s {checkedInstantiations = Map.insert (A.nodeId source) arguments (checkedInstantiations s)}))
  pure (Judgement ty [Wanted (A.nodeId source) (A.nodeSpan source) predicate | predicate <- predicates])

constructorScheme :: Context -> Span -> GlobalId -> Infer (Scheme InferType)
constructorScheme context origin ident = case constructorSignature (C.DataConstructor ident) of
  Just (scheme, _) -> pure (fmap (fmap (\case C.BoundVariable q -> Bound q; C.DiagnosticVariable (C.DiagnosticMetaId n) -> Meta (MetaId n))) scheme)
  Nothing -> case Map.lookup (C.DataConstructor ident) (constructorDeclarations (contextDeclarations context)) of
    Just descriptor -> pure (C.constructorScheme (C.nodeValue descriptor))
    Nothing -> do
      emit (E.diagnostic E.InvalidCoreTree origin "constructor has no semantic descriptor")
      monomorphic <$> fresh origin TypeKind

freshTypeScope :: Context -> [A.TypeBinder] -> Infer TypeScope
freshTypeScope context binders =
  Map.fromList
    <$> forM
      binders
      ( \binder -> do
          let (ident, _, _) = A.nodeValue binder
              kind = Map.findWithDefault TypeKind ident (binderKinds (declarationTypes (contextDeclarations context)))
          ty <- fresh (A.nodeSpan binder) kind
          pure (ident, ty)
      )

patternCheck :: Context -> InferType -> A.Pattern -> Infer Context
patternCheck context expected source = do
  recordType source expected
  case A.nodeValue source of
    A.Bind binder -> bindLocal binder expected context
    A.Wildcard -> pure context
    A.LiteralPattern literal -> void (equate (A.nodeSpan source) expected (literalType literal)) >> pure context
    A.UnitPattern -> void (equate (A.nodeSpan source) expected (primitive UnitType)) >> pure context
    A.ProductPattern patterns -> do
      components <- mapM (\p -> fresh (A.nodeSpan p) TypeKind) patterns
      void (equate (A.nodeSpan source) expected (tupleType components))
      foldM (\inner (ty, p) -> patternCheck inner ty p) context (zip components patterns)
    A.ListPattern patterns -> do
      element <- fresh (A.nodeSpan source) TypeKind
      void (equate (A.nodeSpan source) expected (list element))
      foldM (\inner -> patternCheck inner element) context patterns
    A.AnnotatedPattern body annotation -> do
      written <- readTypeAt (declarationTypes (contextDeclarations context)) (contextTypes context) True TypeKind annotation
      void (equate (A.nodeSpan annotation) expected written)
      patternCheck context expected body
    A.NegatedPattern body -> patternCheck context expected body
    A.ConstructorPattern ident patterns -> do
      scheme <- constructorScheme context (A.nodeSpan source) ident
      result <- instantiateUse context source scheme []
      let (arguments, final) = splitFunctions (judgementType result)
      when (length arguments /= length patterns) (emit (E.diagnostic E.TypeMismatch (A.nodeSpan source) "constructor pattern has the wrong number of fields"))
      void (equate (A.nodeSpan source) expected final)
      foldM (\inner (ty, p) -> patternCheck inner ty p) context (zip arguments patterns)

tupleType :: [InferType] -> InferType
tupleType [] = primitive UnitType
tupleType [ty] = ty
tupleType (ty : rest) = productType ty (tupleType rest)

splitFunctions :: InferType -> ([InferType], InferType)
splitFunctions ty = case functionParts ty of Nothing -> ([], ty); Just (a, b) -> let (rest, result) = splitFunctions b in (a : rest, result)

bindingGroup :: Bool -> Context -> A.BindingGroup -> Infer (Context, [Wanted])
bindingGroup topLevel context group = case schedule group of
  Left problem -> do
    forM_ (A.declarations group) $ \source -> emit (E.diagnostic E.InvalidCoreTree (A.nodeSpan source) (T.pack (show problem)))
    pure (context, [])
  Right groups -> do
    mapM_ emit (checkInitialization topLevel groups)
    foldM step (context, []) groups
  where
    step (outer, accumulated) component = do
      let declarations = case component of Acyclic source -> [source]; Cyclic sources -> NE.toList sources
      signatures <- forM declarations $ \source -> case A.nodeValue source of
        A.ValueDefinition reference annotation _ -> do
          signature <- case Map.lookup reference (valueSignatures (contextDeclarations outer)) of
            Just known -> pure (Just known)
            Nothing -> traverse (readScheme (declarationTypes (contextDeclarations outer)) (contextTypes outer) True) annotation
          (written, _) <- bindQuantifiers (declarationTypes (contextDeclarations outer)) (writtenTypeBinders source)
          let explicit = maybe written (explicitQuantifiers . signatureScheme) signature
          provisional <- case signature of
            Just known | not (signatureHasHoles known) -> pure (signatureScheme known)
            _ -> monomorphic <$> fresh (A.nodeSpan source) TypeKind
          pure (source, Just (reference, signature, provisional, explicit))
        _ -> pure (source, Nothing)
      let withPlaceholders = foldl (\inner (source, entry) -> case entry of Nothing -> inner; Just (reference, _, scheme, _) -> let (name, origin) = declarationName inner source reference in bindValue reference name origin scheme inner) outer signatures
          recursive = A.scopeMode group == A.Recursive
          bodyContext = if recursive then withPlaceholders else outer
      results <- forM signatures $ \(source, entry) -> case entry of
        Nothing -> case A.nodeValue source of
          A.PatternDefinition pattern' body -> do
            inferred <- expression bodyContext Nothing body
            bound <- patternCheck bodyContext (judgementType inferred) pattern'
            checkCoverage (contextDeclarations context) (A.nodeSpan pattern') [judgementType inferred] [([pattern'], False, A.nodeSpan pattern')]
            pure (source, Nothing, bound, inferred, S.empty)
          _ -> pure (source, Nothing, bodyContext, Judgement (primitive UnitType) [], S.empty)
        Just (reference, signature, provisional, explicit) -> do
          (target, given, skolems) <- case signature of
            Just known -> skolemize (signatureScheme known)
            Nothing -> skolemize (provisional {explicitQuantifiers = explicit})
          let scopedArguments = take (length explicit) skolems
              givenEvidence = [(predicate, GivenEvidence (A.nodeId source) index) | (index, predicate) <- zip [0 ..] given]
          inferred <- valueBody (bodyContext {contextGivens = givenEvidence ++ contextGivens bodyContext}) source target scopedArguments
          void (equate (A.nodeSpan source) target (judgementType inferred))
          case signature of
            Just known | not (signatureHasHoles known) -> pure ()
            _ -> void (equate (A.nodeSpan source) (schemeType provisional) target)
          checkEscape outer (maybe (A.nodeSpan source) signatureOrigin signature) skolems
          let quantified = maybe explicit (quantifiers . signatureScheme) signature
              abstraction = S.fromBindings [(variable, Variable (Bound (quantifierId q)) (quantifierKind q)) | (q, Variable variable _) <- zip quantified skolems]
          remaining <- resolveWanteds (bodyContext {contextGivens = givenEvidence ++ contextGivens bodyContext}) (judgementWanteds inferred)
          pure (source, Just (reference, signature, explicit), bodyContext {contextGivens = givenEvidence ++ contextGivens bodyContext}, inferred {judgementWanteds = remaining}, abstraction)
      solveFields bodyContext
      fields <- Infer (gets pendingFields)
      forM_ fields $ \field -> do
        markWeak (fieldSite field) PendingField (fieldReceiver field)
        markWeak (fieldSite field) PendingField (fieldResult field)
      let shared = concat [judgementWanteds inferred | (_, entry, _, inferred, _) <- results, case entry of Just (_, Just signature, _) -> signatureHasHoles signature; _ -> True]
          abstractGroup = foldr S.compose S.empty [mapping | (_, _, _, _, mapping) <- results]
          groupQuantifiers = concat [maybe explicit (quantifiers . signatureScheme) signature | (_, Just (_, signature, _, explicit)) <- signatures]
          completeResults = case component of
            Acyclic _ -> results
            Cyclic _ -> [(source, entry, inner, inferred {judgementWanteds = nub (judgementWanteds inferred ++ shared)}, mapping) | (source, entry, inner, inferred, mapping) <- results]
      foldM (finish outer abstractGroup groupQuantifiers) (outer, accumulated) completeResults
    finish outer abstractGroup groupQuantifiers (current, accumulated) (source, entry, patternContext, inferred, _) = case entry of
      Nothing -> do
        let refs = Set.toList (definedReferences source)
            eligible = initializerExpansiveOrigin source == Nothing && (null (judgementWanteds inferred) || hasValueParameters source)
        wanted <- resolveWanteds patternContext (judgementWanteds inferred)
        (generalizedRhs, mapping) <- generalizeWithMapping (A.nodeSpan source) eligible (Map.elems (contextValues outer)) (map wantedPredicate wanted) (judgementType inferred)
        let retained = filter (\w -> S.apply mapping (predicateArgument (wantedPredicate w)) /= predicateArgument (wantedPredicate w)) wanted
            rhsScheme = generalizedRhs {schemePredicates = nub (map (fmap (S.apply mapping) . wantedPredicate) retained)}
        Infer (modify' (\s -> s {checkedDeclarations = Map.insert (A.nodeId source) rhsScheme (checkedDeclarations s), bindingSubstitutions = Map.insert (A.nodeId source) mapping (bindingSubstitutions s)}))
        finished <-
          foldM
            ( \inner reference -> case Map.lookup reference (contextValues patternContext) of
                Nothing -> pure inner
                Just scheme -> do
                  resolved <- zonk (schemeType scheme)
                  let body = S.apply mapping resolved
                      generalized = Scheme [] [q | q <- quantifiers rhsScheme, Bound (quantifierId q) `Set.member` freeVariables body] [] body
                  Infer (modify' (\s -> s {checkedBindingSchemes = Map.insert reference generalized (checkedBindingSchemes s)}))
                  let (name, origin) = Map.findWithDefault ("$pattern", A.nodeSpan source) reference (contextNames patternContext)
                  pure (bindValue reference name origin generalized inner)
            )
            current
            refs
        pure (finished, accumulated ++ filter (`notElem` retained) wanted)
      Just (reference, signature, explicit) -> do
        wanted <- resolveWanteds patternContext (judgementWanteds inferred)
        let nonExpansiveInitializer = initializerExpansiveOrigin source == Nothing
            completeSignature = maybe False (not . signatureHasHoles) signature
            constrainedMono = not (null wanted) && not (hasValueParameters source) && not completeSignature
            eligible = nonExpansiveInitializer && not constrainedMono
            (name, origin) = declarationName current source reference
        when (not nonExpansiveInitializer && maybe False (not . null . quantifiers . signatureScheme) signature) (emit (E.diagnostic E.InvalidAnnotation (maybe origin signatureOrigin signature) "signature cannot generalize an expansive initializer"))
        (inferredScheme, generalization) <- generalizeWithMapping origin eligible (Map.elems (contextValues outer)) (map wantedPredicate wanted) (judgementType inferred)
        let mapping = S.compose abstractGroup generalization
            abstracted = fmap (S.apply abstractGroup) inferredScheme
            used = Set.unions (map freeVariables (schemeType abstracted : map predicateArgument (schemePredicates abstracted)))
            existing = Set.fromList (map quantifierId (explicit ++ implicitQuantifiers inferredScheme))
            sharedQuantifiers = [q | q <- groupQuantifiers, Bound (quantifierId q) `Set.member` used, quantifierId q `Set.notMember` existing]
            baseScheme = case signature of
              Just written | not (signatureHasHoles written) -> signatureScheme written
              _ -> abstracted {explicitQuantifiers = explicit, implicitQuantifiers = sharedQuantifiers ++ implicitQuantifiers inferredScheme}
            retained = if completeSignature then [] else filter (\w -> S.apply mapping (predicateArgument (wantedPredicate w)) /= predicateArgument (wantedPredicate w)) wanted
            remaining = filter (\w -> w `notElem` retained) wanted
            predicates = nub (map wantedPredicate retained)
            scheme = if completeSignature then baseScheme else baseScheme {schemePredicates = map (fmap (S.apply mapping)) predicates}
            ambiguous = Set.unions (map (freeVariables . predicateArgument) (schemePredicates scheme)) `Set.difference` freeVariables (schemeType scheme)
        unless (Set.null ambiguous) (emit (E.diagnostic E.AmbiguousConstraint origin "inferred constraint variables must occur in the value type"))
        forM_ retained $ \wanted' -> forM_ (elemIndex (wantedPredicate wanted') predicates) $ \index -> rememberEvidence wanted' (GivenEvidence (A.nodeId source) index)
        when completeSignature (mapM_ missingEvidence remaining)
        Infer (modify' (\s -> s {checkedBindingSchemes = Map.insert reference scheme (checkedBindingSchemes s), checkedDeclarations = Map.insert (A.nodeId source) scheme (checkedDeclarations s), bindingSubstitutions = Map.insert (A.nodeId source) mapping (bindingSubstitutions s), bindingWanteds = Map.insert (A.nodeId source) retained (bindingWanteds s)}))
        pure (bindValue reference name origin scheme current, accumulated ++ if completeSignature then [] else remaining)

valueBody :: Context -> A.Declaration -> InferType -> [InferType] -> Infer Judgement
valueBody context source expected explicit = case A.nodeValue source of
  A.ValueDefinition _ annotation (A.BuiltinBody key) -> do
    when (maybe True (\scheme -> let (_, _, body) = A.nodeValue scheme in hasHoles body) annotation) (emit (E.diagnostic E.MissingBuiltinSignature (A.nodeSpan source) "builtin values require a complete signature"))
    case primitiveFromKey key of
      Nothing -> emit (E.diagnostic E.BuiltinContractMismatch (A.nodeSpan source) "builtin key has no value contract")
      Just builtin -> do
        let (inputs, output) = primitiveSignature builtin
            convert = fmap (\case C.BoundVariable q -> Bound q; C.DiagnosticVariable (C.DiagnosticMetaId n) -> Meta (MetaId n))
        void (equateWith E.BuiltinContractMismatch (A.nodeSpan source) (convert (foldr function output inputs)) expected)
    pure (Judgement expected [])
  A.ValueDefinition _ _ (A.ClausesBody arity clauses) -> do
    parameterTypes <- mapM (const (fresh (A.nodeSpan source) TypeKind)) [1 .. arity]
    resultType <- fresh (A.nodeSpan source) TypeKind
    void (equate (A.nodeSpan source) expected (foldr function resultType parameterTypes))
    wanted <- forM clauses $ \clause -> do
      let value = A.nodeValue clause
      typed <- scopedTypes context (A.clauseTypes value) explicit
      inner <- foldM (\environment (ty, pattern') -> patternCheck environment ty pattern') typed (zip parameterTypes (A.clausePatterns value))
      (withWhere, whereWanted) <- bindingGroup False inner (A.clauseWhere value)
      body <- case A.nodeValue (A.clauseBody value) of
        A.TypeLambda binders expressionBody | null (A.clauseTypes value) && arity == 0 -> do
          scoped <- scopedTypes withWhere binders explicit
          result <- expression scoped (Just resultType) expressionBody
          recordType (A.clauseBody value) (judgementType result)
          pure result
        _ -> expression withWhere (Just resultType) (A.clauseBody value)
      pure (whereWanted ++ judgementWanteds body)
    checkCoverage (contextDeclarations context) (A.nodeSpan source) parameterTypes [(A.clausePatterns (A.nodeValue clause), False, A.nodeSpan clause) | clause <- NE.toList clauses]
    pure (Judgement expected (concat wanted))
  _ -> pure (Judgement expected [])

writtenTypeBinders :: A.Declaration -> [A.TypeBinder]
writtenTypeBinders source = case A.nodeValue source of
  A.ValueDefinition _ _ (A.ClausesBody arity (clause NE.:| _)) ->
    let value = A.nodeValue clause
     in case A.nodeValue (A.clauseBody value) of
          A.TypeLambda binders _ | arity == 0 && null (A.clauseTypes value) -> binders
          _ -> A.clauseTypes value
  _ -> []

scopedTypes :: Context -> [A.TypeBinder] -> [InferType] -> Infer Context
scopedTypes context binders arguments = do
  unless (null binders || length binders == length arguments) $
    forM_ binders $
      \binder -> emit (E.diagnostic E.TypeBinderMismatch (A.nodeSpan binder) "definition type binders must match its signature")
  inferred <- freshTypeScope context binders
  forM_ (zip binders arguments) $ \(binder, argument) -> do
    let (ident, _, _) = A.nodeValue binder
        expected = Map.findWithDefault TypeKind ident (binderKinds (declarationTypes (contextDeclarations context)))
    ensureKind (A.nodeSpan binder) expected argument
  let scoped = Map.fromList [(ident, argument) | (binder, argument) <- zip binders arguments, let (ident, _, _) = A.nodeValue binder]
  pure context {contextTypes = scoped `Map.union` inferred `Map.union` contextTypes context}

checkEscape :: Context -> Span -> [InferType] -> Infer ()
checkEscape context origin skolems = do
  environment <- mapM zonkScheme (Map.elems (contextValues context))
  scope <- mapM zonk (Map.elems (contextTypes context))
  let rigid = Set.unions (map freeVariables skolems)
      escaped = rigid `Set.intersection` (Set.unions (map freeSchemeVariables environment) `Set.union` Set.unions (map freeVariables scope))
  unless (Set.null escaped) (emit (E.diagnostic E.InvalidAnnotation origin "abstract signature variables would escape into the enclosing environment"))

declarationName :: Context -> A.Declaration -> Reference -> (Text, Span)
declarationName context source reference =
  let name = case reference of GlobalRef (GlobalId _ _ spelling) -> spelling; _ -> maybe "$local" fst (Map.lookup reference (contextNames context))
      origin = A.nodeSpan source
   in (name, origin {end = (start origin) {column = column (start origin) + T.length name - 1, offset = offset (start origin) + T.length name - 1}})

zonkWanted :: Wanted -> Infer Wanted
zonkWanted wanted = do
  predicate <- traverse zonk (wantedPredicate wanted)
  pure wanted {wantedPredicate = predicate}

resolveWanteds :: Context -> [Wanted] -> Infer [Wanted]
resolveWanteds context wanted = fmap concat $ forM wanted $ \unresolved -> do
  resolved <- zonkWanted unresolved
  givens <- forM (contextGivens context) $ \(predicate, proof) -> (,proof) <$> traverse zonk predicate
  evidence <- solvePredicate (contextDeclarations context) givens (wantedPredicate resolved)
  case evidence of
    Right proof -> rememberEvidence resolved proof >> pure []
    Left NoEvidence -> pure [resolved]
    Left MultipleEvidence -> emit (E.diagnostic E.OverlappingImplementations (wantedOrigin resolved) "constraint matches multiple visible implementations") >> pure []
    Left CyclicEvidence -> emit (E.diagnostic E.RecursiveEvidence (wantedOrigin resolved) "constraint resolution requires itself") >> pure []

rememberEvidence :: Wanted -> Evidence -> Infer ()
rememberEvidence wanted proof = Infer (modify' (\s -> s {checkedEvidence = checkedEvidence s ++ [(wanted, proof)]}))

missingEvidence :: Wanted -> Infer ()
missingEvidence wanted = emit (E.diagnostic E.UnsatisfiedConstraint (wantedOrigin wanted) ("no evidence for " <> renderConstructor (predicateTrait (wantedPredicate wanted)) <> " " <> renderInferType (predicateArgument (wantedPredicate wanted))))

checkImplementations :: Context -> A.AbstractModule -> Infer ()
checkImplementations context tree = forM_ (A.declarations (A.abstractDeclarations tree)) $ \source -> case A.nodeValue source of
  A.ImplementationDefinition ident parameters _ _ _ -> case Map.lookup ident (implementationDeclarations (contextDeclarations context)) of
    Nothing -> pure ()
    Just node -> do
      let implementation = C.nodeValue node
          quantified = implementationParameters implementation
      arguments <- mapM (freshSkolem . quantifierKind) quantified
      let mapping = binderSubstitution quantified arguments
          head' = fmap (S.apply mapping) (implementationHead implementation)
          predicates = map (fmap (S.apply mapping)) (implementationContext implementation)
          given = [(predicate, GivenEvidence (A.nodeId source) index) | (index, predicate) <- zip [0 ..] predicates]
          abstraction = S.fromBindings [(v, Variable (Bound (quantifierId q)) (quantifierKind q)) | (q, Variable v _) <- zip quantified arguments]
      scoped <- scopedTypes context parameters arguments
      let inner = scoped {contextGivens = given}
      Infer (modify' (\s -> s {bindingSubstitutions = Map.insert (A.nodeId source) abstraction (bindingSubstitutions s)}))
      case Map.lookup (predicateTrait head') (traitDeclarations (contextDeclarations context)) of
        Nothing -> pure ()
        Just traitNode -> do
          let trait = C.nodeValue traitNode
              owner = traitParameter trait
              ownerMapping = binderSubstitution [owner] [predicateArgument head']
              ownPredicate = Predicate (predicateTrait head') (Variable (Bound (quantifierId owner)) (quantifierKind owner))
              superclasses = map (fmap (S.apply ownerMapping)) (traitSuperclasses trait)
          unresolved <- resolveWanteds inner [Wanted (A.nodeId source) (A.nodeSpan source) superclass | superclass <- superclasses]
          mapM_ missingEvidence unresolved
          forM_ (Map.toList (implementationMembers implementation)) $ \(method, member) -> case Map.lookup method (traitMethods trait) of
            Nothing -> pure ()
            Just methodScheme -> do
              let scheme = fmap (S.apply ownerMapping) methodScheme {implicitQuantifiers = filter ((/= quantifierId owner) . quantifierId) (implicitQuantifiers methodScheme), schemePredicates = filter (/= ownPredicate) (schemePredicates methodScheme)}
              (expected, constraints, skolems) <- skolemize scheme
              let methodGiven = [(predicate, GivenEvidence (A.nodeId member) index) | (index, predicate) <- zip [0 ..] constraints]
                  methodContext = inner {contextGivens = methodGiven ++ contextGivens inner}
                  methodMapping = S.fromBindings [(v, Variable (Bound (quantifierId q)) (quantifierKind q)) | (q, Variable v _) <- zip (quantifiers scheme) skolems]
              forM_ (initializerExpansiveOrigin member) $ \origin -> emit (E.diagnostic E.ExpansiveInitializer origin "implementation member initializer must be non-expansive")
              inferred <- valueBody methodContext member expected (take (length (explicitQuantifiers scheme)) skolems)
              pending <- resolveWanteds methodContext (judgementWanteds inferred)
              mapM_ missingEvidence pending
              checkEscape inner (A.nodeSpan member) skolems
              Infer (modify' (\s -> s {checkedDeclarations = Map.insert (A.nodeId member) (fmap (S.apply abstraction) scheme) (checkedDeclarations s), bindingSubstitutions = Map.insert (A.nodeId member) (S.compose abstraction methodMapping) (bindingSubstitutions s)}))
  _ -> pure ()

addField :: Context -> NodeId -> Span -> Span -> Span -> InferType -> Text -> InferType -> Bool -> Infer ()
addField context ident origin site valueOrigin receiver name result update = do
  Infer (modify' (\s -> s {pendingFields = pendingFields s ++ [FieldWanted ident origin site valueOrigin receiver name result update]}))
  solveFields context

solveFields :: Context -> Infer ()
solveFields context = do
  fields <- Infer (gets pendingFields)
  Infer (modify' (\s -> s {pendingFields = []}))
  unresolved <- fmap concat $ forM fields $ \field -> do
    receiver <- zonk (fieldReceiver field)
    case typeHead receiver of
      Nothing -> pure [field]
      Just owner -> case Map.lookup owner (recordDeclarations (contextDeclarations context)) of
        Nothing -> do
          emit (E.diagnostic (if fieldIsUpdate field then E.NonRecordReceiver else E.TypeMismatch) (fieldSite field) "receiver is not a nominal record")
          pure []
        Just record -> case [(index, scheme) | (index, descriptor) <- zip [0 ..] (C.recordFields (C.nodeValue record)), let (name, scheme) = C.nodeValue descriptor, name == fieldName field] of
          [] -> emit (E.diagnostic E.UnknownField (fieldOrigin field) "record has no field with this label") >> pure []
          (index, scheme) : _ -> do
            (ty, _, _) <- instantiate (fieldOrigin field) scheme
            case functionParts ty of
              Just (input, output) -> do
                void (equate (fieldSite field) input receiver)
                void (equate (fieldValueOrigin field) output (fieldResult field))
              Nothing -> emit (E.diagnostic E.InvalidCoreTree (fieldOrigin field) "record field descriptor is not a selector")
            Infer (modify' (\s -> s {checkedFields = Map.insert (fieldNode field) (C.FieldId owner index) (checkedFields s)}))
            pure []
  Infer (modify' (\s -> s {pendingFields = unresolved}))
  when (length unresolved < length fields && not (null unresolved)) (solveFields context)

typeHead :: InferType -> Maybe GlobalId
typeHead ty = case ty of Constructor ident _ -> Just ident; Application f _ -> typeHead f; Variable _ _ -> Nothing

constructRecord :: Context -> A.Expr -> GlobalId -> [A.FieldAssignment] -> Infer Judgement
constructRecord context source constructor fields = do
  scheme <- constructorScheme context (A.nodeSpan source) constructor
  use <- instantiateUse context source scheme []
  let (_, result) = splitFunctions (judgementType use)
      owner = typeHead result
      record = owner >>= (\ident -> Map.lookup ident (recordDeclarations (contextDeclarations context)))
      declared = maybe [] (map (fst . C.nodeValue) . C.recordFields . C.nodeValue) record
      supplied = map (fst . A.nodeValue) fields
  checkDuplicateFields fields
  when (any (`notElem` supplied) declared) (emit (E.diagnostic E.MissingField (constructorSpan source constructor) "named construction must supply every field"))
  constraints <- forM fields $ \field -> do
    let (name, body) = A.nodeValue field
    value <- expression context Nothing body
    addField context (A.nodeId field) (labelSpan field) (A.nodeSpan source) (A.nodeSpan body) result name (judgementType value) False
    pure (judgementWanteds value)
  pure (Judgement result (concat constraints))

checkDuplicateFields :: [A.FieldAssignment] -> Infer ()
checkDuplicateFields fields = void (foldM check Set.empty fields)
  where
    check seen field = do
      let name = fst (A.nodeValue field)
      when (Set.member name seen) (emit (E.diagnostic E.DuplicateField (labelSpan field) "duplicate record field"))
      pure (Set.insert name seen)

labelSpan :: A.FieldAssignment -> Span
labelSpan field = let origin = A.nodeSpan field; name = fst (A.nodeValue field) in origin {end = (start origin) {column = column (start origin) + T.length name - 1, offset = offset (start origin) + T.length name - 1}}

constructorSpan :: A.Expr -> GlobalId -> Span
constructorSpan source ident = let origin = A.nodeSpan source; name = renderConstructor ident in origin {end = (start origin) {column = column (start origin) + T.length name - 1, offset = offset (start origin) + T.length name - 1}}
