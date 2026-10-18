-- | Independent typed boundary checks. Structural validation permits diagnostic
-- holes; acceptance additionally requires complete, closed, hole-free Core.
module Ficus.Syntax.Core.Validate (ValidatedCore, validatedModule, validateCore, acceptCore) where

import Data.List (nub)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.Error.Type qualified as E
import Ficus.Syntax.Core
import Ficus.Syntax.Core.Intrinsic
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source

newtype ValidatedCore = ValidatedCore {validatedModule :: CoreModule CoreType} deriving (Eq, Show)

type Environment = Map Reference (Scheme CoreType)

type TypeScope = Map BoundId Kind

validateCore :: CoreModule CoreType -> [E.Diagnostic]
validateCore tree =
  checkOrigin (coreSpan tree) (coreOrigin tree)
    ++ concatMap (checkScheme tree Map.empty (coreSpan tree)) (Map.elems (coreImports tree))
    ++ concatMap checkConstructor (Map.elems (coreConstructors tree))
    ++ concatMap checkRecord (Map.elems (coreRecords tree))
    ++ concatMap checkDictionary (Map.toList (coreDictionaries tree))
    ++ snd (foldl checkGroup (coreImports tree, []) (coreBindings tree))
    ++ concatMap checkGoal (Map.toList (coreGoals tree))
  where
    checkConstructor descriptor =
      let value = nodeValue descriptor
          scheme = constructorScheme value
          (_, result) = splitArrows (schemeType scheme)
       in checkNode descriptor
            ++ checkScheme tree Map.empty (nodeSpan descriptor) scheme
            ++ require (nodeSpan descriptor) (constructorArity value == length (fst (splitArrows (schemeType scheme)))) "constructor arity differs from its scheme"
            ++ require (nodeSpan descriptor) (typeHead result == Just (constructorOwner value)) "constructor has the wrong nominal result"
    checkRecord descriptor = checkNode descriptor ++ concatMap (\field -> checkNode field ++ checkScheme tree Map.empty (nodeSpan field) (snd (nodeValue field))) (recordFields (nodeValue descriptor))
    checkDictionary (ident, descriptor) =
      let value = nodeValue descriptor
          parameter = dictionaryParameter value
          scope = Map.singleton (quantifierId parameter) (quantifierKind parameter)
          methods = dictionaryMethods value
          names = map (fst . nodeValue) methods
       in checkNode descriptor
            ++ require (nodeSpan descriptor) (Map.lookup ident (coreKinds tree) == Just (KindArrow (quantifierKind parameter) TypeKind)) "dictionary has the wrong constructor kind"
            ++ require (nodeSpan descriptor) (length names == length (nub names)) "duplicate dictionary method"
            ++ concatMap (\super -> checkNode super ++ checkType tree scope (nodeSpan super) (nodeValue super) ++ require (nodeSpan super) (maybe False (`Map.member` coreDictionaries tree) (typeHead (nodeValue super))) "superclass is not a dictionary type") (dictionarySuperclasses value)
            ++ concatMap (\method -> checkNode method ++ checkScheme tree scope (nodeSpan method) (snd (nodeValue method))) methods
    checkGroup (environment, errors) group =
      let bindings = groupBindings group
          extended = extendBindings bindings environment
          visible = case group of NonRecursive _ -> environment; Recursive _ -> extended
          cycleErrors = case group of NonRecursive _ -> []; Recursive bs -> checkRecursion (NE.toList bs)
          duplicateErrors = concatMap (\binding -> require (nodeSpan binding) (Map.notMember (bindingReference (nodeValue binding)) environment) "duplicate Core binding") bindings
          topLevelErrors = concatMap (\binding -> maybe [] (\origin -> invalid origin "expansive top-level initializer") (expansiveOrigin (bindingFacts (nodeValue binding)))) bindings
       in (extended, errors ++ duplicateErrors ++ topLevelErrors ++ cycleErrors ++ concatMap (checkBinding tree visible Map.empty) bindings)
    checkGoal (ident, goal) = checkNode goal ++ require (nodeSpan goal) (ident == goalIdentity (nodeValue goal)) "hole goal key disagrees with its identity"

