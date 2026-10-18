-- | Stable dependency scheduling and source-level strict initialization checks.
-- Evidence introduces additional edges, which Core must check independently.
module Ficus.Infer.Initialization (ScheduledGroup (..), ScheduleError (..), schedule, checkInitialization, definedReferences) where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Ficus.Error.Type qualified as E
import Ficus.Infer.Restriction
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Dependencies
import Ficus.Syntax.Name

data ScheduledGroup = Acyclic A.Declaration | Cyclic (NonEmpty A.Declaration) deriving (Eq, Show)

data ScheduleError = InvalidCondensationGraph deriving (Eq, Show)

schedule :: A.BindingGroup -> Either ScheduleError [ScheduledGroup]
schedule group = case A.scopeMode group of
  A.Sequential -> Right (map (Acyclic . snd) indexed)
  A.Recursive -> stable Set.empty components
  where
    indexed = zip [0 :: Int ..] (filter isValue (A.declarations group))
    owners = Map.fromList [(ref, index) | (index, declaration) <- indexed, ref <- Set.toList (definedReferences declaration)]
    dependencies declaration = Set.fromList [index | ref <- Set.toList (valueDependencies (declarationDependencies declaration)), Just index <- [Map.lookup ref owners]]
    components = sortOn firstIndex (map component (stronglyConnComp [((index, declaration), index, Set.toList (dependencies declaration)) | (index, declaration) <- indexed]))
    component (AcyclicSCC entry) = (False, [entry])
    component (CyclicSCC entries) = (True, sortOn fst entries)
    firstIndex (_, (index, _) : _) = index
    firstIndex (_, []) = maxBound
    stable _ [] = Right []
    stable completed remaining = case selectReady completed remaining of
      Nothing -> Left InvalidCondensationGraph
      Just ((recursive, entries), rest) ->
        let done = Set.fromList (map fst entries)
         in do
              following <- stable (completed `Set.union` done) rest
              case entries of
                [] -> Left InvalidCondensationGraph
                (_, first) : later -> pure ((if recursive then Cyclic (first :| map snd later) else Acyclic first) : following)
    selectReady _ [] = Nothing
    selectReady completed (entry@(_, entries) : rest)
      | Set.unions (map (dependencies . snd) entries) `Set.difference` Set.fromList (map fst entries) `Set.isSubsetOf` completed = Just (entry, rest)
      | otherwise = do
          (selected, others) <- selectReady completed rest
          pure (selected, entry : others)
    isValue declaration = case A.nodeValue declaration of
      A.ValueDefinition {} -> True
      A.PatternDefinition {} -> True
      _ -> False

checkInitialization :: Bool -> [ScheduledGroup] -> [E.Diagnostic]
checkInitialization topLevel = concatMap check
  where
    check group =
      let (recursive, declarations) = case group of Acyclic d -> (False, [d]); Cyclic ds -> (True, NE.toList ds)
          references = Set.unions (map definedReferences declarations)
          expansive = [E.diagnostic E.ExpansiveInitializer origin "initializer must be non-expansive" | topLevel || recursive, declaration <- declarations, Just origin <- [initializerExpansiveOrigin declaration]]
          unsafe = [E.diagnostic E.UnsafeRecursiveInitialization (A.nodeSpan occurrence) "recursive initialization reads a value before it is initialized" | recursive, declaration <- declarations, occurrence <- unprotectedReferences references declaration]
       in expansive ++ unsafe

definedReferences :: A.Declaration -> Set Reference
definedReferences declaration = case A.nodeValue declaration of
  A.ValueDefinition reference _ _ -> Set.singleton reference
  A.PatternDefinition pattern' _ -> binders pattern'
  _ -> Set.empty
  where
    binders pattern' = case A.nodeValue pattern' of
      A.Bind binder -> Set.singleton (LocalRef (fst (A.nodeValue binder)))
      A.ConstructorPattern _ arguments -> Set.unions (map binders arguments)
      A.ProductPattern arguments -> Set.unions (map binders arguments)
      A.ListPattern arguments -> Set.unions (map binders arguments)
      A.AnnotatedPattern inner _ -> binders inner
      A.NegatedPattern inner -> binders inner
      A.Wildcard -> Set.empty
      A.LiteralPattern _ -> Set.empty
      A.UnitPattern -> Set.empty
