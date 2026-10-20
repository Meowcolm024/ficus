-- Exercise the real Haskell lsp transport, VFS, dispatch and lifecycle over
-- pipes. The client speaks JSON-RPC so no server implementation is mocked.
module FicusLsp.ProtocolSpec (tests) where

import Control.Concurrent (ThreadId, forkFinally, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, fromException)
import Control.Monad (void)
import Data.Aeson qualified as J
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import FicusLsp qualified as Lsp
import Language.LSP.Server (runServerWithHandles)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hFlush)
import System.IO.Error (tryIOError)
import System.Process (createPipe)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Text.Read (readMaybe)

data Client = Client {input :: Handle, output :: Handle, serverInput :: Handle, serverOutput :: Handle, thread :: ThreadId, exited :: IO (Either SomeException Int), history :: IORef [J.Value]}

tests :: TestTree
tests =
  testGroup
    "LSP transport"
    [ testCase "initialize, unsaved edits, queries, diagnostic clearing and shutdown" $
        bracket start stop $ \client -> do
          completed <- timeout 15000000 (session client)
          case completed of Just () -> pure (); Nothing -> readIORef (history client) >>= assertFailure . show . reverse
    ]

start :: IO Client
start = do
  (serverRead, clientWrite) <- createPipe
  (clientRead, serverWrite) <- createPipe
  definition <- Lsp.serverDefinition Lsp.defaultOptions
  done <- newEmptyMVar
  exchanges <- newIORef []
  ident <- forkFinally (runServerWithHandles mempty mempty serverRead serverWrite definition) (putMVar done)
  pure (Client clientRead clientWrite serverRead serverWrite ident (takeMVar done) exchanges)

stop :: Client -> IO ()
stop client = do
  killThread (thread client)
  mapM_ (void . tryIOError . hClose) [input client, output client, serverInput client, serverOutput client]

session :: Client -> Assertion
session client = do
  initialize <- request client 1 "initialize" (J.object ["processId" J..= J.Null, "rootUri" J..= ("file:///ficus-lsp-wire" :: Text), "capabilities" J..= J.object ["workspace" J..= J.object ["didChangeWatchedFiles" J..= J.object ["dynamicRegistration" J..= True]]]])
  let capability name = at "result" initialize >>= at "capabilities" >>= at name
      provided value = case value of Just (J.Bool True) -> True; Just (J.Object _) -> True; _ -> False
  assertBool "hover capability" (provided (capability "hoverProvider"))
  assertBool "definition capability" (provided (capability "definitionProvider"))
  assertBool "semantic token capability" (case capability "semanticTokensProvider" of Just (J.Object _) -> True; _ -> False)
  notify client "initialized" (J.object [])
  registration <- receiveUntil client (\value -> at "method" value == Just (J.String "client/registerCapability"))
  case at "params" registration >>= at "registrations" of
    Just (J.Array values) -> case V.toList values of
      [value] -> at "method" value @?= Just (J.String "workspace/didChangeWatchedFiles")
      other -> assertFailure (show other)
    other -> assertFailure (show other)
  send client (J.object ["jsonrpc" J..= ("2.0" :: Text), "id" J..= at "id" registration, "result" J..= J.Null])
  let uri = "file:///ficus-lsp-wire/Main.ficus" :: Text
      document = J.object ["uri" J..= uri]
      source = "{-# NO_IMPLICIT_PRELUDE #-}\nidentity x = x\ncheck () = identity 1\n" :: Text
  notify client "textDocument/didOpen" (J.object ["textDocument" J..= J.object ["uri" J..= uri, "languageId" J..= ("ficus" :: Text), "version" J..= (1 :: Int), "text" J..= source]])
  first <- diagnostics client
  (at "params" first >>= at "diagnostics") @?= Just (J.Array V.empty)
  hover <- request client 2 "textDocument/hover" (J.object ["textDocument" J..= document, "position" J..= position 2 14])
  (at "result" hover >>= at "contents" >>= at "value") @?= Just (J.String "```ficus\nidentity : a -> a\n```")
  definition <- request client 3 "textDocument/definition" (J.object ["textDocument" J..= document, "position" J..= position 2 14])
  (at "result" definition >>= at "uri") @?= Just (J.String uri)
  (at "result" definition >>= at "range") @?= Just (range 1 0 1 8)
  tokens <- request client 4 "textDocument/semanticTokens/full" (J.object ["textDocument" J..= document])
  assertBool "encoded semantic tokens" (case at "result" tokens >>= at "data" of Just (J.Array values) -> not (V.null values) && V.length values `mod` 5 == 0; _ -> False)
  change client document 2 [J.object ["text" J..= ("{-# NO_IMPLICIT_PRELUDE #-}\nbad = missing\n" :: Text)]]
  failed <- diagnostics client
  (at "params" failed >>= at "version") @?= Just (J.toJSON (2 :: Int))
  case at "params" failed >>= at "diagnostics" of
    Just (J.Array values) -> case V.toList values of
      [problem] -> do
        at "code" problem @?= Just (J.String "N0001")
        at "severity" problem @?= Just (J.toJSON (1 :: Int))
        at "range" problem @?= Just (range 1 6 1 13)
      other -> assertFailure (show other)
    other -> assertFailure (show other)
  stale <- request client 5 "textDocument/hover" (J.object ["textDocument" J..= document, "position" J..= position 2 14])
  at "result" stale @?= Just J.Null
  change client document 3 [J.object ["range" J..= range 1 6 1 13, "text" J..= ("1" :: Text)]]
  repaired <- diagnostics client
  (at "params" repaired >>= at "diagnostics") @?= Just (J.Array V.empty)
  repairedHover <- request client 6 "textDocument/hover" (J.object ["textDocument" J..= document, "position" J..= position 1 1])
  (at "result" repairedHover >>= at "contents" >>= at "value") @?= Just (J.String "```ficus\nbad : Int\n```")
  change client document 4 [J.object ["text" J..= ("{-# NO_IMPLICIT_PRELUDE #-}\nvalue = \"😀\"\ncopy = value\n" :: Text)]]
  void (diagnostics client)
  change client document 5 [J.object ["range" J..= range 1 9 1 11, "text" J..= ("ab" :: Text)]]
  unicode <- diagnostics client
  (at "params" unicode >>= at "diagnostics") @?= Just (J.Array V.empty)
  notify client "textDocument/didClose" (J.object ["textDocument" J..= document])
  closed <- diagnostics client
  (at "params" closed >>= at "diagnostics") @?= Just (J.Array V.empty)
  gone <- request client 7 "textDocument/hover" (J.object ["textDocument" J..= document, "position" J..= position 1 1])
  at "result" gone @?= Just J.Null
  let otherUri = "file:///ficus-lsp-second/Other.ficus" :: Text
      otherDocument = J.object ["uri" J..= otherUri]
  notify client "textDocument/didOpen" (J.object ["textDocument" J..= J.object ["uri" J..= otherUri, "languageId" J..= ("ficus" :: Text), "version" J..= (1 :: Int), "text" J..= ("{-# NO_IMPLICIT_PRELUDE #-}\nvalue = 1\n" :: Text)]])
  outside <- diagnostics client
  case at "params" outside >>= at "diagnostics" of
    Just (J.Array values) -> map (at "code") (V.toList values) @?= [Just (J.String "N0202")]
    other -> assertFailure (show other)
  notify client "workspace/didChangeWorkspaceFolders" (J.object ["event" J..= J.object ["added" J..= [J.object ["uri" J..= ("file:///ficus-lsp-second" :: Text), "name" J..= ("second" :: Text)]], "removed" J..= ([] :: [J.Value])]])
  included <- diagnostics client
  (at "params" included >>= at "diagnostics") @?= Just (J.Array V.empty)
  notify client "workspace/didChangeWatchedFiles" (J.object ["changes" J..= [J.object ["uri" J..= otherUri, "type" J..= (2 :: Int)]]])
  watched <- diagnostics client
  (at "params" watched >>= at "diagnostics") @?= Just (J.Array V.empty)
  folderHover <- request client 9 "textDocument/hover" (J.object ["textDocument" J..= otherDocument, "position" J..= position 1 1])
  (at "result" folderHover >>= at "contents" >>= at "value") @?= Just (J.String "```ficus\nvalue : Int\n```")
  shutdown <- request client 8 "shutdown" J.Null
  at "result" shutdown @?= Just J.Null
  notify client "exit" J.Null
  exited client >>= \case
    Left problem -> case fromException problem of Just ExitSuccess -> pure (); _ -> assertFailure (show problem)
    Right status -> status @?= 0

