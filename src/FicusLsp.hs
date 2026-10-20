-- | The Ficus language server. Protocol, editor state, overlays, and indexes are
-- confined to this module namespace; compiler passes remain ordinary libraries.
module FicusLsp (LspOptions (..), defaultOptions, run, serverDefinition) where

import Control.Lens ((^.))
import Control.Monad (forM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.Int (Int32)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Compile qualified as Compile
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source qualified as Source
import FicusLsp.Index qualified as Index
import FicusLsp.Protocol qualified as Protocol
import FicusLsp.Workspace
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message
import Language.LSP.Protocol.Types qualified as L
import Language.LSP.Server qualified as Server
import Language.LSP.VFS (virtualFileText, virtualFileVersion)
import System.FilePath (normalise)

data State = State
  { settings :: LspOptions,
    documents :: Map FilePath (Int32, Text),
    analysis :: Maybe Analysis,
    symbols :: Index.Index,
    published :: Set FilePath
  }

run :: LspOptions -> IO Int
run options = serverDefinition options >>= Server.runServer

serverDefinition :: LspOptions -> IO (Server.ServerDefinition ())
serverDefinition options = do
  configured <- normalizeOptions options
  state <- newIORef (State configured Map.empty Nothing Map.empty Set.empty)
  pure
    Server.ServerDefinition
      { Server.defaultConfig = (),
        Server.configSection = "ficus",
        Server.parseConfig = \_ _ -> Right (),
        Server.onConfigChange = \_ -> pure (),
        Server.doInitialize = \env request -> do
          let params = request ^. L.params
              folders = case params ^. L.workspaceFolders of Just (L.InL values) -> mapMaybe (L.uriToFilePath . (^. L.uri)) values; _ -> []
              root = case params ^. L.rootUri of L.InL uri -> maybe [] pure (L.uriToFilePath uri); _ -> []
              roots = if null (sourceRoots configured) then nub (if null folders then root else folders) else sourceRoots configured
          normalized <- normalizeOptions (configured {sourceRoots = roots})
          modifyIORef' state (\current -> current {settings = normalized})
          pure (Right env),
        Server.staticHandlers = handlers state (null (sourceRoots configured)),
        -- The library dispatches these handlers serially. VFS edits, analysis,
        -- publication and queries therefore observe one ordered snapshot.
        Server.interpretHandler = \env -> Server.Iso (Server.runLspT env) liftIO,
        Server.options =
          Server.defaultOptions
            { Server.optTextDocumentSync = Just (L.TextDocumentSyncOptions (Just True) (Just L.TextDocumentSyncKind_Incremental) (Just False) (Just False) (Just (L.InR (L.SaveOptions (Just False))))),
              Server.optServerInfo = Just (L.ServerInfo "ficus" Nothing)
            }
      }

handlers :: IORef State -> Bool -> L.ClientCapabilities -> Server.Handlers (Server.LspM ())
handlers state workspaceRoots capabilities =
  mconcat
    [ Server.notificationHandler SMethod_Initialized $ \_ -> do
        when (dynamic == Just True) $
          void $
            Server.registerCapability
              mempty
              SMethod_WorkspaceDidChangeWatchedFiles
              (L.DidChangeWatchedFilesRegistrationOptions [L.FileSystemWatcher (L.GlobPattern (L.InL (L.Pattern "**/*.ficus"))) Nothing])
              (\_ -> recheck state),
      Server.notificationHandler SMethod_TextDocumentDidOpen $ \message -> syncDocument state (message ^. L.params . L.textDocument . L.uri),
      Server.notificationHandler SMethod_TextDocumentDidChange $ \message -> syncDocument state (message ^. L.params . L.textDocument . L.uri),
      Server.notificationHandler SMethod_TextDocumentDidSave $ \_ -> recheck state,
      Server.notificationHandler SMethod_TextDocumentDidClose $ \message -> do
        forM_ (filePath (message ^. L.params . L.textDocument . L.uri)) $ \file -> liftIO (modifyIORef' state (\current -> current {documents = Map.delete file (documents current)}))
        recheck state,
      Server.notificationHandler SMethod_WorkspaceDidChangeWorkspaceFolders $ \message -> when workspaceRoots $ do
        let event = message ^. L.params . L.event
            removed = mapMaybe (filePath . (^. L.uri)) (event ^. L.removed)
            added = mapMaybe (filePath . (^. L.uri)) (event ^. L.added)
        liftIO (modifyIORef' state (\current -> let old = settings current in current {settings = old {sourceRoots = nub (filter (`notElem` removed) (sourceRoots old) ++ added)}}))
        recheck state,
      Server.requestHandler SMethod_TextDocumentHover $ \request respond -> do
        current <- liftIO (readIORef state)
        let params = request ^. L.params
            result = do
              (file, source) <- documentSource current (params ^. L.textDocument . L.uri)
              Protocol.hoverAt source (Map.findWithDefault [] file (symbols current)) (params ^. L.position)
        respond (Right (maybe (L.InR L.Null) L.InL result)),
      Server.requestHandler SMethod_TextDocumentDefinition $ \request respond -> do
        current <- liftIO (readIORef state)
        let params = request ^. L.params
            result = do
              (file, source) <- documentSource current (params ^. L.textDocument . L.uri)
              Protocol.definitionAt (sources current) source (Map.findWithDefault [] file (symbols current)) (params ^. L.position)
        respond (Right (maybe (L.InR (L.InR L.Null)) (L.InL . L.Definition . L.InL) result)),
      Server.requestHandler SMethod_TextDocumentSemanticTokensFull $ \request respond -> do
        current <- liftIO (readIORef state)
        let result = case documentSource current (request ^. L.params . L.textDocument . L.uri) of
              Nothing -> Right (L.SemanticTokens Nothing [])
              Just (file, source) -> Protocol.semanticTokens file source (Map.findWithDefault [] file (symbols current))
        respond (case result of Right tokens -> Right (L.InL tokens); Left message -> Left (TResponseError (L.InR L.ErrorCodes_InternalError) message Nothing))
    ]
    <> if dynamic == Just True then mempty else Server.notificationHandler SMethod_WorkspaceDidChangeWatchedFiles (\_ -> recheck state)
  where
    -- The lsp library deliberately refuses to register a method dynamically
    -- when it already has a static handler for that method.
    dynamic = capabilities ^. L.workspace >>= (^. L.didChangeWatchedFiles) >>= (^. L.dynamicRegistration)

filePath :: L.Uri -> Maybe FilePath
filePath = fmap normalise . L.uriToFilePath

sources :: State -> Documents
sources current = Map.map snd (documents current) `Map.union` maybe Map.empty (Compile.compileSources . compilation) (analysis current)

documentSource :: State -> L.Uri -> Maybe (FilePath, Text)
documentSource current uri = do
  file <- filePath uri
  text <- Map.lookup file (sources current)
  pure (file, text)

syncDocument :: IORef State -> L.Uri -> Server.LspM () ()
syncDocument state uri = do
  virtual <- Server.getVirtualFile (L.toNormalizedUri uri)
  case (filePath uri, virtual) of
    (Just file, Just value) -> do
      liftIO (modifyIORef' state (\current -> current {documents = Map.insert file (virtualFileVersion value, virtualFileText value) (documents current)}))
      recheck state
    _ -> pure ()

recheck :: IORef State -> Server.LspM () ()
recheck state = do
  previous <- liftIO (readIORef state)
  checked <- liftIO (analyze (settings previous) (Map.map snd (documents previous)))
  let sourceTexts = Compile.compileSources (compilation checked)
      errors = Map.fromListWith (++) [(Source.sourceFile (D.diagnosticSpan problem), [Protocol.diagnostic sourceTexts problem]) | problem <- diagnostics checked]
      nextPublished = Map.keysSet errors `Set.union` Map.keysSet (documents previous)
      current = previous {analysis = Just checked, symbols = Index.buildIndex (compilation checked), published = nextPublished}
  liftIO (writeIORef state current)
  forM_ (Set.toAscList (published previous `Set.union` nextPublished)) $ \file -> do
    let version = fst <$> Map.lookup file (documents current)
    Server.sendNotification SMethod_TextDocumentPublishDiagnostics (L.PublishDiagnosticsParams (L.filePathToUri file) version (Map.findWithDefault [] file errors))
