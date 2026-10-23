-- | Structural dependencies only. SCCs are not evidence of safe strict
-- initialization; inference checks protection, expansiveness and dictionaries.
module Ficus.Syntax.Abstract.Dependencies (Dependencies (..), declarationDependencies, bindingDependencies, bindingComponents) where

import Data.Graph (SCC, stronglyConnComp)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Ficus.Syntax.Abstract
import Ficus.Syntax.Name

-- Value and type edges stay separate, and identities never depend on spelling.
data Dependencies = Dependencies {valueDependencies :: Set Reference, typeDependencies :: Set GlobalId, scopedTypeDependencies :: Set TypeVarId} deriving (Eq, Show)

instance Semigroup Dependencies where
  Dependencies a b c <> Dependencies d e f = Dependencies (Set.union a d) (Set.union b e) (Set.union c f)

instance Monoid Dependencies where
  mempty = Dependencies Set.empty Set.empty Set.empty

bindingDependencies :: BindingGroup -> Map Reference Dependencies
bindingDependencies g = Map.fromList [(ref, declarationDependencies d) | d <- declarations g, ref <- defines d]

-- Source-ordered graph input; consumers retain declarations for effect order.
bindingComponents :: BindingGroup -> [SCC Reference]
bindingComponents g = stronglyConnComp [(ref, ref, Set.toList ((valueDependencies deps `Set.union` Set.unions [Map.findWithDefault Set.empty ident typeOwners | ident <- Set.toList (scopedTypeDependencies deps)]) `Set.intersection` declared)) | d <- declarations g, ref <- defines d, Just deps <- [Map.lookup ref graph]]
  where
    graph = bindingDependencies g
    declared = Map.keysSet graph
    typeOwners = Map.fromList [(ident, Set.fromList (defines d)) | d <- declarations g, PatternDefinition p _ <- [nodeValue d], binder <- patternTypeBinders p, let (ident, _, _) = nodeValue binder]

defines :: Declaration -> [Reference]
defines d = case nodeValue d of
  ValueDefinition ref _ _ -> [ref]
  PatternDefinition p _ -> patternBinders p
  _ -> []

patternBinders :: Pattern -> [Reference]
patternBinders p = case nodeValue p of
  Bind b -> [LocalRef (fst (nodeValue b))]
  OpenPattern _ body -> patternBinders body
  ConstructorPattern _ ps -> concatMap patternBinders ps
  ProductPattern ps -> concatMap patternBinders ps
  ListPattern ps -> concatMap patternBinders ps
  AnnotatedPattern q _ -> patternBinders q
  NegatedPattern q -> patternBinders q
  _ -> []

-- | Also available for anonymous discard initializers, which have no entry in
-- the name-indexed binding graph. They must still be checked and initialized.
declarationDependencies :: Declaration -> Dependencies
declarationDependencies d = case nodeValue d of
  ValueDefinition _ sig body -> foldMap scheme sig <> case body of BuiltinBody _ -> mempty; ClausesBody _ cs -> foldMap clause cs
  PatternDefinition p e ->
    let dependencies = patternTypes p <> expression e
        bound = Set.fromList [ident | binder <- patternTypeBinders p, let (ident, _, _) = nodeValue binder]
     in dependencies {scopedTypeDependencies = scopedTypeDependencies dependencies `Set.difference` bound}
  AliasDefinition _ _ _ t -> ty t
  DataDefinition _ _ _ cs -> foldMap (foldMap ty . snd . nodeValue) cs
  RecordDefinition _ _ _ _ fs _ -> foldMap (ty . snd . nodeValue) fs
  OpaqueBuiltinType {} -> mempty
  TraitDefinition _ _ cs methods -> foldMap predicate cs <> foldMap declarationDependencies methods
  MethodDefinition _ s -> scheme s
  ImplementationDefinition _ _ cs head' methods -> foldMap predicate cs <> predicate head' <> foldMap declarationDependencies methods
  where
    clause c = let cl = nodeValue c in foldMap patternTypes (clausePatterns cl) <> expression (clauseBody cl) <> group (clauseWhere cl)
    scheme s = let (_, _, t) = nodeValue s in ty t

value :: Reference -> Dependencies
value ref = Dependencies (Set.singleton ref) Set.empty Set.empty

typeEdge :: GlobalId -> Dependencies
typeEdge gid = Dependencies Set.empty (Set.singleton gid) Set.empty

group :: BindingGroup -> Dependencies
group = foldMap declarationDependencies . declarations

expression :: Expr -> Dependencies
expression e = case nodeValue e of
  Ref ref -> value ref
  Constructor gid -> value (GlobalRef gid)
  Method gid -> value (GlobalRef gid)
  Literal _ -> mempty
  Hole _ -> mempty
  Apply a b -> expression a <> expression b
  TypeApply a ts -> expression a <> foldMap (ty . nodeValue) ts
  Annotated a _ t -> expression a <> ty t
  Lambda _ a -> expression a
  TypeLambda _ a -> expression a
  Match _ a cs -> expression a <> foldMap (\c -> let (p, g, r) = nodeValue c in patternTypes p <> foldMap expression g <> expression r) cs
  Conditional cs -> foldMap (\c -> let (g, r) = nodeValue c in foldMap expression g <> expression r) cs
  Sequence ss a -> foldMap (\s -> case nodeValue s of Effect x -> expression x; BindStatement g -> group g) ss <> expression a
  Where _ g a -> group g <> expression a
  Project a _ -> expression a
  PackRecord gid ts fs -> value (GlobalRef gid) <> foldMap (ty . snd . nodeValue) ts <> foldMap (expression . snd . nodeValue) fs
  ConstructRecord gid fs -> value (GlobalRef gid) <> foldMap (expression . snd . nodeValue) fs
  UpdateRecord a fs -> expression a <> foldMap (expression . snd . nodeValue) fs
  Product xs -> foldMap expression xs
  List xs -> foldMap expression xs
  Unit -> mempty
  Negate a -> expression a

patternTypes :: Pattern -> Dependencies
patternTypes p = case nodeValue p of
  OpenPattern _ body -> patternTypes body
  ConstructorPattern gid ps -> value (GlobalRef gid) <> foldMap patternTypes ps
  ProductPattern ps -> foldMap patternTypes ps
  ListPattern ps -> foldMap patternTypes ps
  AnnotatedPattern q t -> patternTypes q <> ty t
  NegatedPattern q -> patternTypes q
  _ -> mempty

ty :: TypeSyntax -> Dependencies
ty t = case nodeValue t of
  TypeConstructor gid -> typeEdge gid
  TypeApplication a b -> ty a <> ty b
  ArrowType a b -> ty a <> ty b
  LazyArrowType a b -> ty a <> ty b
  QualifiedType cs a -> foldMap predicate cs <> ty a
  TypeVariable ident -> Dependencies Set.empty Set.empty (Set.singleton ident)
  TypeHole _ -> mempty

predicate :: Predicate -> Dependencies
predicate p = let (gid, t) = nodeValue p in typeEdge gid <> ty t