acceptCore :: CoreModule CoreType -> Either [E.Diagnostic] ValidatedCore
acceptCore tree = case validateCore tree ++ incomplete of
  [] -> Right (ValidatedCore tree)
  errors -> Left errors
  where
    holes = concatMap (expressionHoles . bindingBody . nodeValue) (concatMap groupBindings (coreBindings tree))
    incomplete =
      [E.diagnostic E.ExpressionHole (nodeSpan hole) "an expression hole prevents Core acceptance" | hole <- holes]
        ++ [E.diagnostic E.InvalidCoreTree (coreSpan tree) "unresolved diagnostic type in accepted Core" | any hasDiagnostic tree]
    hasDiagnostic = any (\case DiagnosticVariable _ -> True; BoundVariable _ -> False)

checkBinding :: CoreModule CoreType -> Environment -> TypeScope -> Binding CoreType -> [E.Diagnostic]
checkBinding tree environment outer binding =
  let value = nodeValue binding
      scheme = bindingScheme value
      scope = outer `Map.union` quantifierScope scheme
   in checkNode binding
        ++ checkScheme tree outer (nodeSpan binding) scheme
        ++ require (nodeSpan binding) (writtenValueParameters (bindingFacts value) >= 0) "negative written arity"
        ++ sameType (nodeSpan binding) (schemeType scheme) (typeOf (bindingBody value))
        ++ checkExpression tree environment scope (bindingBody value)

