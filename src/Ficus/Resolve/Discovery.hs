-- | Dependency discovery accepts any provider, including an in-memory one.
module Ficus.Resolve.Discovery where

import Control.Monad (forM_, unless)
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Parser qualified as P
import Ficus.Error.Resolve
import Ficus.Resolve.Header
import Ficus.Resolve.Provider
import Ficus.Syntax.Concrete qualified as C
import Ficus.Syntax.Name
import Ficus.Syntax.Parser (parseModule)
import Ficus.Syntax.Pragma (directiveSpan, standaloneEnabled)
import Ficus.Util.Source

data DiscoveryDiagnostic = ParseDiagnostic P.Diagnostic | ResolutionDiagnostic Diagnostic deriving (Eq, Show)

data DiscoveredModule = DiscoveredModule {discoveredHeader :: Header, discoveredConcrete :: C.ConcreteModule} deriving (Eq, Show)

data ModuleGraph = ModuleGraph {graphModules :: Map ModuleId DiscoveredModule, dependencyOrder :: [ModuleId], graphDiagnostics :: [DiscoveryDiagnostic]} deriving (Eq, Show)

data DiscoveryState = DiscoveryState {loaded :: Map ModuleId DiscoveredModule, visited :: Set ModuleId, order :: [ModuleId], diagnostics :: [DiscoveryDiagnostic]}

type Discover m = ReaderT (ModuleProvider m) (StateT DiscoveryState m)

discoverModules :: (Monad m) => ModuleProvider m -> [ModuleId] -> m ModuleGraph
discoverModules provider entries = discoverModulesAt provider [(owner, Span "<module>" (Position 1 1 0) (Position 1 1 0)) | owner <- entries]

-- | File-oriented drivers supply an anchor for each explicit entry. This keeps
-- missing entry diagnostics distinct without turning entries into import edges.
discoverModulesAt :: (Monad m) => ModuleProvider m -> [(ModuleId, Span)] -> m ModuleGraph
discoverModulesAt provider entries = do
  s <- execStateT (runReaderT (mapM_ (\(owner, anchor) -> visit anchor [] [] Nothing owner) entries) provider) (DiscoveryState Map.empty Set.empty [] [])
  let importErrors =
        [ ResolutionDiagnostic ((diagnostic ModuleNotImportable (edgeSpan edge) "standalone modules cannot be imported") {relatedSpans = [(directiveSpan pragma, "standalone module declared here") | pragma <- Map.findWithDefault [] "STANDALONE" (headerOptions (discoveredHeader target))]})
        | discovered <- Map.elems (loaded s),
          edge <- headerEdges (discoveredHeader discovered),
          Just target <- [Map.lookup (edgeTarget edge) (loaded s)],
          standaloneEnabled (headerOptions (discoveredHeader target))
        ]
  pure (ModuleGraph (loaded s) (reverse (order s)) (reverse (diagnostics s) ++ importErrors))
  where
    visit anchor stack route incoming owner
      | owner `elem` stack = case incoming of
          Nothing -> pure ()
          Just edge -> report (ResolutionDiagnostic ((diagnostic ImportCycle (edgeSpan edge) ("module import cycle: " <> T.intercalate " -> " (map moduleText (drop (cycleStart owner stack) stack ++ [owner])))) {relatedSpans = [(edgeSpan e, "cycle edge") | e <- drop (cycleStart owner stack) route]}))
      | otherwise = do
          seen <- gets (Set.member owner . visited)
          unless seen $ do
            modify' (\s -> s {visited = Set.insert owner (visited s)})
            provider' <- ask
            source <- lift (lift (provider' owner))
            case source of
              Left message -> report (ResolutionDiagnostic (diagnostic ModuleNotFound (maybe anchor edgeSpan incoming) message))
              Right (Source file input) -> case parseModule file input of
                Left d -> report (ParseDiagnostic d)
                Right concrete -> do
                  let (header, ds) = scanHeader owner concrete
                  mapM_ (report . ResolutionDiagnostic) ds
                  modify' (\s -> s {loaded = Map.insert owner (DiscoveredModule header concrete) (loaded s)})
                  forM_ (headerEdges header) $ \edge -> visit anchor (stack ++ [owner]) (route ++ maybe [] pure incoming) (Just edge) (edgeTarget edge)
                  modify' (\s -> s {order = owner : order s})
    cycleStart owner = length . takeWhile (/= owner)
    report d = modify' (\s -> s {diagnostics = d : diagnostics s})

instance D.ToDiagnostic DiscoveryDiagnostic where
  toDiagnostic (ParseDiagnostic d) = D.toDiagnostic d
  toDiagnostic (ResolutionDiagnostic d) = D.toDiagnostic d
