-- | Source-to-Core lowering consumes solved types. Missing work-table entries
-- are boundary errors, never invented values or expression-hole placeholders.
module Ficus.Elaborate.Lower (lowerModule) where

import Control.Monad (filterM, foldM, forM, forM_)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.State.Strict (gets, modify')
import Control.Monad.Trans.Class (lift)
import Data.List (findIndex)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Builtin.Registry (primitiveFromKey, specializePrimitive)
import Ficus.Elaborate.Schedule
import Ficus.Elaborate.Types
import Ficus.Error.Type qualified as E
import Ficus.Infer.Check
import Ficus.Infer.Declaration
import Ficus.Infer.Evidence
import Ficus.Infer.Initialization
import Ficus.Infer.Monad
import Ficus.Infer.Restriction
import Ficus.Infer.Syntax (Signature (..), TypeEnvironment (..))
import Ficus.Infer.Type
import Ficus.Infer.Unify qualified as U
import Ficus.Primitive.Registry qualified as P
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Intrinsic hiding (primitiveFromKey)
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source

type Lower = ExceptT E.Diagnostic Infer

data Context = Context
  { declarations :: Declarations,
    schemes :: Map Reference (Scheme InferType),
    mapping :: S.Substitution InferVariable,
    givens :: [(Predicate InferType, C.Binder InferType)],
    boundValues :: Set.Set Reference,
    lazyValues :: Map Reference (C.Binder InferType),
    memberReferences :: Map GlobalId (Predicate InferType, Reference)
  }

lowerModule :: Inference -> A.AbstractModule -> (Either E.Diagnostic (C.CoreModule InferType), InferState)
lowerModule inferred source = runInferFrom (inferenceState inferred) (runExceptT action)
  where
    prepared = inferredDeclarations inferred
    context = Context prepared (checkedBindingSchemes (inferenceState inferred) `Map.union` Map.map signatureScheme (valueSignatures prepared)) S.empty [] Set.empty Map.empty Map.empty
    action = do
      dictionaries <- lift (dictionaryDescriptors prepared)
      bindings <- lowerTop context (A.abstractDeclarations source)
      implementations <- fmap concat $ forM (A.declarations (A.abstractDeclarations source)) $ \declaration -> case A.nodeValue declaration of
        A.ImplementationDefinition ident _ _ _ _ -> (: []) <$> lowerImplementation context declaration ident
        _ -> pure []
      ordered <- either throwError pure (scheduleBindings (concatMap C.groupBindings bindings ++ implementations))
      lift (mapM_ emit (initializationDiagnostics ordered))
      goals <- lift (Infer (gets checkedGoals))
      let local = Set.fromList [C.bindingReference (C.nodeValue binding) | group <- bindings, binding <- C.groupBindings group]
          imported = Map.filterWithKey (\reference _ -> case reference of GlobalRef _ -> reference `Set.notMember` local; LocalRef _ -> False) (inferredValues inferred)
          importedImplementations = Map.fromList [(implementationReference ident, implementationScheme prepared (C.nodeValue node)) | (ident@(ImplementationId (owner, _)), node) <- Map.toList (implementationDeclarations prepared), owner /= A.abstractId source]
          references = Set.unions [referencedValues (C.bindingBody (C.nodeValue binding)) | group <- ordered, binding <- C.groupBindings group]
      pure
        C.CoreModule
          { C.coreId = A.abstractId source,
            C.coreCompilationConfig = inferenceCompilationConfig inferred,
            C.coreSpan = A.abstractSpan source,
            C.coreOrigin = A.abstractOrigin source,
            C.coreBuiltins = Map.restrictKeys (builtinTypeAssociations prepared) (Set.fromList (P.builtinDataKeys)),
            C.coreBuiltinMembers = builtinRecordMembers prepared,
            C.coreKinds = typeKinds (declarationTypes prepared),
            C.coreImports = Map.restrictKeys (Map.map (evidenceScheme prepared) imported `Map.union` importedImplementations) references,
            C.coreConstructors = fmap (fmap (\descriptor -> descriptor {C.constructorScheme = evidenceScheme prepared (C.constructorScheme descriptor), C.constructorArity = C.constructorArity descriptor + length (schemePredicates (C.constructorScheme descriptor))})) (constructorDeclarations prepared),
            C.coreRecords = recordDeclarations prepared,
            C.coreDictionaries = dictionaries,
            C.coreBindings = ordered,
            C.coreGoals = goals
          }

failure :: A.Node a -> Text -> Lower b
failure source message = throwError (E.diagnostic E.InvalidCoreTree (A.nodeSpan source) message)

generated :: A.Node a -> Text -> b -> Lower (C.Node b)
generated source reason value = do
  ident <- lift freshId
  pure (C.Node (NodeId (-ident - 1)) (A.nodeSpan source) (GeneratedOrigin reason (A.nodeSpan source)) value)

sourceExpression :: A.Expr -> InferType -> C.ExprF InferType -> C.Expr InferType
sourceExpression source ty form = C.Node (A.nodeId source) (A.nodeSpan source) (A.nodeOrigin source) (C.TypedExpr ty form)

makeExpression :: A.Node a -> InferType -> C.ExprF InferType -> Lower (C.Expr InferType)
makeExpression source ty form = generated source "elaborated expression" (C.TypedExpr ty form)

resolved :: Context -> InferType -> Lower InferType
resolved context ty = S.apply (mapping context) <$> lift (zonk ty)

nodeType :: Context -> A.Node a -> Lower InferType
nodeType context source = do
  found <- lift (Infer (gets (Map.lookup (A.nodeId source) . checkedNodeTypes)))
  maybe (failure source "checked source node has no inferred type") (resolved context) found

withMapping :: Context -> A.Node a -> Lower Context
withMapping context source = do
  abstracted <- lift (Infer (gets (Map.findWithDefault S.empty (A.nodeId source) . bindingSubstitutions)))
  pure context {mapping = S.compose (mapping context) abstracted}

freshBinder :: A.Node a -> Text -> C.BinderRole -> InferType -> Lower (C.Binder InferType)
freshBinder source name role ty = do
  ident <- lift freshId
  generated source "elaborated binder" (LocalId (-ident - 1), name, role, ty)

binderUse :: A.Node a -> C.Binder InferType -> Lower (C.Expr InferType)
binderUse source binder = makeExpression source (C.binderType binder) (C.Var (C.binderReference binder) [])

monoBinding :: A.Node a -> Reference -> C.Expr InferType -> Lower (C.Binding InferType)
monoBinding source reference body = generated source "strict temporary" (C.Binding reference (monomorphic (C.typeOf body)) body (C.BindingFacts 0 Nothing))

letValue :: A.Node a -> C.Expr InferType -> (C.Expr InferType -> Lower (C.Expr InferType)) -> Lower (C.Expr InferType)
letValue source value continuation = do
  binder <- freshBinder source "$value" C.ValueBinder (C.typeOf value)
  reference <- binderUse source binder
  binding <- monoBinding source (C.binderReference binder) value
  body <- continuation reference
  makeExpression source (C.typeOf body) (C.Let binding body)

apply :: A.Node a -> C.Expr InferType -> C.Expr InferType -> Lower (C.Expr InferType)
apply source f x = case arrowParts (C.typeOf f) of
  Just (mode, _, result) -> do
    argument <- delayArgument source mode x
    makeExpression source result (C.Apply f argument)
  Nothing -> failure source "checked application has no function type"

delayArgument :: A.Node a -> ArrowMode -> C.Expr InferType -> Lower (C.Expr InferType)
delayArgument _ StrictArrow value = pure value
delayArgument source NameArrow value = do
  binder <- freshBinder source "$delay" C.ValueBinder (primitive UnitType)
  generated source "call-by-name argument" (C.TypedExpr (C.parameterType NameArrow (C.typeOf value)) (C.Lambda binder value))

demand :: A.Node a -> C.Binder InferType -> Lower (C.Expr InferType)
demand source binder = do
  thunk <- binderUse source binder
  unit <- makeExpression source (primitive UnitType) (C.Construct C.UnitConstructor [] [])
  apply source thunk unit

-- An annotation does not change the underlying pattern's demand behavior.
undemandingPattern :: A.Pattern -> Maybe (Maybe A.Binder)
undemandingPattern source = case A.nodeValue source of
  A.Bind binder -> Just (Just binder)
  A.Wildcard -> Just Nothing
  A.AnnotatedPattern pattern' _ -> undemandingPattern pattern'
  _ -> Nothing

bindLazyPattern :: Context -> C.Binder InferType -> Maybe A.Binder -> Context
bindLazyPattern context _ Nothing = context
bindLazyPattern context thunk (Just binder) = context {lazyValues = Map.insert (LocalRef (fst (A.nodeValue binder))) thunk (lazyValues context)}

sourceBinder :: A.Binder -> InferType -> C.Binder InferType
sourceBinder binder ty =
  let (ident, name) = A.nodeValue binder
   in C.Node (A.nodeId binder) (A.nodeSpan binder) (A.nodeOrigin binder) (ident, name, C.ValueBinder, ty)

-- Only resolver-generated parameter matches may skip a variable/wildcard
-- demand. An explicit `with x { _ -> ... }` still evaluates its receiver.
lazyLambdaPattern :: A.Expr -> Maybe (Maybe A.Binder, A.Expr)
lazyLambdaPattern body = case (A.nodeOrigin body, A.nodeValue body) of
  (GeneratedOrigin "lambda pattern match" _, A.Match _ _ [clause])
    | (pattern', Nothing, result) <- A.nodeValue clause,
      Just binding <- undemandingPattern pattern' ->
        Just (binding, result)
  _ -> Nothing

expression :: Context -> A.Expr -> Lower (C.Expr InferType)
expression context source = do
  ty <- nodeType context source
  let sourced = pure . sourceExpression source ty
  case A.nodeValue source of
    A.Ref reference -> referenceUse context source reference
    A.Method ident -> referenceUse context source (GlobalRef ident)
    A.Constructor ident -> constructorUse context source ident
    A.Literal literal -> sourced (C.Literal literal)
    A.Hole ident -> do
      goal <- lift (Infer (gets (Map.lookup ident . checkedGoals)))
      forM_ goal $ \entry -> do
        checked <- traverse (traverse (resolved context)) entry
        lift (Infer (modify' (\s -> s {checkedGoals = Map.insert ident checked (checkedGoals s)})))
      sourced (C.Hole ident)
    A.Apply f x -> do
      function' <- expression context f
      argument <- expression context x
      case arrowParts (C.typeOf function') of
        Just (mode, _, _) -> delayArgument x mode argument >>= sourced . C.Apply function'
        Nothing -> failure source "checked application has no function type"
    A.TypeApply body _ -> case A.nodeValue body of
      A.Ref reference -> referenceUse context source reference
      A.Method ident -> referenceUse context source (GlobalRef ident)
      A.Constructor ident -> constructorUse context source ident
      _ -> failure source "checked explicit application has no addressed value"
    A.Annotated body _ _ -> expression context body
    A.TypeLambda _ body -> do
      instantiated <- lift (Infer (gets (Map.findWithDefault S.empty (A.nodeId source) . expressionSubstitutions)))
      expression (context {mapping = S.compose (mapping context) instantiated}) body
    A.Lambda binder body -> do
      input <- nodeType context binder
      mode <- case arrowParts ty of Just (mode, _, _) -> pure mode; Nothing -> failure source "lambda has no function type"
      let ident = fst (A.nodeValue binder)
          lazyPattern = if mode == NameArrow then lazyLambdaPattern body else Nothing
          parameter = case lazyPattern of Just (Just named, _) -> named; _ -> binder
          checked = sourceBinder parameter (C.parameterType mode input)
          bound = context {boundValues = Set.insert (LocalRef ident) (boundValues context)}
          inner = if mode == NameArrow then bindLazyPattern bound checked (Just binder) else bound
      result <- case lazyPattern of
        Just (binding, result) -> expression (bindLazyPattern inner checked binding) result
        _ -> expression inner body
      sourced (C.Lambda checked result)
    A.Match _ receiver clauses -> do
      value <- expression context receiver
      letValue receiver value $ \reference -> do
        fallback <- makeExpression source ty C.Fail
        case clauses of
          [] -> makeExpression source ty (C.Case reference [] fallback)
          _ -> foldM (lowerClause context reference) fallback (reverse clauses)
    A.Conditional clauses -> do
      arms <- forM clauses $ \clause -> do
        let (condition, body) = A.nodeValue clause
        test <- traverse (expression context) condition
        result <- expression context body
        pure (clause, test, result)
      conditions <- forM [(clause, condition, body) | (clause, Just condition, body) <- arms] $ \(clause, condition, body) -> generated clause "conditional arm" (condition, body)
      sourced (C.If conditions (case [body | (_, Nothing, body) <- arms] of body : _ -> Just body; [] -> Nothing))
    A.Sequence statements body -> lowerStatements context statements (expression context body)
    A.Where _ group body -> lowerGroup context group (expression context body)
    A.Product components -> mapM (expression context) components >>= productExpression source
    A.List components -> do
      values <- mapM (expression context) components
      element <- case ty of Application (Constructor (IntrinsicId ListType) _) item -> pure item; _ -> failure source "checked list has no element type"
      nil <- makeExpression source ty (C.Construct (C.DataConstructor (IntrinsicId NilConstructor)) [element] [])
      foldM (\rest value -> makeExpression source ty (C.Construct (C.DataConstructor (IntrinsicId ConsConstructor)) [element] [value, rest])) nil (reverse values)
    A.Unit -> sourced (C.Construct C.UnitConstructor [] [])
    A.Negate body -> do
      value <- expression context body
      builtin <- if ty == primitive IntType then pure C.IntNegate else if ty == primitive FloatType then pure C.FloatNegate else failure source "negation operand was not solved"
      sourced (C.Primitive builtin [value])
    A.Project receiver _ -> do
      value <- expression context receiver
      field <- fieldId source
      sourced (C.SelectField value field)
    A.PackRecord constructor _ fields -> recordConstruction context source constructor fields
    A.ConstructRecord constructor fields -> recordConstruction context source constructor fields
    A.UpdateRecord receiver fields -> recordUpdate context source receiver fields

useArguments :: Context -> A.Node a -> Scheme InferType -> InferType -> Lower [InferType]
useArguments context source scheme wanted = do
  recorded <- lift (Infer (gets (Map.findWithDefault [] (A.nodeId source) . checkedInstantiations)))
  if length recorded == length (quantifiers scheme)
    then mapM (resolved context) recorded
    else do
      (patternType, _, arguments) <- lift (instantiate (A.nodeSpan source) scheme)
      case U.match patternType wanted of
        Left _ -> failure source "recursive reference cannot instantiate its finalized scheme"
        Right substitution' -> pure (map (S.apply substitution') arguments)

referenceUse :: Context -> A.Expr -> Reference -> Lower (C.Expr InferType)
referenceUse context source reference | Just binder <- Map.lookup reference (lazyValues context) = do
  ty <- resolved context (C.binderType binder)
  demand source (fmap (\(ident, name, role, _) -> (ident, name, role, ty)) binder)
referenceUse context source reference = do
  ty <- nodeType context source
  let scheme = Map.findWithDefault (monomorphic ty) reference (schemes context)
  checked <- traverse (resolved context) scheme
  arguments <- useArguments context source checked ty
  let substitution' = binderSubstitution (quantifiers checked) arguments
      predicates = map (fmap (S.apply substitution')) (schemePredicates checked)
      ordinary = S.apply substitution' (schemeType (evidenceScheme (declarations context) checked))
      methodOwner = [(owner, trait) | (owner, node) <- Map.toList (traitDeclarations (declarations context)), let trait = C.nodeValue node, GlobalRef method <- [reference], Map.member method (traitMethods trait)]
  case (methodOwner, reference, predicates) of
    ((owner, trait) : _, GlobalRef method, ownPredicate : restPredicates) -> do
      index <- maybe (failure source "method has no dictionary slot") pure (findIndex (== method) (Map.keys (traitMethods trait)))
      let methodArguments = [argument | (q, argument) <- zip (quantifiers checked) arguments, quantifierId q /= quantifierId (traitParameter trait)]
      selectedType <- case functionParts ordinary of Just (_, result) -> pure result; Nothing -> failure source "method scheme has no owning dictionary"
      selected <- case Map.lookup method (memberReferences context) of
        Just (head', local) | head' == ownPredicate -> makeExpression source selectedType (C.Var local methodArguments)
        _ -> do
          dictionary <- evidence context source ownPredicate
          makeExpression source selectedType (C.SelectMethod dictionary owner index methodArguments)
      rest <- mapM (evidence context source) restPredicates
      foldM (apply source) selected rest
    (_ : _, _, _) -> failure source "method use has no owning evidence"
    _ -> do
      dictionaries <- mapM (evidence context source) predicates
      value <- makeExpression source ordinary (C.Var reference arguments)
      foldM (apply source) value dictionaries

evidence :: Context -> A.Node a -> Predicate InferType -> Lower (C.Expr InferType)
evidence context source predicate = do
  checked <- lift (Infer (gets checkedEvidence))
  roots <- lift (Infer (gets patternGivens))
  let origins proof' = case proof' of GivenEvidence ident index -> [(ident, index)]; SuperclassEvidence _ _ parent -> origins parent; ImplementationEvidence _ _ parents -> concatMap origins parents
  matching <- filterM (\(wanted, _) -> do actual <- traverse (resolved context) (wantedPredicate wanted); pure (wantedNode wanted == A.nodeId source && actual == predicate)) checked
  let required = Set.toList (Set.fromList [key' | (_, proof') <- matching, key' <- origins proof', Map.member key' roots])
  opened <- forM required $ \key' -> do
    binder <- patternGiven context source key'
    p <- maybe (failure source "pattern evidence has no predicate") (\(_, _, p) -> traverse (resolved context) p) (Map.lookup key' roots)
    pure (p, binder)
  let available = [(p, GivenEvidence (C.nodeId binder) 0) | (p, binder) <- opened ++ givens context]
  proof <- lift (solvePredicate (declarations context) available predicate)
  either (const (failure source "checked constraint has no dictionary evidence")) (build opened) proof
  where
    build opened (GivenEvidence ident _) = case [binder | (_, binder) <- opened ++ givens context, C.nodeId binder == ident] of
      binder : _ -> binderUse source binder
      [] -> failure source "given dictionary is out of scope"
    build opened (SuperclassEvidence owner index parent) = do
      receiver <- build opened parent
      trait <- maybe (failure source "superclass descriptor missing") (pure . C.nodeValue) (Map.lookup owner (traitDeclarations (declarations context)))
      argument <- case C.typeOf receiver of Application (Constructor actual _) ty | actual == owner -> pure ty; _ -> failure source "superclass receiver has the wrong dictionary type"
      superclass <- case drop index (traitSuperclasses trait) of value : _ | index >= 0 -> pure value; _ -> failure source "superclass slot is out of range"
      let specialized = fmap (S.apply (binderSubstitution [traitParameter trait] [argument])) superclass
      makeExpression source (dictionaryType (declarations context) specialized) (C.SelectSuperclass receiver owner index)
    build opened (ImplementationEvidence ident arguments proofs) = do
      implementation <- maybe (failure source "evidence names an unknown implementation") (pure . C.nodeValue) (Map.lookup ident (implementationDeclarations (declarations context)))
      let scheme = implementationScheme (declarations context) implementation
          ty = S.apply (binderSubstitution (quantifiers scheme) arguments) (schemeType scheme)
      builder <- makeExpression source ty (C.Var (implementationReference ident) arguments)
      contextEvidence <- mapM (build opened) proofs
      foldM (apply source) builder contextEvidence

constructorUse :: Context -> A.Expr -> GlobalId -> Lower (C.Expr InferType)
constructorUse context source ident = do
  let constructor = C.DataConstructor ident
  (scheme, arity) <- constructorInfo context source constructor
  ty <- nodeType context source
  arguments <- useArguments context source scheme ty
  let instantiated = S.apply (binderSubstitution (quantifiers scheme) arguments) (schemeType scheme)
  dictionaries <- mapM (evidence context source . fmap (S.apply (binderSubstitution (quantifiers scheme) arguments))) (schemePredicates scheme)
  etaExpand source arity instantiated (\fields result -> makeExpression source result (C.Construct constructor arguments (dictionaries ++ fields)))

constructorInfo :: Context -> A.Node a -> C.ConstructorId -> Lower (Scheme InferType, Int)
constructorInfo context source ident = case constructorSignature ident of
  Just (scheme, arity) -> pure (fmap (fmap convert) scheme, arity)
  Nothing -> case Map.lookup ident (constructorDeclarations (declarations context)) of
    Nothing -> failure source "constructor descriptor is absent"
    Just node -> pure (C.constructorScheme (C.nodeValue node), C.constructorArity (C.nodeValue node))
  where
    convert (C.BoundVariable q) = Bound q
    convert (C.DiagnosticVariable (C.DiagnosticMetaId n)) = Meta (MetaId n)

etaExpand :: A.Node a -> Int -> InferType -> ([C.Expr InferType] -> InferType -> Lower (C.Expr InferType)) -> Lower (C.Expr InferType)
etaExpand source arity ty body = go arity ty []
  where
    go count current arguments
      | count <= 0 = body arguments current
      | otherwise = case functionParts current of
          Nothing -> failure source "saturated operation has too few function arrows"
          Just (input, output) -> do
            binder <- freshBinder source "$argument" C.ValueBinder input
            reference <- binderUse source binder
            result <- go (count - 1) output (arguments ++ [reference])
            makeExpression source current (C.Lambda binder result)

productExpression :: A.Node a -> [C.Expr InferType] -> Lower (C.Expr InferType)
productExpression source values = case values of
  [] -> makeExpression source (primitive UnitType) (C.Construct C.UnitConstructor [] [])
  [single] -> pure single
  first : rest -> do
    tail' <- productExpression source rest
    makeExpression source (productType (C.typeOf first) (C.typeOf tail')) (C.Construct C.PairConstructor [C.typeOf first, C.typeOf tail'] [first, tail'])

fieldId :: A.Node a -> Lower C.FieldId
fieldId source = do
  found <- lift (Infer (gets (Map.lookup (A.nodeId source) . checkedFields)))
  maybe (failure source "record field was not resolved to a nominal slot") pure found

lowerClause :: Context -> C.Expr InferType -> C.Expr InferType -> A.MatchClause -> Lower (C.Expr InferType)
lowerClause context receiver fallback clause = do
  let (pattern', guard, body) = A.nodeValue clause
  result <- expression context body
  success <- case guard of
    Nothing -> pure result
    Just condition -> do
      test <- expression context condition
      arm <- generated clause "match guard" (test, result)
      makeExpression clause (C.typeOf result) (C.If [arm] (Just fallback))
  matchPattern context receiver pattern' success fallback

matchPattern :: Context -> C.Expr InferType -> A.Pattern -> C.Expr InferType -> C.Expr InferType -> Lower (C.Expr InferType)
matchPattern context receiver source success fallback = case A.nodeValue source of
  A.Bind binder -> do
    let reference = LocalRef (fst (A.nodeValue binder))
    case C.formOf receiver of
      _ | reference `Set.member` boundValues context -> pure success
      C.Var actual [] | actual == reference -> pure success
      _ -> do
        binding <- monoBinding binder reference receiver
        makeExpression source (C.typeOf success) (C.Let binding success)
  A.Wildcard -> pure success
  A.AnnotatedPattern pattern' _ -> matchPattern context receiver pattern' success fallback
  A.OpenPattern _ pattern' -> matchPattern context receiver pattern' success fallback
  A.LiteralPattern literal -> literalCase literal
  A.NegatedPattern pattern' -> case A.nodeValue pattern' of
    A.LiteralPattern (L.IntegerLiteral value) -> literalCase (L.IntegerLiteral ("-" <> value))
    A.LiteralPattern (L.FloatLiteral value) -> literalCase (L.FloatLiteral ("-" <> value))
    _ -> failure source "invalid checked negative pattern"
  A.UnitPattern -> constructorCase C.UnitConstructor [] [] success
  A.ConstructorPattern ident fields -> do
    (scheme, _) <- constructorInfo context source (C.DataConstructor ident)
    recorded <- lift (Infer (gets (Map.findWithDefault [] (A.nodeId source) . checkedInstantiations)))
    arguments <- mapM (resolved context) recorded
    let instantiated = S.apply (binderSubstitution (quantifiers scheme) arguments) (schemeType scheme)
        types = fst (splitFunctions instantiated)
    dictionaries <- forM (zip [0 ..] (schemePredicates scheme)) $ \(index, _) -> patternGiven context source (A.nodeId source, index)
    binders <- sequence [freshBinder field "$field" C.ValueBinder ty | (field, ty) <- zip fields types]
    nested <- foldM (\body (field, binder) -> binderUse field binder >>= \value -> matchPattern context value field body fallback) success (reverse (zip fields binders))
    opened <- lift (Infer (gets (Map.findWithDefault [] (A.nodeId source) . openedWitnesses)))
    if null opened
      then constructorCase (C.DataConstructor ident) arguments (dictionaries ++ binders) nested
      else do
        quantified <- forM opened $ \witness -> do
          ident' <- BoundId <$> lift freshId
          kind <- either (const (failure source "invalid hidden witness kind")) pure (kindOf witness)
          binder <- generated source "existential witness" (Quantifier ident' "$witness" kind)
          pure (witness, binder)
        let abstraction = S.fromBindings [(v, Variable (Bound (quantifierId (C.nodeValue binder))) (quantifierKind (C.nodeValue binder))) | (Variable v _, binder) <- quantified]
            abstractArguments = map (S.apply abstraction) arguments
            abstractBinders = map (fmap (fmap (S.apply abstraction))) (dictionaries ++ binders)
        alternative <- generated source "existential constructor pattern" (C.OpenConstructorTest (map snd quantified) (C.DataConstructor ident) abstractArguments abstractBinders, fmap (fmap (S.apply abstraction)) nested)
        makeExpression source (C.typeOf success) (C.Case receiver [alternative] fallback)
  A.ProductPattern fields -> productPattern receiver fields success
  A.ListPattern fields -> listPattern receiver fields success
  where
    literalCase literal = do
      alternative <- generated source "literal pattern" (C.LiteralTest literal, success)
      makeExpression source (C.typeOf success) (C.Case receiver [alternative] fallback)
    constructorCase constructor arguments binders body = do
      alternative <- generated source "constructor pattern" (C.ConstructorTest constructor arguments binders, body)
      makeExpression source (C.typeOf success) (C.Case receiver [alternative] fallback)
    productPattern value patterns body = case patterns of
      [] -> do
        alternative <- generated source "unit pattern" (C.ConstructorTest C.UnitConstructor [] [], body)
        makeExpression source (C.typeOf body) (C.Case value [alternative] fallback)
      [single] -> matchPattern context value single body fallback
      first : rest -> case C.typeOf value of
        Application (Application (Constructor (IntrinsicId ProductType) _) left) right -> do
          firstBinder <- freshBinder first "$first" C.ValueBinder left
          restBinder <- freshBinder source "$rest" C.ValueBinder right
          firstValue <- binderUse first firstBinder
          restValue <- binderUse source restBinder
          tailBody <- productPattern restValue rest body
          fullBody <- matchPattern context firstValue first tailBody fallback
          alternative <- generated source "product pattern" (C.ConstructorTest C.PairConstructor [left, right] [firstBinder, restBinder], fullBody)
          makeExpression source (C.typeOf body) (C.Case value [alternative] fallback)
        _ -> failure source "product pattern has no product type"
    listPattern value patterns body = case C.typeOf value of
      Application (Constructor (IntrinsicId ListType) _) element -> do
        (constructor, binders, branch) <- case patterns of
          [] -> pure (IntrinsicId NilConstructor, [], body)
          first : rest -> do
            firstBinder <- freshBinder first "$head" C.ValueBinder element
            restBinder <- freshBinder source "$tail" C.ValueBinder (list element)
            firstValue <- binderUse first firstBinder
            restValue <- binderUse source restBinder
            tailBody <- listPattern restValue rest body
            fullBody <- matchPattern context firstValue first tailBody fallback
            pure (IntrinsicId ConsConstructor, [firstBinder, restBinder], fullBody)
        alternative <- generated source "list pattern" (C.ConstructorTest (C.DataConstructor constructor) [element] binders, branch)
        makeExpression source (C.typeOf body) (C.Case value [alternative] fallback)
      _ -> failure source "list pattern has no list type"

splitFunctions :: InferType -> ([InferType], InferType)
splitFunctions ty = case functionParts ty of Nothing -> ([], ty); Just (input, output) -> let (rest, result) = splitFunctions output in (input : rest, result)

recordDescriptor :: Context -> A.Node a -> InferType -> Lower (GlobalId, [InferType], C.RecordDescriptor InferType)
recordDescriptor context source ty = case spine ty of
  (Constructor owner _, arguments) -> case Map.lookup owner (recordDeclarations (declarations context)) of
    Just descriptor -> pure (owner, arguments, C.nodeValue descriptor)
    Nothing -> failure source "record type has no descriptor"
  _ -> failure source "record receiver is unresolved"
  where
    spine = go []
    go arguments (Application f x) = go (x : arguments) f
    go arguments base = (base, arguments)

recordConstruction :: Context -> A.Expr -> GlobalId -> [A.FieldAssignment] -> Lower (C.Expr InferType)
recordConstruction context source _ fields = do
  ty <- nodeType context source
  (_, _, descriptor) <- recordDescriptor context source ty
  recorded <- lift (Infer (gets (Map.findWithDefault [] (A.nodeId source) . checkedInstantiations)))
  arguments <- mapM (resolved context) recorded
  (scheme, _) <- constructorInfo context source (C.recordConstructor descriptor)
  let substitution' = binderSubstitution (quantifiers scheme) arguments
  dictionaries <- mapM (evidence context source . fmap (S.apply substitution')) (schemePredicates scheme)
  withFields context fields Map.empty $ \values -> do
    ordered <- forM [0 .. length (C.recordFields descriptor) - 1] $ \index -> maybe (failure source "record construction is missing a checked field") pure (Map.lookup index values)
    makeExpression source ty (C.Construct (C.recordConstructor descriptor) arguments (dictionaries ++ ordered))

recordUpdate :: Context -> A.Expr -> A.Expr -> [A.FieldAssignment] -> Lower (C.Expr InferType)
recordUpdate context source receiver fields = do
  value <- expression context receiver
  (owner, arguments, descriptor) <- recordDescriptor context source (C.typeOf value)
  letValue receiver value $ \reference -> withFields context fields Map.empty $ \replacements -> do
    ordered <- forM (zip [0 ..] (C.recordFields descriptor)) $ \(index, field) -> case Map.lookup index replacements of
      Just replacement -> pure replacement
      Nothing -> do
        let scheme = snd (C.nodeValue field)
            selected = S.apply (binderSubstitution (quantifiers scheme) arguments) (schemeType scheme)
        case functionParts selected of
          Just (_, ty) -> makeExpression receiver ty (C.SelectField reference (C.FieldId owner index))
          Nothing -> failure receiver "record field has an invalid selector scheme"
    makeExpression source (C.typeOf reference) (C.Construct (C.recordConstructor descriptor) arguments ordered)

withFields :: Context -> [A.FieldAssignment] -> Map Int (C.Expr InferType) -> (Map Int (C.Expr InferType) -> Lower (C.Expr InferType)) -> Lower (C.Expr InferType)
withFields _ [] values continuation = continuation values
withFields context (field : rest) values continuation = do
  let (_, body) = A.nodeValue field
  value <- expression context body
  C.FieldId _ index <- fieldId field
  letValue field value $ \reference -> withFields context rest (Map.insert index reference values) continuation

lowerStatements :: Context -> [A.Statement] -> Lower (C.Expr InferType) -> Lower (C.Expr InferType)
lowerStatements _ [] continuation = continuation
lowerStatements context (statement : rest) continuation = case A.nodeValue statement of
  A.Effect body -> do
    value <- expression context body
    letValue statement value (\_ -> lowerStatements context rest continuation)
  A.BindStatement group -> lowerGroup context group (lowerStatements context rest continuation)

lowerGroup :: Context -> A.BindingGroup -> Lower (C.Expr InferType) -> Lower (C.Expr InferType)
lowerGroup context group continuation = case schedule group of
  Left _ -> case A.declarations group of source : _ -> failure source "invalid source dependency group"; [] -> continuation
  Right components -> foldr component continuation components
  where
    component (Acyclic source) body = case A.nodeValue source of
      A.ValueDefinition {} -> do
        binding <- lowerBinding context source
        result <- body
        makeExpression source (C.typeOf result) (C.Let binding result)
      A.PatternDefinition pattern' rhs -> lowerPatternBinding context source pattern' rhs body
      _ -> body
    component (Cyclic sources) body = do
      bindings <- traverse (lowerBinding context) sources
      result <- body
      makeExpression (NE.head sources) (C.typeOf result) (C.LetRec bindings result)

lowerTop :: Context -> A.BindingGroup -> Lower [C.BindingGroup InferType]
lowerTop context group = case schedule group of
  Left _ -> case A.declarations group of source : _ -> failure source "invalid module dependency group"; [] -> pure []
  Right components -> fmap concat $ forM components $ \component -> case component of
    Acyclic source -> case A.nodeValue source of
      A.ValueDefinition {} -> (: []) . C.NonRecursive <$> lowerBinding context source
      A.PatternDefinition pattern' body -> map C.NonRecursive <$> lowerTopPatternBinding context source pattern' body
      _ -> pure []
    Cyclic sources -> (: []) . C.Recursive <$> traverse (lowerBinding context) sources

-- Top-level pattern variables occupy ordinary module initialization slots. A
-- shared payload evaluates and matches the RHS once, including all-wildcard
-- patterns; outward aliases retain independent polymorphic instantiations.
lowerTopPatternBinding :: Context -> A.Declaration -> A.Pattern -> A.Expr -> Lower [C.Binding InferType]
lowerTopPatternBinding context source pattern' rhs = do
  scheme <- declarationScheme context source
  inner <- withMapping context source
  (withEvidence, parameters) <- evidenceParameters inner source (schemePredicates scheme)
  value <- expression withEvidence rhs
  let binders = patternBinders pattern'
  values <- forM binders $ \binder -> do
    ty <- nodeType inner binder
    makeExpression binder ty (C.Var (LocalRef (fst (A.nodeValue binder))) [])
  packed <- productExpression pattern' values
  failed <- makeExpression pattern' (C.typeOf packed) C.Fail
  matched <- letValue source value $ \reference -> matchPattern withEvidence reference pattern' packed failed
  payload <- freshBinder source "$pattern" C.ValueBinder (C.typeOf packed)
  let payloadScheme = evidenceScheme (declarations context) scheme {schemeType = C.typeOf packed}
  payloadBody <- abstractEvidence source parameters matched >>= closeInternal source
  payloadBinding <- generated source "top-level pattern initializer" (C.Binding (C.binderReference payload) payloadScheme payloadBody (C.BindingFacts 0 (initializerExpansiveOrigin source)))
  aliases <- forM (zip [0 ..] binders) $ \(index, binder) -> do
    let reference = LocalRef (fst (A.nodeValue binder))
    ownScheme <- maybe (failure binder "pattern variable has no checked scheme") (traverse (resolved context)) (Map.lookup reference (schemes context))
    let owned = Set.fromList (map quantifierId (quantifiers ownScheme))
    arguments <- forM (quantifiers payloadScheme) $ \q ->
      if quantifierId q `Set.member` owned
        then pure (Variable (Bound (quantifierId q)) (quantifierKind q))
        else lift (fresh (A.nodeSpan binder) (quantifierKind q))
    let instantiated = S.apply (binderSubstitution (quantifiers payloadScheme) arguments) (schemeType payloadScheme)
    receiver <- makeExpression binder instantiated (C.Var (C.binderReference payload) arguments)
    selected <- selectProduct binder index (length binders) receiver >>= closeInternal binder
    generated binder "top-level pattern variable" (C.Binding reference ownScheme selected (C.BindingFacts 0 Nothing))
  pure (payloadBinding : aliases)

lowerBinding :: Context -> A.Declaration -> Lower (C.Binding InferType)
lowerBinding context source = case A.nodeValue source of
  A.ValueDefinition reference _ _ -> do
    scheme <- declarationScheme context source
    inner <- withMapping context source
    (withEvidence, binders) <- evidenceParameters inner source (schemePredicates scheme)
    body <- valueBody withEvidence source (schemeType scheme)
    qualified <- abstractEvidence source binders body
    closed <- closeInternal source qualified
    generated source "value binding" (C.Binding reference (evidenceScheme (declarations context) scheme) closed (C.BindingFacts (writtenArity source) (initializerExpansiveOrigin source)))
  _ -> failure source "recursive group contains a non-value declaration"

declarationScheme :: Context -> A.Node a -> Lower (Scheme InferType)
declarationScheme context source = do
  found <- lift (Infer (gets (Map.lookup (A.nodeId source) . checkedDeclarations)))
  maybe (failure source "declaration has no checked scheme") (traverse (resolved context)) found

writtenArity :: A.Declaration -> Int
writtenArity source = case A.nodeValue source of A.ValueDefinition _ _ (A.ClausesBody arity _) -> arity; _ -> 0

evidenceParameters :: Context -> A.Node a -> [Predicate InferType] -> Lower (Context, [C.Binder InferType])
evidenceParameters context source predicates = do
  binders <- mapM (freshBinder source "$dictionary" C.EvidenceBinder . dictionaryType (declarations context)) predicates
  pure (context {givens = zip predicates binders ++ givens context}, binders)

abstractEvidence :: A.Node a -> [C.Binder InferType] -> C.Expr InferType -> Lower (C.Expr InferType)
abstractEvidence source binders body = foldM (\inner binder -> makeExpression source (function (C.binderType binder) (C.typeOf inner)) (C.Lambda binder inner)) body (reverse binders)

valueBody :: Context -> A.Declaration -> InferType -> Lower (C.Expr InferType)
valueBody context source ty = case A.nodeValue source of
  A.ValueDefinition _ _ (A.BuiltinBody key) -> case primitiveFromKey key >>= specializePrimitive (builtinTypeAssociations (declarations context)) of
    Nothing -> failure source "builtin has no lowering contract"
    Just builtin -> do
      dictionaries <- case P.exceptionTrait builtin of
        Nothing -> pure []
        Just owner -> case [binder | (predicate, binder) <- givens context, predicateTrait predicate == owner] of
          binder : _ -> pure <$> binderUse source binder
          [] -> failure source "exception primitive requires its dictionary parameter"
      etaExpand source (P.primitiveArity builtin - length dictionaries) ty (\arguments result -> makeExpression source result (C.Primitive builtin (dictionaries ++ arguments)))
  A.ValueDefinition _ _ (A.ClausesBody _ clauses) -> do
    fallback <- makeExpression source ty C.Fail
    foldM clause fallback (reverse (NE.toList clauses))
  _ -> failure source "value body expected"
  where
    clause fallback node = parameters context [] ty (A.clausePatterns (A.nodeValue node))
      where
        parameters inner supplied current patterns = case patterns of
          [] -> lowerGroup inner (A.clauseWhere (A.nodeValue node)) (expression inner (A.clauseBody (A.nodeValue node)))
          pattern' : rest -> case arrowParts current of
            Nothing -> failure node "written parameters exceed checked function arity"
            Just (mode, input, output) -> do
              let lazyBinding = if mode == NameArrow then undemandingPattern pattern' else Nothing
              binder <- case lazyBinding of
                Just (Just named) -> pure (sourceBinder named (C.parameterType mode input))
                _ -> freshBinder pattern' "$parameter" C.ValueBinder (C.parameterType mode input)
              let extended = maybe inner (bindLazyPattern inner binder) lazyBinding
                  supplied' = supplied ++ [(mode, binder)]
                  argument (StrictArrow, parameter) = binderUse node parameter
                  argument (NameArrow, parameter) = demand node parameter
              reference <- case mode of StrictArrow -> binderUse pattern' binder; NameArrow -> demand pattern' binder
              success <- parameters extended supplied' output rest
              arguments <- mapM argument supplied'
              onFailure <- foldM (apply node) fallback arguments
              match <- case lazyBinding of
                Just _ -> pure success
                Nothing -> matchPattern inner reference pattern' success onFailure
              makeExpression node current (C.Lambda binder match)

-- These variables are local to the derivation, e.g. the ignored argument in
-- const 1 (x -> x). They are erased binders and cannot change the result scheme.
closeInternal :: A.Node a -> C.Expr InferType -> Lower (C.Expr InferType)
closeInternal source body = do
  checked <- traverse (traverse (lift . zonk)) body
  let kinds = variableKinds (foldr (:) [] (C.nodeValue checked))
      resultVariables = freeVariables (C.typeOf checked)
      variables = [(v, kind) | (v@(Meta _), kind) <- Map.toList kinds, v `Set.notMember` resultVariables]
  quantified <- forM variables $ \(variable, kind) -> do
    ident <- BoundId <$> lift freshId
    node <- generated source "internal type" (Quantifier ident "$internal" kind)
    pure (variable, node)
  let substitution' = S.fromBindings [(variable, Variable (Bound (quantifierId (C.nodeValue node))) (quantifierKind (C.nodeValue node))) | (variable, node) <- quantified]
      closed = fmap (fmap (S.apply substitution')) checked
      holes = Set.fromList [ident | hole <- C.expressionHoles checked, let (ident, _) = C.nodeValue hole]
  lift (Infer (modify' (\s -> s {checkedGoals = Map.mapWithKey (\ident goal -> if ident `Set.member` holes then fmap (fmap (S.apply substitution')) goal else goal) (checkedGoals s)})))
  if null quantified then pure closed else makeExpression source (C.typeOf closed) (C.ScopeTypes (map snd quantified) closed)

lowerPatternBinding :: Context -> A.Declaration -> A.Pattern -> A.Expr -> Lower (C.Expr InferType) -> Lower (C.Expr InferType)
lowerPatternBinding context source pattern' rhs continuation = do
  scheme <- declarationScheme context source
  inner <- withMapping context source
  (withEvidence, parameters) <- evidenceParameters inner source (schemePredicates scheme)
  value <- expression withEvidence rhs
  if null (quantifiers scheme)
    then letValue source value $ \reference -> do
      body <- continuation
      failed <- makeExpression pattern' (C.typeOf body) C.Fail
      matchPattern inner reference pattern' body failed
    else do
      -- Match once inside the shared polymorphic initializer. Each outward
      -- binding selects its component at its independently instantiated type.
      let binders = patternBinders pattern'
      values <- forM binders $ \binder -> do
        ty <- nodeType inner binder
        makeExpression binder ty (C.Var (LocalRef (fst (A.nodeValue binder))) [])
      packed <- productExpression pattern' values
      failed <- makeExpression pattern' (C.typeOf packed) C.Fail
      matched <- letValue source value $ \reference -> matchPattern withEvidence reference pattern' packed failed
      payload <- freshBinder source "$pattern" C.ValueBinder (C.typeOf packed)
      let payloadScheme = evidenceScheme (declarations context) scheme {schemeType = C.typeOf packed}
      payloadBody <- abstractEvidence source parameters matched >>= closeInternal source
      payloadBinding <- generated source "polymorphic pattern initializer" (C.Binding (C.binderReference payload) payloadScheme payloadBody (C.BindingFacts 0 Nothing))
      aliases <- forM (zip [0 ..] binders) $ \(index, binder) -> do
        let reference = LocalRef (fst (A.nodeValue binder))
        ownScheme <- maybe (failure binder "pattern variable has no checked scheme") (traverse (resolved context)) (Map.lookup reference (schemes context))
        let owned = Set.fromList (map quantifierId (quantifiers ownScheme))
        arguments <- forM (quantifiers payloadScheme) $ \q ->
          if quantifierId q `Set.member` owned
            then pure (Variable (Bound (quantifierId q)) (quantifierKind q))
            else lift (fresh (A.nodeSpan binder) (quantifierKind q))
        let instantiated = S.apply (binderSubstitution (quantifiers payloadScheme) arguments) (schemeType payloadScheme)
        receiver <- makeExpression binder instantiated (C.Var (C.binderReference payload) arguments)
        selected <- selectProduct binder index (length binders) receiver >>= closeInternal binder
        generated binder "polymorphic pattern variable" (C.Binding reference ownScheme selected (C.BindingFacts 0 Nothing))
      body <- continuation
      foldM (\rest binding -> makeExpression source (C.typeOf rest) (C.Let binding rest)) body (reverse (payloadBinding : aliases))

patternBinders :: A.Pattern -> [A.Binder]
patternBinders source = case A.nodeValue source of
  A.Bind binder -> [binder]
  A.OpenPattern _ body -> patternBinders body
  A.ConstructorPattern _ patterns -> concatMap patternBinders patterns
  A.ProductPattern patterns -> concatMap patternBinders patterns
  A.ListPattern patterns -> concatMap patternBinders patterns
  A.AnnotatedPattern pattern' _ -> patternBinders pattern'
  A.NegatedPattern pattern' -> patternBinders pattern'
  _ -> []

selectProduct :: A.Node a -> Int -> Int -> C.Expr InferType -> Lower (C.Expr InferType)
selectProduct source index count receiver
  | count == 1 && index == 0 = pure receiver
  | count > 1 = case C.typeOf receiver of
      Application (Application (Constructor (IntrinsicId ProductType) _) first) rest -> do
        firstBinder <- freshBinder source "$first" C.ValueBinder first
        restBinder <- freshBinder source "$rest" C.ValueBinder rest
        selected <- if index == 0 then binderUse source firstBinder else binderUse source restBinder >>= selectProduct source (index - 1) (count - 1)
        arm <- generated source "pattern component" (C.ConstructorTest C.PairConstructor [first, rest] [firstBinder, restBinder], selected)
        failed <- makeExpression source (C.typeOf selected) C.Fail
        makeExpression source (C.typeOf selected) (C.Case receiver [arm] failed)
      _ -> failure source "pattern payload has no product type"
  | otherwise = failure source "pattern component is out of range"

lowerImplementation :: Context -> A.Declaration -> ImplementationId -> Lower (C.Binding InferType)
lowerImplementation context source ident = do
  implementation <- maybe (failure source "implementation descriptor missing") (pure . C.nodeValue) (Map.lookup ident (implementationDeclarations (declarations context)))
  inner <- withMapping context source
  let head' = implementationHead implementation
      target = dictionaryType (declarations context) head'
      scheme = implementationScheme (declarations context) implementation
  (scoped, binders) <- evidenceParameters inner source (implementationContext implementation)
  trait <- maybe (failure source "implementation trait descriptor missing") (pure . C.nodeValue) (Map.lookup (predicateTrait head') (traitDeclarations (declarations context)))
  let ownerMapping = binderSubstitution [traitParameter trait] [predicateArgument head']
      superclasses = map (fmap (S.apply ownerMapping)) (traitSuperclasses trait)
  supers <- mapM (evidence scoped source) superclasses
  members <- forM (Map.keys (traitMethods trait)) $ \method -> do
    member <- maybe (failure source "implementation method missing") pure (Map.lookup method (implementationMembers implementation))
    memberScheme <- declarationScheme scoped member
    binder <- freshBinder member "$method" C.ValueBinder (schemeType (evidenceScheme (declarations context) memberScheme))
    pure (method, member, memberScheme, binder)
  let localMethods = Map.fromList [(method, (head', C.binderReference binder)) | (method, _, _, binder) <- members]
      memberScope = scoped {memberReferences = localMethods}
  lowered <- forM members $ \(_, member, memberScheme, binder) -> do
    memberContext <- withMapping memberScope member
    (withEvidence, parameters) <- evidenceParameters memberContext member (schemePredicates memberScheme)
    body <- valueBody withEvidence member (schemeType memberScheme)
    qualified <- abstractEvidence member parameters body >>= closeInternal member
    let coreScheme = evidenceScheme (declarations context) memberScheme
        arguments = [Variable (Bound (quantifierId q)) (quantifierKind q) | q <- quantifiers coreScheme]
    binding <- generated member "method initializer" (C.Binding (C.binderReference binder) coreScheme qualified (C.BindingFacts (writtenArity member) (initializerExpansiveOrigin member)))
    reference <- makeExpression member (schemeType coreScheme) (C.Var (C.binderReference binder) arguments)
    field <- generated member "dictionary method" (coreScheme, reference)
    pure (binding, field)
  ordered <- either throwError pure (scheduleBindings (map fst lowered))
  lift (mapM_ emit (initializationDiagnostics ordered))
  let withSupers [] values = do
        packed <-
          if traitException trait
            then do
              let arguments = typeArguments (predicateArgument head')
              tokens <- mapM (evidence scoped source . Predicate (predicateTrait head')) arguments
              makeExpression source target (C.ExceptionDictionary (predicateTrait head') (predicateArgument head') tokens values)
            else makeExpression source target (C.Dictionary (predicateTrait head') (predicateArgument head') values (map snd lowered))
        foldM (\rest group -> makeExpression source target (case group of C.NonRecursive binding -> C.Let binding rest; C.Recursive bindings -> C.LetRec bindings rest)) packed (reverse ordered)
      withSupers (value : rest) values = letValue source value (\reference -> withSupers rest (values ++ [reference]))
  dictionary <- withSupers supers []
  body <- abstractEvidence source binders dictionary >>= closeInternal source
  generated source "implementation dictionary" (C.Binding (implementationReference ident) scheme body (C.BindingFacts 0 Nothing))

typeArguments :: Type v -> [Type v]
typeArguments = go []
  where
    go arguments (Application f x) = go (x : arguments) f
    go arguments _ = arguments

-- Lazily allocate one evidence binder per unpacking site, shared by the body
-- and the constructor test even when the body is lowered first.
patternGiven :: Context -> A.Node a -> (NodeId, Int) -> Lower (C.Binder InferType)
patternGiven context source key' = do
  known <- lift (Infer (gets (Map.lookup key' . loweredPatternGivens)))
  case known of
    Just binder -> do
      let (ident, name, role, ty) = C.nodeValue binder
      checked <- resolved context ty
      pure (binder {C.nodeValue = (ident, name, role, checked)})
    Nothing -> do
      (origin, provenance, rawPredicate) <- lift (Infer (gets (Map.lookup key' . patternGivens))) >>= maybe (failure source "missing checked pattern evidence") pure
      predicate <- traverse (resolved context) rawPredicate
      let originNode = source {A.nodeSpan = origin, A.nodeOrigin = provenance}
      binder <- freshBinder originNode "$packageEvidence" C.EvidenceBinder (dictionaryType (declarations context) predicate)
      lift (Infer (modify' (\state -> state {loweredPatternGivens = Map.insert key' binder (loweredPatternGivens state)})))
      pure binder
