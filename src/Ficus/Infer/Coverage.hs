-- | Pattern-matrix usefulness. Guards never contribute coverage, and nominal
-- constructor families come from checked declarations rather than spelling.
module Ficus.Infer.Coverage (checkCoverage, patternTotal) where

import Control.Monad (foldM, forM, unless, when)
import Data.Map.Strict qualified as Map
import Ficus.Error.Type qualified as E
import Ficus.Infer.Declaration
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Infer.Unify qualified as U
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Intrinsic (constructorSignature)
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source

data Pattern = Any | Tagged C.ConstructorId [Pattern] | Literal L.Literal deriving (Eq, Show)

checkCoverage :: Declarations -> Span -> [InferType] -> [([A.Pattern], Bool, Span)] -> Infer ()
checkCoverage environment origin types clauses = do
  matrix <- foldM add [] clauses
  incomplete <- useful environment origin types matrix (replicate (length types) Any)
  when incomplete (emit (E.diagnostic E.NonExhaustiveMatch origin "patterns do not cover every possible value"))
  where
    add matrix (patterns, guarded, location) = do
      let row = map normalize patterns
      reachable <- useful environment location types matrix row
      unless reachable (emit (E.diagnostic E.RedundantClause location "earlier clauses already cover this pattern"))
      pure (if guarded then matrix else matrix ++ [row])

patternTotal :: Declarations -> InferType -> A.Pattern -> Infer Bool
patternTotal environment ty source = not <$> useful environment (A.nodeSpan source) [ty] [[normalize source]] [Any]

useful :: Declarations -> Span -> [InferType] -> [[Pattern]] -> [Pattern] -> Infer Bool
useful _ _ _ [] _ = pure True
useful _ _ _ matrix row | any (\patterns -> length patterns == length row && all (== Any) patterns) matrix = pure False
useful _ _ [] _ [] = pure False
useful environment origin (ty : types) matrix (pattern' : rest) = case pattern' of
  Literal literal -> useful environment origin types (specializeLiteral literal matrix) rest
  Tagged constructor fields -> do
    alternatives <- universe environment origin ty
    case lookup constructor alternatives of
      Nothing -> pure True
      Just fieldTypes -> useful environment origin (fieldTypes ++ types) (specialize constructor (length fields) matrix) (fields ++ rest)
  Any -> do
    alternatives <- universe environment origin ty
    let present = [constructor | Tagged constructor _ : _ <- matrix]
        complete = not (null alternatives) && all ((`elem` present) . fst) alternatives
    if complete
      then or <$> forM alternatives (\(constructor, fields) -> useful environment origin (fields ++ types) (specialize constructor (length fields) matrix) (replicate (length fields) Any ++ rest))
      else useful environment origin types [tail' | Any : tail' <- matrix] rest
useful _ _ _ _ _ = pure True

specialize :: C.ConstructorId -> Int -> [[Pattern]] -> [[Pattern]]
specialize constructor arity matrix = concatMap row matrix
  where
    row (Any : rest) = [replicate arity Any ++ rest]
    row (Tagged actual fields : rest) | actual == constructor = [fields ++ rest]
    row _ = []

specializeLiteral :: L.Literal -> [[Pattern]] -> [[Pattern]]
specializeLiteral literal matrix = [rest | pattern' : rest <- matrix, pattern' == Any || pattern' == Literal literal]

universe :: Declarations -> Span -> InferType -> Infer [(C.ConstructorId, [InferType])]
universe environment origin unknown = do
  receiver <- zonk unknown
  let owner = typeHead receiver
      nominal = [(ident, C.constructorScheme (C.nodeValue node)) | (ident, node) <- Map.toList (constructorDeclarations environment), Just (C.constructorOwner (C.nodeValue node)) == owner]
      builtin = case owner of
        Just (IntrinsicId BoolType) -> [C.DataConstructor (IntrinsicId TrueConstructor), C.DataConstructor (IntrinsicId FalseConstructor)]
        Just (IntrinsicId ListType) -> [C.DataConstructor (IntrinsicId NilConstructor), C.DataConstructor (IntrinsicId ConsConstructor)]
        Just (IntrinsicId ProductType) -> [C.PairConstructor]
        Just (IntrinsicId UnitType) -> [C.UnitConstructor]
        _ -> []
      intrinsic = [(ident, fmap (fmap convert) scheme) | ident <- builtin, Just (scheme, _) <- [constructorSignature ident]]
  fmap concat $ forM (nominal ++ intrinsic) $ \(ident, scheme) -> do
    (ty, _, _) <- instantiate origin scheme
    let (fields, result) = split ty
    pure $ case U.match result receiver of
      Left _ -> []
      Right mapping -> [(ident, map (S.apply mapping) fields)]
  where
    convert (C.BoundVariable q) = Bound q
    convert (C.DiagnosticVariable (C.DiagnosticMetaId n)) = Meta (MetaId n)
    typeHead (Constructor ident _) = Just ident
    typeHead (Application f _) = typeHead f
    typeHead (Variable _ _) = Nothing
    split ty = case functionParts ty of Nothing -> ([], ty); Just (input, output) -> let (rest, result) = split output in (input : rest, result)

normalize :: A.Pattern -> Pattern
normalize source = case A.nodeValue source of
  A.Bind _ -> Any
  A.Wildcard -> Any
  A.ConstructorPattern ident fields -> Tagged (C.DataConstructor ident) (map normalize fields)
  A.LiteralPattern literal -> Literal literal
  A.ProductPattern fields -> productPattern (map normalize fields)
  A.ListPattern fields -> foldr (\field rest -> Tagged (C.DataConstructor (IntrinsicId ConsConstructor)) [normalize field, rest]) (Tagged (C.DataConstructor (IntrinsicId NilConstructor)) []) fields
  A.UnitPattern -> Tagged C.UnitConstructor []
  A.AnnotatedPattern pattern' _ -> normalize pattern'
  A.NegatedPattern pattern' -> case normalize pattern' of
    Literal (L.IntegerLiteral n) -> Literal (L.IntegerLiteral ("-" <> n))
    Literal (L.FloatLiteral n) -> Literal (L.FloatLiteral ("-" <> n))
    other -> other
  where
    productPattern [] = Tagged C.UnitConstructor []
    productPattern [single] = single
    productPattern (first : rest) = Tagged C.PairConstructor [first, productPattern rest]
