module Ficus.Resolve.Header where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Ficus.Error.Resolve
import Ficus.Resolve.Pragma
import Ficus.Syntax.Concrete qualified as C
import Ficus.Syntax.Name
import Ficus.Util.Source

data EdgeOrigin = ExplicitImport | ImplicitPrelude deriving (Eq, Show)

data ImportEdge = ImportEdge {edgeTarget :: ModuleId, edgeSpan :: Span, edgeOrigin :: EdgeOrigin} deriving (Eq, Show)

data Header = Header {headerId :: ModuleId, headerSpan :: Span, headerOptions :: ModuleOptions, headerEdges :: [ImportEdge]} deriving (Eq, Show)

scanHeader :: ModuleId -> C.ConcreteModule -> (Header, [Diagnostic])
scanHeader owner m = (Header owner anchor options edges, errors)
  where
    s = C.moduleLocation m
    anchor = s {end = start s}
    results = map (validatePragma ModuleDirective) (C.modulePragmas m)
    errors = [d | Left d <- results] ++ [diagnostic InvalidModuleIdentity anchor "module path components must be uppercase identifiers" | let ModuleId parts = owner, not (all validModuleComponent parts)]
    options = Map.fromListWith (++) [(directiveName d, [d]) | Right d <- results, Just rule <- [Map.lookup (directiveName d) pragmaRules], pragmaPlacement rule == ModuleDirective]
    enabled = preludeEnabled options
    edges = [ImportEdge (ModuleId ("Prelude" :| [])) anchor ImplicitPrelude | enabled] ++ map explicit (C.moduleImports m)
    explicit i = case C.concrete i of
      C.Import (n : ns) _ -> ImportEdge (ModuleId (C.nameText n :| map C.nameText ns)) (foldl extend (C.nameLocation n) ns) ExplicitImport
      C.Import [] _ -> ImportEdge owner (C.location i) ExplicitImport -- rejected by Concrete parser
    extend a n = a {end = end (C.nameLocation n)}

headerPrelude :: Header -> Bool
headerPrelude = preludeEnabled . headerOptions
