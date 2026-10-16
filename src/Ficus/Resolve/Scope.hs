-- | Resolver-facing interfaces and import candidate sets, independent of IO.
module Ficus.Resolve.Scope where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.Error.Resolve
import Ficus.Resolve.Header
import Ficus.Syntax.Concrete qualified as C
import Ficus.Syntax.Name
import Ficus.Util.Source

data Candidate = Candidate {candidateEntity :: Entity, candidateRoutes :: [Span]} deriving (Eq, Show)

type Candidates = Map (Namespace, Text) [Candidate]

data Interface = Interface {publicNames :: NameSummary, allEntities :: Map GlobalId Entity, interfaceImplementations :: [ImplementationId], interfaceFields :: Map (GlobalId, Text) FieldDescriptor, interfaceBuiltins :: Map Text GlobalId} deriving (Eq, Show)

data Scope = Scope {openedNames :: Candidates, moduleQualifiers :: Map [Text] [(ModuleId, Span)], scopeInterfaces :: Map ModuleId Interface} deriving (Eq, Show)

insertCandidate :: (Namespace, Text) -> Candidate -> Candidates -> Candidates
insertCandidate key candidate = Map.insertWith merge key [candidate]
  where
    merge new old = foldl add old new
    add xs c = case break ((== entityId (candidateEntity c)) . entityId . candidateEntity) xs of
      (before, x : after) -> before ++ [x {candidateRoutes = candidateRoutes x ++ candidateRoutes c}] ++ after
      _ -> xs ++ [c]

collectNames :: ModuleId -> C.ConcreteModule -> (NameSummary, [Diagnostic])
collectNames owner m =
  let ds = C.moduleDeclarations m
      (table, errors) = foldl add (Map.empty, []) (concatMap entries ds)
      definitions = concatMap declared ds
      (_, duplicates) = foldl checkDuplicate (Map.empty, []) definitions
      (_, signatureErrors) = foldl checkSignature (Map.empty, []) [n | C.Located _ _ (C.KindSignature n _) <- ds]
   in (table, errors ++ duplicates ++ signatureErrors ++ concatMap fieldDuplicates ds)
  where
    entity ns role parent n = ((ns, C.nameText n), Entity (GlobalId owner ns (C.nameText n)) role (C.nameLocation n) parent)
    entries d = case C.concrete d of
      C.FunctionClause n _ _ _ _ -> [entity ValueNS ValueRole Nothing n | C.nameText n /= "_"]
      C.TypeSignature n _ -> [entity ValueNS ValueRole Nothing n | C.nameText n /= "_"]
      C.KindSignature n _ -> [entity TypeNS DataRole Nothing n | not (any (definesType (C.nameText n)) (C.moduleDeclarations m))]
      C.TypeAlias n _ _ -> [entity TypeNS AliasRole Nothing n]
      C.DataDeclaration n _ body ->
        let tid = GlobalId owner TypeNS (C.nameText n)
         in case body of
              C.Constructors b -> entity TypeNS DataRole Nothing n : [entity ConstructorNS ConstructorRole (Just tid) c | C.Located _ _ (C.Constructor c _) <- C.blockItems b]
              C.Fields _ -> [entity TypeNS RecordRole Nothing n, entity ConstructorNS RecordConstructorRole (Just tid) n]
      C.TraitDeclaration _ n _ b -> entity TypeNS TraitRole Nothing n : [entity ValueNS MethodRole (Just (GlobalId owner TypeNS (C.nameText n))) method | C.Located _ _ (C.TypeSignature method _) <- C.blockItems b, C.nameText method /= "_"]
      _ -> []
    definesType spelling d = case C.concrete d of
      C.TypeAlias n _ _ -> C.nameText n == spelling
      C.DataDeclaration n _ _ -> C.nameText n == spelling
      C.TraitDeclaration _ n _ _ -> C.nameText n == spelling
      _ -> False
    declared d = case C.concrete d of
      C.FunctionClause {} -> entries d
      C.TypeAlias {} -> entries d
      C.DataDeclaration {} -> entries d
      C.TraitDeclaration {} -> entries d
      _ -> []
    fieldDuplicates d = case C.concrete d of
      C.DataDeclaration _ _ (C.Fields block) -> snd (foldl checkField (Map.empty, []) (C.blockItems block))
      _ -> []
    checkField (seen, ds) (C.Located _ _ (C.FieldSignature n _))
      | C.nameText n == "_" = (seen, ds ++ [diagnostic ReservedName (C.nameLocation n) "a record field requires a name"])
      | otherwise = case Map.lookup (C.nameText n) seen of
          Just old -> (seen, ds ++ [(diagnostic DuplicateDeclaration (C.nameLocation n) "duplicate record field") {relatedSpans = [(C.nameLocation old, "earlier field")]}])
          Nothing -> (Map.insert (C.nameText n) n seen, ds)
    checkSignature (seen, ds) n = case Map.lookup (C.nameText n) seen of
      Just old -> (seen, ds ++ [(diagnostic DuplicateSignature (C.nameLocation n) "duplicate kind signature") {relatedSpans = [(C.nameLocation old, "first signature")]}])
      Nothing -> (Map.insert (C.nameText n) n seen, ds)
    checkDuplicate (seen, ds) (key, e) = case Map.lookup key seen of
      Just old | entityRole old == ValueRole && entityRole e == ValueRole -> (seen, ds)
      Just old -> (seen, ds ++ [(diagnostic (if entityRole old == MethodRole && entityRole e == MethodRole && entityOwner old == entityOwner e then DuplicateSignature else DuplicateDeclaration) (entitySpan e) "duplicate declaration") {relatedSpans = [(entitySpan old, "earlier declaration")]}])
      Nothing -> (Map.insert key e seen, ds)
    add (table, ds) (key@(ns, spelling), e)
      | any (\(p, n, _, _) -> p == ns && n == spelling) primitiveNames = (table, ds ++ [diagnostic ReservedName (entitySpan e) "reserved intrinsic name"])
      | otherwise = (Map.insertWith (\_ old -> old) key e table, ds)

