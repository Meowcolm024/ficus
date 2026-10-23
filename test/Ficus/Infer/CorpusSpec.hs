module Ficus.Infer.CorpusSpec (tests) where

import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Aeson (FromJSON (..), eitherDecodeFileStrict', withObject, (.!=), (.:), (.:?))
import Data.Char (isLower)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Ficus.Elaborate.Finalize qualified as F
import Ficus.Elaborate.Lower
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Check
import Ficus.Infer.Declaration
import Ficus.Infer.Monad
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Resolve
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Concrete qualified as Concrete
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Name
import Ficus.Syntax.Parser (parseModule)
import Ficus.Type
import Ficus.Util.Source
import System.Directory (listDirectory)
import System.FilePath (takeBaseName, takeExtension, (</>))
import Test.Tasty
import Test.Tasty.HUnit

root :: FilePath
root = "test/fixtures/semantics/type-checking"

data Expected = Expected T.Text [Int] [Expected] deriving (Show)

newtype ExpectedTypes = ExpectedTypes (Map.Map T.Text T.Text)

instance FromJSON ExpectedTypes where
  parseJSON = withObject "inferred types" $ \object -> ExpectedTypes <$> object .: "types"

instance FromJSON Expected where
  parseJSON = withObject "type diagnostic" $ \object -> Expected <$> object .: "kind" <*> object .: "span" <*> (object .:? "additionalDiagnostics" .!= [])

tests :: IO TestTree
tests = do
  let provider = fileProvider (ProviderConfig ["test/fixtures/support"] PreludeFromRoots)
      preludeId = ModuleId ("Prelude" :| [])
  resolved <- resolveSources fixtureConfig fixtureSugar provider [preludeId]
  prelude <- case Map.lookup preludeId (frontendModules resolved) of
    Nothing -> ioError (userError (show (frontendDiagnostics resolved)))
    Just tree -> pure tree
  let checked = inferModule emptyDeclarations prelude
      environment = (inferredDeclarations checked) {valueSignatures = Map.map (\scheme -> Signature scheme False (A.abstractSpan prelude)) (inferredValues checked)}
  paths <- sort . filter ((== ".ficus") . takeExtension) <$> listDirectory (root </> "positive")
  negatives <- eitherDecodeFileStrict' (root </> "expectations.json") >>= either (ioError . userError) pure
  positives <- eitherDecodeFileStrict' (root </> "positive-expectations.json") >>= either (ioError . userError) pure
  pure
    ( testGroup
        "type inference corpus"
        ( testCase "support Prelude" ((validateAbstract prelude @?= Right ()) >> assertInference checked >> assertElaboration checked prelude)
            : [ testCase path $ do
                  let owner = ModuleId (T.pack (takeBaseName path) :| [])
                      sources = fileProvider (ProviderConfig [root </> "positive", "test/fixtures/support"] PreludeFromRoots)
                  result <- resolveSources fixtureConfig fixtureSugar sources [owner]
                  assertBool (show (frontendDiagnostics result)) (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics result))
                  case Map.lookup owner (frontendModules result) of
                    Nothing -> assertFailure "fixture did not resolve"
                    Just tree -> do
                      validateAbstract tree @?= Right ()
                      let inferred = inferModule environment tree
                      assertInference inferred
                      assertElaboration inferred tree
                      case Map.lookup ("positive/" ++ path) positives of
                        Nothing -> pure ()
                        Just (ExpectedTypes expected) -> mapM_ (\(name, ty) -> assertScheme owner inferred name ty) (Map.toList expected)
              | path <- paths
              ]
            ++ [ negativeCase environment path expected
               | (path, expected) <- Map.toList negatives,
                 -- The resolver already rejects this fixture as InvalidTypeVariableScope.
                 path /= "negative/NamedPatternAnnotation.ficus"
               ]
        )
    )

negativeCase :: Declarations -> FilePath -> Expected -> TestTree
negativeCase environment path expected = testCase path $ do
  let owner = ModuleId (T.pack (takeBaseName path) :| [])
      provider = fileProvider (ProviderConfig [root </> "negative", "test/fixtures/support"] PreludeFromRoots)
  result <- resolveSources fixtureConfig fixtureSugar provider [owner]
  assertBool (show (frontendDiagnostics result)) (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics result))
  case Map.lookup owner (frontendModules result) of
    Nothing -> assertFailure "fixture did not resolve"
    Just tree -> do
      validateAbstract tree @?= Right ()
      let errors = diagnostics (inferenceState (inferModule environment tree))
          checkExpected (Expected kind coordinates more) = do
            let matching = [d | d <- errors, T.pack (show (E.diagnosticCode d)) == kind]
                location d = let span' = E.diagnosticSpan d in [line (start span'), column (start span'), line (end span'), column (end span')]
            assertBool (show errors) (any ((== coordinates) . location) matching)
            mapM_ checkExpected more
      checkExpected expected

assertInference :: Inference -> Assertion
assertInference checked = do
  filter ((== D.Error) . D.diagnosticSeverity . D.toDiagnostic) (diagnostics (inferenceState checked)) @?= []
  remainingWanteds checked @?= []
  Map.null (checkedGoals (inferenceState checked)) @?= True

assertElaboration :: Inference -> A.AbstractModule -> Assertion
assertElaboration checked tree = case lowerModule checked tree of
  (Left diagnostic, _) -> assertFailure (show diagnostic)
  (Right core, state) -> case fst (runInferFrom state (F.finalizeModule core)) of
    F.Incomplete _ diagnostics' -> assertFailure (show diagnostics')
    F.Complete accepted _ -> validateCore (validatedModule accepted) @?= []