position :: Int -> Int -> J.Value
position line column = J.object ["line" J..= line, "character" J..= column]

range :: Int -> Int -> Int -> Int -> J.Value
range a b c d = J.object ["start" J..= position a b, "end" J..= position c d]

at :: Key -> J.Value -> Maybe J.Value
at key (J.Object value) = KM.lookup key value
at _ _ = Nothing

request :: Client -> Int -> Text -> J.Value -> IO J.Value
request client ident method params = do
  send client (J.object ["jsonrpc" J..= ("2.0" :: Text), "id" J..= ident, "method" J..= method, "params" J..= params])
  receiveUntil client (\value -> at "id" value == Just (J.toJSON ident))

notify :: Client -> Text -> J.Value -> IO ()
notify client method params = send client (J.object ["jsonrpc" J..= ("2.0" :: Text), "method" J..= method, "params" J..= params])

change :: Client -> J.Value -> Int -> [J.Value] -> IO ()
change client document version changes = case document of
  J.Object value -> notify client "textDocument/didChange" (J.object ["textDocument" J..= J.Object (KM.insert "version" (J.toJSON version) value), "contentChanges" J..= changes])
  _ -> assertFailure "invalid test document"

diagnostics :: Client -> IO J.Value
diagnostics client = receiveUntil client (\value -> at "method" value == Just (J.String "textDocument/publishDiagnostics"))

send :: Client -> J.Value -> IO ()
send client value = do
  modifyIORef' (history client) (J.object ["sent" J..= value] :)
  let bytes = J.encode value
  BSC.hPutStr (output client) (BSC.pack ("Content-Length: " <> show (BL.length bytes) <> "\r\n\r\n"))
  BL.hPut (output client) bytes
  hFlush (output client)

receiveUntil :: Client -> (J.Value -> Bool) -> IO J.Value
receiveUntil client predicate = do
  size <- headers Nothing
  bytes <- BS.hGet (input client) size
  case J.eitherDecodeStrict' bytes of
    Left message -> assertFailure message >> fail message
    Right value -> do
      modifyIORef' (history client) (J.object ["received" J..= value] :)
      if predicate value then pure value else receiveUntil client predicate
  where
    headers size = do
      line <- BSC.hGetLine (input client)
      case BSC.words line of
        [] -> maybe (fail "missing Content-Length") pure size
        ["Content-Length:", count] -> headers (readMaybe (BSC.unpack count))
        _ -> headers size