checkExpression :: CoreModule CoreType -> Environment -> TypeScope -> Expr CoreType -> [E.Diagnostic]
checkExpression tree environment scope expression =
  checkNode expression ++ checkType tree scope location ty ++ require location (kindOf ty == Right TypeKind) "expression type is not of kind Type" ++ formErrors
  where
    location = nodeSpan expression
    ty = typeOf expression
    check = checkExpression tree environment scope
    same = sameType location
    formErrors = case formOf expression of
      Var reference arguments -> case Map.lookup reference environment of
        Nothing -> invalid location "unbound Core reference"
        Just scheme -> case instantiate scheme arguments of
          Left message -> invalid location message
          Right result -> concatMap (checkType tree scope location) arguments ++ same ty result
      Literal literal -> same ty (literalType literal)
      Hole ident -> case Map.lookup ident (coreGoals tree) of
        Nothing -> invalid location "hole has no goal snapshot"
        Just goal -> same ty (goalType (nodeValue goal)) ++ require location (nodeSpan goal == location) "hole and goal origins disagree"
      Lambda binder body ->
        checkBinder tree scope binder
          ++ require (nodeSpan binder) (Map.notMember (binderReference binder) environment) "duplicate lambda binder"
          ++ same ty (function (binderType binder) (typeOf body))
          ++ checkExpression tree (Map.insert (binderReference binder) (monomorphic (binderType binder)) environment) scope body
      Apply f x -> check f ++ check x ++ same (typeOf f) (function (typeOf x) ty)
      Let binding body ->
        require (nodeSpan binding) (Map.notMember (bindingReference (nodeValue binding)) environment) "duplicate let binder"
          ++ checkBinding tree environment scope binding
          ++ checkExpression tree (extendBindings [binding] environment) scope body
          ++ same ty (typeOf body)
      LetRec bindings body ->
        let bs = NE.toList bindings
            extended = extendBindings bs environment
         in checkRecursion bs ++ concatMap (checkBinding tree extended scope) bs ++ checkExpression tree extended scope body ++ same ty (typeOf body)
      Construct constructor arguments fields ->
        concatMap check fields
          ++ concatMap (checkType tree scope location) arguments
          ++ case lookupConstructor tree constructor arguments of
            Left message -> invalid location message
            Right (expected, result) -> checkOperands location expected fields ++ same ty result
      Case receiver alternatives fallback -> check receiver ++ check fallback ++ same ty (typeOf fallback) ++ concatMap (checkAlternative receiver) alternatives
      If arms fallback -> concatMap checkArm arms ++ maybe [] (\body -> check body ++ same ty (typeOf body)) fallback
      SelectField receiver (FieldId owner index) ->
        check receiver ++ case Map.lookup owner (coreRecords tree) of
          Nothing -> invalid location "unknown nominal record"
          Just record -> case drop index (recordFields (nodeValue record)) of
            field : _
              | index >= 0 ->
                  let (_, arguments) = applicationSpine (typeOf receiver)
                   in case instantiate (snd (nodeValue field)) arguments of
                        Left message -> invalid location message
                        Right fieldType -> same fieldType (function (typeOf receiver) ty)
            _ -> invalid location "field slot is out of range"
      Dictionary owner argument supers methods ->
        checkType tree scope location argument ++ concatMap check supers ++ case specializeDictionary tree owner argument of
          Left message -> invalid location message
          Right (result, expectedSupers, expectedMethods) ->
            same ty result
              ++ checkOperands location expectedSupers supers
              ++ require location (length methods == length expectedMethods) "dictionary method count differs from its layout"
              ++ concat (zipWith checkMethod expectedMethods methods)
      SelectMethod receiver owner index arguments ->
        check receiver ++ concatMap (checkType tree scope location) arguments ++ case dictionaryReceiver tree owner (typeOf receiver) of
          Left message -> invalid location message
          Right (_, methods) -> case slot index methods of
            Nothing -> invalid location "dictionary method slot is out of range"
            Just scheme -> case instantiate scheme arguments of
              Left message -> invalid location message
              Right result -> same ty result
      SelectSuperclass receiver owner index ->
        check receiver ++ case dictionaryReceiver tree owner (typeOf receiver) of
          Left message -> invalid location message
          Right (supers, _) -> case slot index supers of
            Nothing -> invalid location "superclass slot is out of range"
            Just result -> same ty result
      ScopeTypes binders body ->
        let qs = map nodeValue binders
            ids = map quantifierId qs
            extended = Map.fromList [(quantifierId q, quantifierKind q) | q <- qs] `Map.union` scope
         in concatMap checkNode binders
              ++ require location (length ids == length (nub ids) && all (`Map.notMember` scope) ids) "duplicate or capturing local type binder"
              ++ same ty (typeOf body)
              ++ checkExpression tree environment extended body
      Primitive primitiveId arguments ->
        let (expected, result) = primitiveSignature primitiveId
         in concatMap check arguments ++ checkOperands location expected arguments ++ same ty result
      Fail -> []
    checkMethod expected actual =
      let (scheme, body) = nodeValue actual
       in checkNode actual
            ++ checkScheme tree scope (nodeSpan actual) scheme
            ++ require (nodeSpan actual) (sameScheme expected scheme) "dictionary method scheme differs from its layout"
            ++ sameType (nodeSpan actual) (schemeType scheme) (typeOf body)
            ++ checkExpression tree environment (quantifierScope scheme `Map.union` scope) body
    checkArm arm = let (condition, body) = nodeValue arm in checkNode arm ++ check condition ++ check body ++ sameType (nodeSpan condition) (primitive BoolType) (typeOf condition) ++ same ty (typeOf body)
    checkAlternative receiver alternative =
      let (test, body) = nodeValue alternative
          (binders, errors) = case test of
            LiteralTest literal -> ([], sameType (nodeSpan alternative) (typeOf receiver) (literalType literal))
            ConstructorTest constructor arguments bs ->
              ( bs,
                concatMap (checkType tree scope (nodeSpan alternative)) arguments ++ case lookupConstructor tree constructor arguments of
                  Left message -> invalid (nodeSpan alternative) message
                  Right (fields, result) -> sameType (nodeSpan alternative) (typeOf receiver) result ++ require (nodeSpan alternative) (length fields == length bs) "case binder arity mismatch" ++ concat (zipWith (sameType (nodeSpan alternative)) fields (map binderType bs))
              )
          names = map binderReference binders
          extended = Map.fromList [(binderReference b, monomorphic (binderType b)) | b <- binders] `Map.union` environment
       in checkNode alternative
            ++ errors
            ++ require (nodeSpan alternative) (length names == length (nub names) && all (`Map.notMember` environment) names) "duplicate case binder"
            ++ concatMap (checkBinder tree scope) binders
            ++ checkExpression tree extended scope body
            ++ same ty (typeOf body)

checkBinder :: CoreModule CoreType -> TypeScope -> Binder CoreType -> [E.Diagnostic]
checkBinder tree scope binder = checkNode binder ++ checkType tree scope (nodeSpan binder) (binderType binder) ++ require (nodeSpan binder) (kindOf (binderType binder) == Right TypeKind) "binder type is not of kind Type"