buildScope :: Header -> C.ConcreteModule -> NameSummary -> Map ModuleId Interface -> (Scope, NameSummary, [Diagnostic])
buildScope header m own interfaces = foldl importOne (initial, own, []) (C.moduleImports m)
  where
    prelude = ModuleId ("Prelude" :| [])
    initial = Scope (if headerPrelude header then maybe Map.empty (candidates (headerSpan header) . publicNames) (Map.lookup prelude interfaces) else Map.empty) Map.empty interfaces
    candidates s = Map.map (\e -> [Candidate e [s]])
    importOne (scope, exports, ds) imp = case C.concrete imp of
      C.Import [] _ -> (scope, exports, ds)
      C.Import (n : ns) mode ->
        let owner = ModuleId (C.nameText n :| map C.nameText ns)
         in case Map.lookup owner interfaces of
              Nothing -> (scope, exports, ds) -- discovery already reports unavailable modules
              Just iface -> case mode of
                C.ModuleOnly -> qualifier scope exports ds [lastComponent n ns] owner imp
                C.Aliased alias -> qualifier scope exports ds [C.nameText alias] owner imp
                C.AllMembers pub -> open scope exports ds (Map.toList (publicNames iface)) pub imp
                C.Selected items pub ->
                  let (selected, errors) = foldl (select iface) ([], []) items
                   in open scope exports (ds ++ errors) selected pub imp
    lastComponent n ns = case reverse ns of x : _ -> C.nameText x; [] -> C.nameText n
    qualifier scope exports ds path owner imp =
      let old = Map.findWithDefault [] path (moduleQualifiers scope)
          warnings = [(diagnostic RepeatedModuleQualifier (C.location imp) "repeated module qualifier; ambiguity is checked at use") {relatedSpans = [(s, "earlier qualifier") | (_, s) <- old]} | not (null old)]
          routes = old ++ [(owner, C.location imp)]
       in (scope {moduleQualifiers = Map.insert path routes (moduleQualifiers scope)}, exports, ds ++ warnings)
    open scope exports ds selected pub imp =
      let names = foldl (\acc (key, e) -> insertCandidate key (Candidate e [C.location imp]) acc) (openedNames scope) selected
          (exports', errors) = if pub then foldl (publish (pubSpan imp)) (exports, []) selected else (exports, [])
       in (scope {openedNames = names}, exports', ds ++ errors)
    pubSpan imp = case [C.tokenSpan t | t <- C.moduleTokens m, C.tokenText t == "pub", start (C.tokenSpan t) >= start (C.location imp), end (C.tokenSpan t) <= end (C.location imp)] of
      s : _ -> s
      [] -> C.location imp
    publish s (exports, ds) (key, e) = case Map.lookup key exports of
      Just old | entityId old /= entityId e -> (exports, ds ++ [(diagnostic AmbiguousReexport s "conflicting public exports") {relatedSpans = [(entitySpan old, "earlier public entity"), (entitySpan e, "conflicting entity")]}])
      _ -> (Map.insert key e exports, ds)
    select iface (selected, ds) item = case C.concrete item of
      C.ImportItem n _ | C.nameText n == "_" -> (selected, ds ++ [diagnostic ReservedName (C.nameLocation n) "_ is not an importable name"])
      C.ImportItem n members ->
        let ns = if C.nameSpace n == C.LowerName then ValueNS else TypeNS
            found = Map.lookup (ns, C.nameText n) (publicNames iface)
            fallback = Map.lookup (ConstructorNS, C.nameText n) (publicNames iface)
         in case found `orElse` fallback of
              Nothing -> (selected, ds ++ [diagnostic MissingExport (C.nameLocation n) "missing public export"])
              Just e ->
                let key = case entityId e of GlobalId _ namespace _ -> (namespace, C.nameText n); IntrinsicId _ -> (ns, C.nameText n)
                    constructors = [(k, c) | (k, c) <- Map.toList (publicNames iface), entityOwner c == Just (entityId e)]
                    memberSpan = case members of
                      Just C.AllConstructors -> selectionSpan item n
                      Just (C.SelectedConstructors (x : _)) -> C.nameLocation x
                      _ -> C.location item
                 in case members of
                      Just _ | entityRole e /= DataRole -> (selected ++ [(key, e)], ds ++ [diagnostic InvalidImportSelection memberSpan "constructor selection requires an ADT"])
                      Just C.AllConstructors -> (selected ++ [(key, e)] ++ constructors, ds)
                      Just (C.SelectedConstructors xs) -> foldl (selectConstructor constructors) (selected ++ [(key, e)], ds) xs
                      Nothing -> (selected ++ [(key, e)] ++ [c | c <- constructors, entityRole e == RecordRole], ds)
    selectionSpan item n = case [C.tokenSpan t | t <- C.moduleTokens m, C.tokenText t == "..", start (C.tokenSpan t) >= end (C.nameLocation n), end (C.tokenSpan t) <= end (C.location item)] of
      s : _ -> s
      [] -> C.location item
    selectConstructor cs (selected, ds) n = case lookup (ConstructorNS, C.nameText n) cs of
      Just e -> (selected ++ [((ConstructorNS, C.nameText n), e)], ds)
      Nothing -> (selected, ds ++ [diagnostic InvalidImportSelection (C.nameLocation n) "constructor does not belong to selected type"])
    orElse (Just x) _ = Just x
    orElse Nothing y = y

collectFields :: ModuleId -> C.ConcreteModule -> Map (GlobalId, Text) FieldDescriptor
collectFields owner m = Map.fromList [((gid, C.nameText name), FieldDescriptor gid (C.nameText name) (C.nameLocation name)) | C.Located _ _ (C.DataDeclaration n _ (C.Fields block)) <- C.moduleDeclarations m, let gid = GlobalId owner TypeNS (C.nameText n), C.Located _ _ (C.FieldSignature name _) <- C.blockItems block, C.nameText name /= "_"]