-- Compare alpha-equivalent syntax trees using the real type parser, preserving
-- application/arrow precedence, predicates and explicit quantifier ordering.
data Shape = Name T.Text | TypeVariable Int | Apply Shape Shape | Qualified [(T.Text, Shape)] Shape deriving (Eq, Show)

assertScheme :: ModuleId -> Inference -> T.Text -> T.Text -> Assertion
assertScheme owner inferred name expected = case Map.lookup (GlobalRef (GlobalId owner ValueNS name)) (inferredValues inferred) of
  Nothing -> assertFailure ("missing inferred type for " ++ T.unpack name)
  Just scheme -> do
    let variable (Bound ident) = renderBound ident
        variable other = T.pack (show other)
        binder q = "{" <> renderBound (quantifierId q) <> "} -> "
        predicate p = renderConstructor (predicateTrait p) <> " " <> renderType variable (predicateArgument p)
        predicates = case schemePredicates scheme of
          [] -> ""
          [p] -> predicate p <> " => "
          ps -> "(" <> T.intercalate ", " (map predicate ps) <> ") => "
        actual = foldMap binder (explicitQuantifiers scheme) <> predicates <> renderType variable (schemeType scheme)
    case (signatureShape expected, signatureShape actual) of
      (Right wanted, Right found) -> assertEqual (T.unpack (name <> " : " <> actual)) wanted found
      other -> assertFailure (show other)

signatureShape :: T.Text -> Either T.Text (Int, Shape)
signatureShape source = do
  tree <- either (Left . T.pack . show) Right (parseModule "ExpectedType.ficus" ("expected : " <> source <> "\n"))
  case Concrete.moduleDeclarations tree of
    [declaration]
      | Concrete.TypeSignature _ signature <- Concrete.concrete declaration,
        Concrete.SignatureType qs body <- Concrete.concrete signature ->
          Right (length qs, evalState (mapM_ (\q -> let Concrete.Quantifier name _ = Concrete.concrete q in variableShape (Concrete.nameText name)) qs >> typeShape body) Map.empty)
    _ -> Left "expected one type signature"

variableShape :: T.Text -> State (Map.Map T.Text Int) Shape
variableShape name = do
  known <- get
  case Map.lookup name known of
    Just ident -> pure (TypeVariable ident)
    Nothing -> do
      let ident = Map.size known
      put (Map.insert name ident known)
      pure (TypeVariable ident)

typeShape :: Concrete.TypeExpr -> State (Map.Map T.Text Int) Shape
typeShape source = case Concrete.concrete source of
  Concrete.IdentT name -> case T.uncons (Concrete.nameText name) of
    Just (first, _) | isLower first -> variableShape (Concrete.nameText name)
    _ -> pure (Name (Concrete.nameText name))
  Concrete.DottedT names -> pure (Name (T.intercalate "." (map Concrete.nameText names)))
  Concrete.AppT f x -> Apply <$> typeShape f <*> typeShape x
  Concrete.OpAppT a op b -> binary (Concrete.nameText op) a b
  Concrete.ArrowT a b -> binary "(->)" a b
  Concrete.LazyArrowT a b -> binary "(~>)" a b
  Concrete.ProductT a b -> binary "(*)" a b
  Concrete.ConstrainedT predicates body -> Qualified <$> mapM (\p -> let Concrete.Constraint name argument = Concrete.concrete p in (Concrete.nameText name,) <$> typeShape argument) predicates <*> typeShape body
  Concrete.ParenT body -> typeShape body
  Concrete.ListT body -> Apply (Name "[]") <$> typeShape body
  Concrete.ListConstructor -> pure (Name "[]")
  Concrete.ProductConstructor -> pure (Name "(*)")
  Concrete.FunctionConstructor -> pure (Name "(->)")
  Concrete.LazyFunctionConstructor -> pure (Name "(~>)")
  where
    binary name a b = Apply <$> (Apply (Name name) <$> typeShape a) <*> typeShape b
