-- | Composition of independently usable discovery and translation passes.
module Ficus.Resolve (FrontendResult (..), resolveGraph, resolveGraphWithNames, resolveSources) where

import Data.List (nubBy, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Ficus.Desugar.Registry
import Ficus.Error.Diagnostic qualified as D
import Ficus.Resolve.Desugar
import Ficus.Resolve.Discovery
import Ficus.Resolve.Header
import Ficus.Resolve.Provider
import Ficus.Resolve.Scope
import Ficus.Syntax.Abstract
import Ficus.Syntax.Name
import Ficus.Syntax.Pragma (standaloneEnabled)
import Ficus.Util.Source (sourceFile)

-- Valid independent modules remain available even when another module fails.
-- Consumers must inspect frontendDiagnostics before compiling the whole graph.
data FrontendResult = FrontendResult
  { frontendModules :: Map ModuleId AbstractModule,
    frontendInterfaces :: Map ModuleId Interface,
    frontendDiagnostics :: [DiscoveryDiagnostic]
  }
  deriving (Eq, Show)

resolveSources :: (Monad m) => ResolveConfig -> SugarRegistry -> ModuleProvider m -> [ModuleId] -> m FrontendResult
resolveSources config registry provider entries = resolveGraph config registry <$> discoverModules provider entries

resolveGraph :: ResolveConfig -> SugarRegistry -> ModuleGraph -> FrontendResult
resolveGraph = resolveGraphWithNames Map.empty

resolveGraphWithNames :: Map ModuleId NameSummary -> ResolveConfig -> SugarRegistry -> ModuleGraph -> FrontendResult
resolveGraphWithNames scopes config registry graph =
  let result = foldl resolve initial (dependencyOrder graph)
   in result {frontendDiagnostics = sortOn diagnosticOrder (nubBy sameDiagnostic (frontendDiagnostics result))}
  where
    sameDiagnostic a b =
      let x = D.toDiagnostic a; y = D.toDiagnostic b
       in D.diagnosticCode x == D.diagnosticCode y && D.diagnosticSpan x == D.diagnosticSpan y
    traversal = Map.fromList [(sourceFile (headerSpan (discoveredHeader m)), index) | (index, owner) <- zip [0 :: Int ..] (dependencyOrder graph), Just m <- [Map.lookup owner (graphModules graph)]]
    diagnosticOrder d = let envelope = D.toDiagnostic d; span' = D.diagnosticSpan envelope in (Map.findWithDefault maxBound (sourceFile span') traversal, span', D.diagnosticCode envelope)
    initial = FrontendResult Map.empty Map.empty (graphDiagnostics graph)
    resolve result owner = case Map.lookup owner (graphModules graph) of
      Nothing -> result
      Just (DiscoveredModule header input) ->
        let dependencies = Map.restrictKeys (frontendInterfaces result) (Map.keysSet (Map.fromList [(edgeTarget edge, ()) | edge <- headerEdges header]))
            resolution = resolveModuleWithNames (Map.findWithDefault Map.empty owner scopes) config registry header input dependencies
            dependencyFailed = any (\edge -> Map.notMember (edgeTarget edge) (frontendModules result) || maybe False (standaloneEnabled . headerOptions . discoveredHeader) (Map.lookup (edgeTarget edge) (graphModules graph))) (headerEdges header)
            valid = if dependencyFailed then Nothing else resolvedModule resolution
         in result
              { frontendModules = maybe (frontendModules result) (\tree -> Map.insert owner tree (frontendModules result)) valid,
                frontendInterfaces = Map.insert owner (resolvedInterface resolution) (frontendInterfaces result),
                frontendDiagnostics = frontendDiagnostics result ++ map ResolutionDiagnostic (resolutionDiagnostics resolution)
              }
