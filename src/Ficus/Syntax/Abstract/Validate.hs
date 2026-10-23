-- | Checks the successful Abstract boundary, including lexical dominance.
module Ficus.Syntax.Abstract.Validate (validateAbstract) where

import Control.Monad (unless)
import Control.Monad.Reader
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Syntax.Abstract
import Ficus.Syntax.Name
import Ficus.Util.Source

data Scope = Scope {values :: Set LocalId, types :: Set TypeVarId}

type Check = ReaderT Scope (Either Text)

validateAbstract :: AbstractModule -> Either Text ()
validateAbstract m = runReaderT check (Scope Set.empty Set.empty)
  where
    check = do
      unless (start (abstractSpan m) <= end (abstractSpan m)) (bad "reversed module span")
      unless (abstractOrigin m == SourceOrigin (abstractSpan m)) (bad "invalid module provenance")
      mapM_ validateExport (Map.toList (abstractExports m))
      mapM_ (\(gid, entity) -> do global gid; unless (gid == entityId entity) (bad "inconsistent entity identity")) (Map.toList (abstractEntities m))
      mapM_ (\((owner, label), field) -> do validName label; role owner [RecordRole]; unless (owner == fieldOwner field && label == fieldLabel field) (bad "inconsistent field descriptor")) (Map.toList (abstractFields m))
      mapM_ (validName . occurrenceSpelling) (abstractOccurrences m)
      mapM_ global (Map.elems (builtinAssociations m))
      mapM_ (\field -> role (fieldOwner field) [RecordRole] >> validName (fieldLabel field)) (Map.elems (builtinMemberAssociations m))
      group (abstractDeclarations m)
    bad :: Text -> Check a
    bad = lift . Left
    validName spelling = unless (spelling /= "_") (bad "wildcard used as a name")
    validNode :: Node a -> Check ()
    validNode n = do
      let s = nodeSpan n
          parent = abstractSpan m
          provenanceSpan = case nodeOrigin n of SourceOrigin p -> p; GeneratedOrigin _ p -> p
      unless (start s <= end s && sourceFile s == sourceFile parent && start s >= start parent && end s <= end parent) (bad "invalid Abstract source span")
      unless (provenanceSpan == s) (bad "invalid Abstract provenance")
    onNode :: (a -> Check b) -> Node a -> Check b
    onNode f n = validNode n >> f (nodeValue n)
    global gid = case gid of
      IntrinsicId _ -> pure ()
      GlobalId _ _ spelling -> validName spelling >> unless (Map.member gid (abstractEntities m)) (bad "unknown canonical global identity")
    role gid allowed = do
      global gid
      case gid of
        IntrinsicId _ -> unless (any (\(_, _, identity, actualRole) -> identity == gid && actualRole `elem` allowed) primitiveNames) (bad "intrinsic has incorrect role")
        _ -> case Map.lookup gid (abstractEntities m) of
          Just e | entityRole e `elem` allowed -> pure ()
          _ -> bad "global has incorrect declaration role"
    validateExport ((ns, spelling), entity) = do
      global (entityId entity)
      case entityId entity of
        GlobalId _ namespace name -> unless (ns == namespace && spelling == name) (bad "export identity disagrees with its key")
        IntrinsicId _ -> pure ()
    reference = \case
      GlobalRef gid -> role gid [ValueRole, MethodRole]
      LocalRef i -> do scope <- asks values; unless (Set.member i scope) (bad "local reference outside its lexical scope")
    typeVariable i = do scope <- asks types; unless (Set.member i scope) (bad "type variable outside its lexical scope")
    withValues :: Set LocalId -> Check a -> Check a
    withValues xs = local (\s -> s {values = Set.union xs (values s)})
    withTypes :: Set TypeVarId -> Check a -> Check a
    withTypes xs = local (\s -> s {types = Set.union xs (types s)})
    binder b = onNode (\(_, spelling) -> validName spelling) b
    typeBinder b = onNode (\(_, spelling, k) -> validName spelling >> mapM_ kind k) b
    typeIds bs = Set.fromList [i | b <- bs, let (i, _, _) = nodeValue b]
    binders :: [TypeBinder] -> Check a -> Check a
    binders bs action = do
      unless (Set.size (typeIds bs) == length bs) (bad "duplicate type binder identity")
      mapM_ typeBinder bs
      withTypes (typeIds bs) action
    kind = onNode $ \case
      TypeKindSyntax -> pure ()
      KindVariable i -> typeVariable i
      KindArrow a b -> kind a >> kind b
      KindHole _ -> pure ()
    ty = onNode $ \case
      TypeVariable i -> typeVariable i
      TypeConstructor gid -> role gid [AliasRole, DataRole, RecordRole, TraitRole]
      TypeApplication a b -> ty a >> ty b
      ArrowType a b -> ty a >> ty b
      LazyArrowType a b -> ty a >> ty b
      QualifiedType cs t -> mapM_ predicate cs >> ty t
      TypeHole _ -> pure ()
    predicate = onNode (\(gid, t) -> role gid [TraitRole] >> ty t)
    scheme = onNode (\(explicit, implicit, t) -> binders (explicit ++ implicit) (ty t))
    patternNode = onNode $ \case
      Bind b -> binder b
      Wildcard -> pure ()
      OpenPattern witnesses body -> binders (map snd witnesses) (patternNode body)
      ConstructorPattern gid ps -> role gid [ConstructorRole, RecordConstructorRole] >> mapM_ patternNode ps
      LiteralPattern _ -> pure ()
      ProductPattern ps -> mapM_ patternNode ps
      ListPattern ps -> mapM_ patternNode ps
      UnitPattern -> pure ()
      AnnotatedPattern p t -> patternNode p >> ty t
      NegatedPattern p -> patternNode p
    patternIds p = case nodeValue p of
      Bind b -> [fst (nodeValue b)]
      OpenPattern _ body -> patternIds body
      ConstructorPattern _ ps -> concatMap patternIds ps
      ProductPattern ps -> concatMap patternIds ps
      ListPattern ps -> concatMap patternIds ps
      AnnotatedPattern q _ -> patternIds q
      NegatedPattern q -> patternIds q
      _ -> []
    patterns :: [Pattern] -> Check a -> Check a
    patterns ps action = do
      let ids = concatMap patternIds ps
      unless (length ids == Set.size (Set.fromList ids)) (bad "duplicate pattern binder identity")
      binders (concatMap patternTypeBinders ps) (mapM_ patternNode ps >> withValues (Set.fromList ids) action)
    expr = onNode $ \case
      Ref ref -> reference ref
      Constructor gid -> role gid [ConstructorRole, RecordConstructorRole]
      Method gid -> role gid [MethodRole]
      Literal _ -> pure ()
      Hole _ -> pure () -- inference owns expression-hole rejection
      Apply a b -> expr a >> expr b
      TypeApply e ts -> nonempty ts >> expr e >> mapM_ (onNode ty) ts
      Annotated e bs t -> expr e >> binders bs (ty t)
      Lambda b e -> binder b >> withValues (Set.singleton (fst (nodeValue b))) (expr e)
      TypeLambda bs e -> nonempty bs >> binders bs (expr e)
      Match _ e cs -> expr e >> mapM_ matchClause cs
      Conditional cs -> nonempty cs >> mapM_ (onNode (\(c, e) -> mapM_ expr c >> expr e)) cs
      Sequence ss e -> statements ss (expr e)
      Where p g e -> do
        case p of AfterValueParameters n | n <= 0 -> bad "invalid where timing"; _ -> pure ()
        withTypes (groupTypeIds g) (withValues (groupIds g) (group g >> expr e))
      Project e selector -> expr e >> onNode validName selector
      PackRecord gid ts fs -> role gid [RecordConstructorRole] >> mapM_ (onNode (\(label, t) -> validName label >> ty t)) ts >> mapM_ assignment fs
      ConstructRecord gid fs -> role gid [RecordConstructorRole] >> mapM_ assignment fs
      UpdateRecord e fs -> expr e >> mapM_ assignment fs
      Product es -> mapM_ expr es
      List es -> mapM_ expr es
      Unit -> pure ()
      Negate e -> expr e
    nonempty :: [a] -> Check ()
    nonempty xs = unless (not (null xs)) (bad "unexpected empty Abstract sequence")
    assignment = onNode (\(label, e) -> validName label >> expr e)
    matchClause = onNode (\(p, g, e) -> patterns [p] (mapM_ expr g >> expr e))
    statements [] rest = rest
    statements (s : ss) rest =
      onNode
        ( \case
            Effect e -> expr e >> statements ss rest
            BindStatement g -> group g >> withTypes (groupTypeIds g) (withValues (groupIds g) (statements ss rest))
        )
        s
    groupTypeIds g = typeIds [b | d <- declarations g, PatternDefinition p _ <- [nodeValue d], b <- patternTypeBinders p]
    groupIds g = Set.fromList (concatMap declared (declarations g))
    declared d = case nodeValue d of
      ValueDefinition (LocalRef i) _ _ -> [i]
      PatternDefinition p _ -> patternIds p
      _ -> []
    group g = (if scopeMode g == Recursive then withValues (groupIds g) else id) (mapM_ declaration (declarations g))
    declaration = onNode $ \case
      ValueDefinition ref sig body -> do
        case ref of GlobalRef gid -> role gid [ValueRole, MethodRole]; LocalRef _ -> pure ()
        mapM_ scheme sig
        case body of
          BuiltinBody _ -> pure ()
          ClausesBody arity cs -> mapM_ (clause arity) cs
      PatternDefinition p e -> expr e >> patterns [p] (pure ())
      AliasDefinition gid bs k t -> role gid [AliasRole] >> mapM_ kind k >> binders bs (ty t)
      DataDefinition gid bs k cs -> role gid [DataRole] >> mapM_ kind k >> binders bs (mapM_ (onNode (\(c, ts) -> role c [ConstructorRole] >> mapM_ ty ts)) cs)
      RecordDefinition gid bs k ctor fs members -> role gid [RecordRole] >> role ctor [RecordConstructorRole] >> mapM_ kind k >> binders (bs ++ members) (mapM_ (onNode (\(label, t) -> validName label >> ty t)) fs)
      OpaqueBuiltinType gid _ k -> global gid >> kind k
      TraitDefinition gid b supers methods -> role gid [TraitRole] >> binders [b] (mapM_ predicate supers >> mapM_ declaration methods)
      MethodDefinition gid s -> role gid [MethodRole] >> scheme s
      ImplementationDefinition _ bs cs head' methods -> binders bs (mapM_ predicate cs >> predicate head' >> mapM_ declaration methods)
    clause arity c =
      onNode
        ( \cl -> do
            unless (length (clausePatterns cl) == arity) (bad "nonuniform written clause arity")
            unless (clauseWherePlan cl == (if arity == 0 then AtInitialization else AfterValueParameters arity)) (bad "invalid clause where timing")
            binders (clauseTypes cl) (patterns (clausePatterns cl) (withTypes (groupTypeIds (clauseWhere cl)) (withValues (groupIds (clauseWhere cl)) (group (clauseWhere cl) >> expr (clauseBody cl)))))
        )
        c