checkScheme :: CoreModule CoreType -> TypeScope -> Span -> Scheme CoreType -> [E.Diagnostic]
checkScheme tree outer origin scheme =
  require origin (null (schemePredicates scheme)) "implicit trait constraints remain in Core"
    ++ require origin (length ids == length (nub ids) && all (`Map.notMember` outer) ids) "duplicate or capturing scheme quantifier"
    ++ checkType tree (outer `Map.union` quantifierScope scheme) origin (schemeType scheme)
    ++ require origin (kindOf (schemeType scheme) == Right TypeKind) "value scheme is not of kind Type"
  where
    ids = map quantifierId (quantifiers scheme)

quantifierScope :: Scheme ty -> TypeScope
quantifierScope scheme = Map.fromList [(quantifierId q, quantifierKind q) | q <- quantifiers scheme]

checkType :: CoreModule CoreType -> TypeScope -> Span -> CoreType -> [E.Diagnostic]
checkType tree scope origin ty = case ty of
  Variable (BoundVariable ident) kind -> require origin (Map.lookup ident scope == Just kind) "unbound type variable or inconsistent variable kind"
  Variable (DiagnosticVariable _) _ -> []
  Constructor gid kind -> case gid of
    IntrinsicId p -> require origin (p `elem` [IntType, FloatType, BoolType, CharType, StringType, UnitType, ListType, ProductType, FunctionType] && kind == primitiveKind p) "invalid intrinsic type or kind"
    _ -> require origin (Map.lookup gid (coreKinds tree) == Just kind) "unknown type constructor or kind"
  Application a b -> checkType tree scope origin a ++ checkType tree scope origin b ++ either (const (invalid origin "ill-kinded type application")) (const []) (kindOf ty)

instantiate :: Scheme CoreType -> [CoreType] -> Either Text CoreType
instantiate scheme arguments
  | length qs /= length arguments = Left "type argument count differs from scheme"
  | not (and (zipWith (\q t -> kindOf t == Right (quantifierKind q)) qs arguments)) = Left "type argument kind differs from scheme"
  | otherwise = Right (S.apply mapping (schemeType scheme))
  where
    qs = quantifiers scheme
    mapping = foldr (S.compose . uncurry S.singleton) S.empty [(BoundVariable (quantifierId q), t) | (q, t) <- zip qs arguments]

lookupConstructor :: CoreModule CoreType -> ConstructorId -> [CoreType] -> Either Text ([CoreType], CoreType)
lookupConstructor tree constructor arguments = do
  (scheme, arity) <- case constructorSignature constructor of
    Just entry -> Right entry
    Nothing -> case Map.lookup constructor (coreConstructors tree) of
      Just descriptor -> let d = nodeValue descriptor in Right (constructorScheme d, constructorArity d)
      Nothing -> Left "unknown Core constructor"
  ty <- instantiate scheme arguments
  pure (splitAtArity arity ty)

splitAtArity :: Int -> CoreType -> ([CoreType], CoreType)
splitAtArity n ty
  | n <= 0 = ([], ty)
  | otherwise = case functionParts ty of
      Nothing -> ([], ty)
      Just (input, output) -> let (rest, result) = splitAtArity (n - 1) output in (input : rest, result)

splitArrows :: CoreType -> ([CoreType], CoreType)
splitArrows ty = case functionParts ty of
  Nothing -> ([], ty)
  Just (a, b) -> let (arguments, result) = splitArrows b in (a : arguments, result)

applicationSpine :: Type v -> (Type v, [Type v])
applicationSpine = go []
  where
    go args (Application f x) = go (x : args) f
    go args ty = (ty, args)

typeHead :: Type v -> Maybe GlobalId
typeHead ty = case fst (applicationSpine ty) of Constructor gid _ -> Just gid; _ -> Nothing

slot :: Int -> [a] -> Maybe a
slot index _ | index < 0 = Nothing
slot index values = case drop index values of value : _ -> Just value; [] -> Nothing

