module Ficus.Infer.RestrictionSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Error.Type qualified as E
import Ficus.Infer.Initialization
import Ficus.Infer.Restriction
import Ficus.Resolve
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Name
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

withDeclarations :: Text -> ([A.Declaration] -> Assertion) -> Assertion
withDeclarations source = withResolvedDeclarations ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source)

withResolvedDeclarations :: Text -> ([A.Declaration] -> Assertion) -> Assertion
withResolvedDeclarations source assertion = do
  let owner = ModuleId ("Restrictions" :| [])
      provider requested
        | requested == owner = pure (Right (Source "Restrictions.ficus" source))
        | otherwise = fileProvider (ProviderConfig ["test/fixtures/support"] PreludeFromRoots) requested
  result <- resolveSources fixtureConfig fixtureSugar provider [owner]
  frontendDiagnostics result @?= []
  case Map.lookup owner (frontendModules result) of
    Nothing -> assertFailure "expected resolved fixture"
    Just tree -> do
      validateAbstract tree @?= Right ()
      assertion (A.declarations (A.abstractDeclarations tree))

valueDeclarations :: [A.Declaration] -> [A.Declaration]
valueDeclarations = filter (\d -> case A.nodeValue d of A.ValueDefinition {} -> True; A.PatternDefinition {} -> True; _ -> False)

tests :: TestTree
tests =
  testGroup
    "source initialization restrictions"
    [ testCase "non-expansive values include constructors and aggregates" $
        withDeclarations "type Box a = Box a\nid x = x\nbox = Box id\npair = (id, [id])\nnegative = -1\n" $ \declarations ->
          map initializerExpansiveOrigin declarations @?= replicate (length declarations) Nothing,
      testCase "calls, partial applications, multi-expression blocks, if, matches, and projection are expansive" $
        withDeclarations "type Point = { x : Int }\nid x = x\ncall = id 1\npartial = id id\nblock = { 1; 2 }\nbranch = if { _ -> 1 }\nmatch = with 1 { _ -> 1 }\npoint = Point 1\nfield = point.x\n" $ \declarations -> do
          let origins = [line (start origin) | Just origin <- map initializerExpansiveOrigin declarations]
          origins @?= [4, 5, 6, 7, 8, 10],
      testCase "single-expression blocks inherit the expression's classification" $
        withDeclarations "id x = x\nvalue = { 1 }\nidentity = { x -> x }\ncall = { id 1 }\nnested = { { 1 } }\n" $ \declarations ->
          map (fmap (line . start) . initializerExpansiveOrigin) declarations @?= [Nothing, Nothing, Nothing, Just 5, Nothing],
      testCase "single-expression do blocks follow the same classification" $
        withResolvedDeclarations "value = do { 1 }\nidentity = do { x -> x }\ncall = do { id 1 }\n" $ \declarations ->
          map (fmap (line . start) . initializerExpansiveOrigin) declarations @?= [Nothing, Nothing, Just 3],
      testCase "type abstraction does not defer a call" $
        withDeclarations "id x = x\nbad @a = id 1\ngood @a x = id x\n" $ \declarations -> do
          map (fmap (line . start) . initializerExpansiveOrigin) declarations @?= [Nothing, Just 3, Nothing]
          map hasValueParameters declarations @?= [True, False, True],
      testCase "immediate where is checked before a returned lambda" $
        withDeclarations "id x = x\nbad = x -> x where { work = id 1 }\ngood x = y -> y where { work = id 1 }\n" $ \declarations ->
          map (fmap (line . start) . initializerExpansiveOrigin) declarations @?= [Nothing, Just 3, Nothing],
      testCase "recursive reads retain occurrence spans and value-lambda protection" $
        withDeclarations "left = right\nright = left\nprotected x = protected x\nstatic @a = static\n" $ \declarations -> do
          let references = Set.fromList [ref | d <- declarations, A.ValueDefinition ref _ _ <- [A.nodeValue d]]
              occurrences = concatMap (unprotectedReferences references) declarations
          map (line . start . A.nodeSpan) occurrences @?= [2, 3, 5]
          map (column . start . A.nodeSpan) occurrences @?= [8, 9, 13],
      testCase "constructor-valued aliases still use the call rule" $
        withDeclarations "type Box a = Box a\nconstructor = Box\ncall = constructor 1\n" $ \declarations ->
          map (fmap (line . start) . initializerExpansiveOrigin) (valueDeclarations declarations) @?= [Nothing, Just 4],
      testCase "unused anonymous initializers retain the same restrictions" $
        withDeclarations "id x = x\n_ = id 1\n_ = 1\n" $ \declarations ->
          map (fmap (line . start) . initializerExpansiveOrigin) declarations @?= [Nothing, Just 3, Nothing],
      testCase "dependency scheduling uses source order among ready groups" $
        withDeclarations "first = late\nindependent = 2\nlate = 1\nlast = first\n" $ \declarations ->
          case schedule (A.BindingGroup A.Recursive declarations) of
            Left problem -> assertFailure (show problem)
            Right groups -> scheduledLines groups @?= [3, 4, 2, 5],
      testCase "anonymous initializers wait for dependencies without disappearing" $
        withDeclarations "x = y\n_ = x\ny = 1\n" $ \declarations ->
          case schedule (A.BindingGroup A.Recursive declarations) of
            Left problem -> assertFailure (show problem)
            Right groups -> scheduledLines groups @?= [4, 2, 3],
      testCase "recursive functions stay in source order and pass initialization" $
        withDeclarations "ping x = pong x\npong x = ping x\n" $ \declarations ->
          case schedule (A.BindingGroup A.Recursive declarations) of
            Right groups@[Cyclic _] -> do
              scheduledLines groups @?= [2, 3]
              checkInitialization True groups @?= []
            other -> assertFailure (show other),
      testCase "unsafe cycles report reference spans and diagnostic kinds" $
        withDeclarations "left = right\nright = left\n" $ \declarations ->
          case schedule (A.BindingGroup A.Recursive declarations) of
            Left problem -> assertFailure (show problem)
            Right groups -> do
              let errors = checkInitialization True groups
              map E.diagnosticCode errors @?= [E.UnsafeRecursiveInitialization, E.UnsafeRecursiveInitialization]
              map (\d -> let span' = E.diagnosticSpan d in (line (start span'), column (start span'), column (end span'))) errors @?= [(2, 8, 12), (3, 9, 12)]
    ]

scheduledLines :: [ScheduledGroup] -> [Int]
scheduledLines = concatMap (\case Acyclic d -> [line (start (A.nodeSpan d))]; Cyclic ds -> map (line . start . A.nodeSpan) (foldr (:) [] ds))