specializeDictionary :: CoreModule CoreType -> GlobalId -> CoreType -> Either Text (CoreType, [CoreType], [Scheme CoreType])
specializeDictionary tree owner argument = case Map.lookup owner (coreDictionaries tree) of
  Nothing -> Left "unknown dictionary layout"
  Just descriptor ->
    let value = nodeValue descriptor
        parameter = dictionaryParameter value
        mapping = S.singleton (BoundVariable (quantifierId parameter)) argument
        result = Application (Constructor owner (KindArrow (quantifierKind parameter) TypeKind)) argument
     in if kindOf argument /= Right (quantifierKind parameter)
          then Left "dictionary parameter kind mismatch"
          else Right (result, map (S.apply mapping . nodeValue) (dictionarySuperclasses value), map (fmap (S.apply mapping) . snd . nodeValue) (dictionaryMethods value))

dictionaryReceiver :: CoreModule CoreType -> GlobalId -> CoreType -> Either Text ([CoreType], [Scheme CoreType])
dictionaryReceiver tree owner receiver = case applicationSpine receiver of
  (Constructor actual _, [argument]) | owner == actual -> do
    (expected, supers, methods) <- specializeDictionary tree owner argument
    if expected == receiver then Right (supers, methods) else Left "dictionary receiver has the wrong kind"
  _ -> Left "dictionary selection has the wrong receiver"

sameScheme :: Scheme CoreType -> Scheme CoreType -> Bool
sameScheme expected actual =
  length (explicitQuantifiers expected) == length (explicitQuantifiers actual)
    && map quantifierKind (quantifiers expected) == map quantifierKind (quantifiers actual)
    && null (schemePredicates expected)
    && null (schemePredicates actual)
    && S.apply mapping (schemeType expected) == schemeType actual
  where
    mapping = S.fromBindings [(BoundVariable (quantifierId a), Variable (BoundVariable (quantifierId b)) (quantifierKind b)) | (a, b) <- zip (quantifiers expected) (quantifiers actual)]

checkOperands :: Span -> [CoreType] -> [Expr CoreType] -> [E.Diagnostic]
checkOperands origin expected actual = require origin (length expected == length actual) "operation is not saturated" ++ concat (zipWith (\ty expression -> sameType (nodeSpan expression) ty (typeOf expression)) expected actual)

extendBindings :: [Binding CoreType] -> Environment -> Environment
extendBindings bindings environment = Map.fromList [(bindingReference b, bindingScheme b) | node <- bindings, let { b = nodeValue node }] `Map.union` environment

checkRecursion :: [Binding CoreType] -> [E.Diagnostic]
checkRecursion bindings =
  require anchor (length references == length (nub references)) "duplicate recursive binder"
    ++ concatMap (\binding -> maybe [] (\origin -> invalid origin "expansive recursive initializer") (expansiveOrigin (bindingFacts (nodeValue binding))) ++ unprotected False (bindingBody (nodeValue binding))) bindings
  where
    references = map (bindingReference . nodeValue) bindings
    anchor = case bindings of b : _ -> nodeSpan b; [] -> Span "<core>" (Position 1 1 0) (Position 1 1 0)
    unprotected delayed expression = case formOf expression of
      Var reference _ -> require (nodeSpan expression) (delayed || reference `notElem` references) "unprotected recursive reference"
      Lambda binder body -> unprotected (delayed || role binder == ValueBinder) body
      _ -> concatMap (unprotected delayed) (children expression)
    role binder = let (_, _, r, _) = nodeValue binder in r

checkNode :: Node a -> [E.Diagnostic]
checkNode node = checkOrigin (nodeSpan node) (nodeOrigin node)

checkOrigin :: Span -> Provenance -> [E.Diagnostic]
checkOrigin span' provenance = require span' (start span' <= end span' && parent == span') "invalid Core source provenance"
  where
    parent = case provenance of SourceOrigin origin -> origin; GeneratedOrigin _ origin -> origin

sameType :: Span -> CoreType -> CoreType -> [E.Diagnostic]
sameType origin expected actual = require origin (expected == actual) "Core type mismatch"

require :: Span -> Bool -> Text -> [E.Diagnostic]
require _ True _ = []
require origin False message = invalid origin message

invalid :: Span -> Text -> [E.Diagnostic]
invalid origin message = [E.diagnostic E.InvalidCoreTree origin message]
