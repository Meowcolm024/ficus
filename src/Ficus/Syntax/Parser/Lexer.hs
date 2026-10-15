module Ficus.Syntax.Parser.Lexer (lexSource, eofSpan) where

import Control.Monad (void, when)
import Data.Char (isAlphaNum, isLower, isSpace, isUpper)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Parser
import Ficus.Syntax.Token
import Ficus.Util.Source
import Text.Megaparsec hiding (Token, sourceName, tokens)
import Text.Megaparsec.Char

type Lexer = Parsec Diagnostic Text

position :: Lexer Position
position = do
  p <- getSourcePos
  o <- getOffset
  pure (Position (unPos (sourceLine p)) (unPos (sourceColumn p)) o)

spanFrom :: FilePath -> Position -> Lexer Span
spanFrom file a = do
  b <- position
  pure (Span file a (if offset b > offset a then b {column = column b - 1, offset = offset b - 1} else b))

failureAt :: ParserErrorCode -> Span -> Text -> Lexer a
failureAt code s msg = customFailure (Diagnostic code s msg)

operatorChar :: Char -> Bool
operatorChar c = c `elem` ("!#$%&*+/<=>?@\\^|-~:." :: String)

identChar :: Char -> Bool
identChar c = isAlphaNum c || c == '_' || c == '\''

lexSource :: FilePath -> Text -> Either Diagnostic ([Token], [Comment])
lexSource file input = case snd (runParser' (scan <* eof) initialState) of
  Left bundle -> case bundleErrors bundle of
    FancyError _ es :| _ -> case [d | ErrorCustom d <- foldr (:) [] es] of
      d : _ -> Left d
      [] -> Left fallback
    _ -> Left fallback
  Right result -> Right result
  where
    initialState = State input 0 (PosState input 0 (initialPos file) (mkPos tabWidth) "") []
    fallback = Diagnostic InvalidSourceCharacter (eofSpan file input) "invalid source character"
    scan = do
      comments <- trivia
      done <- atEnd
      if done
        then pure ([], comments)
        else do
          rest <- getInput
          if "{-#" `T.isPrefixOf` rest
            then do
              open <- fixed "{-#" Punctuation
              beforeName <- trivia
              missingName <- atEnd
              when missingName (failureAt UnterminatedPragma (tokenSpan open) "unterminated pragma")
              nameStart <- position
              nameText <- takeWhile1P (Just "pragma name") identChar
              ns <- spanFrom file nameStart
              when (not (validPragmaName nameText)) (failureAt InvalidPragmaName ns "expected ALL_CAPITAL pragma name")
              let nameToken = Token PragmaName nameText ns
              (inside, cs) <- pragmaTokens (tokenSpan open)
              (after, following) <- scan
              pure (open : nameToken : inside ++ after, comments ++ beforeName ++ cs ++ following)
            else do
              t <- ordinary
              (ts, following) <- scan
              pure (t : ts, comments ++ following)
    -- Comments have the same lexical meaning inside and outside pragmas.
    trivia = do
      void (takeWhileP Nothing isSpace)
      rest <- getInput
      a <- position
      if "{-" `T.isPrefixOf` rest && not ("{-#" `T.isPrefixOf` rest)
        then do
          void (chunk "{-")
          body <- takeWhileUntil "-}" (Span file a (a {column = column a + 1, offset = offset a + 1}))
          s <- spanFrom file a
          cs <- trivia
          pure (Comment ("{-" <> body <> "-}") s : cs)
        else
          if lineComment rest
            then do
              body <- takeWhileP Nothing (/= '\n')
              s <- spanFrom file a
              cs <- trivia
              pure (Comment body s : cs)
            else pure []
    pragmaTokens opening = do
      comments <- trivia
      rest <- getInput
      if "#-}" `T.isPrefixOf` rest
        then do
          close <- fixed "#-}" Punctuation
          pure ([close], comments)
        else
          if T.null rest
            then failureAt UnterminatedPragma opening "unterminated pragma"
            else do
              t <- ordinary
              (ts, cs) <- pragmaTokens opening
              pure (t : ts, comments ++ cs)
    fixed txt kind = do
      a <- position
      void (chunk txt)
      Token kind txt <$> spanFrom file a
    ordinary = do
      a <- position
      rest <- getInput
      case T.uncons rest of
        Just (c, _) | isLower c || isUpper c || c == '_' -> do
          txt <- takeWhile1P Nothing identChar
          let kind
                | txt `elem` ["use", "type", "trait", "impl", "with", "if", "where", "do"] = Keyword
                | isUpper c = Upper
                | otherwise = Lower
          Token kind txt <$> spanFrom file a
        Just (c, _) | c >= '0' && c <= '9' -> do
          whole <- takeWhile1P Nothing (\x -> x >= '0' && x <= '9')
          frac <- optional (try (char '.' *> lookAhead digitChar *> takeWhile1P Nothing (\x -> x >= '0' && x <= '9')))
          Token NumberLiteral (whole <> maybe "" ("." <>) frac) <$> spanFrom file a
        Just ('"', _) -> literal '"' StringLiteral
        Just ('\'', _) -> literal '\'' CharacterLiteral
        Just (c, _) | c `elem` ("()[]{},;" :: String) -> fixed (T.singleton c) Punctuation
        Just ('.', _) -> if ".." `T.isPrefixOf` rest then fixed ".." Punctuation else fixed "." Punctuation
        Just (c, _) | operatorChar c -> do
          txt <- takeWhile1P Nothing (\x -> operatorChar x && x /= '.')
          suffix <- embedded
          let full = txt <> suffix
          Token (if full `elem` ["@", ":", "=", "->", "<-", "=>"] then Punctuation else Symbol) full <$> spanFrom file a
        _ -> do
          void anySingle
          s <- spanFrom file a
          failureAt InvalidSourceCharacter s "invalid source character"
    embedded = do
      rest <- getInput
      case T.unpack (T.take 2 rest) of
        ['.', c] | operatorChar c && c /= '.' -> do
          void (char '.')
          txt <- takeWhile1P Nothing (\x -> operatorChar x && x /= '.')
          more <- embedded
          pure ("." <> txt <> more)
        _ -> pure ""
    literal quote kind = do
      a <- position
      void (char quote)
      characterCount <- contents quote a (0 :: Int)
      s <- spanFrom file a
      when (kind == CharacterLiteral && characterCount /= 1) (failureAt InvalidCharacterLiteral s "character literal must contain one character")
      b <- getOffset
      pure (Token kind (T.take (b - offset a) (T.drop (offset a) input)) s)
    contents quote a n = do
      rest <- getInput
      case T.uncons rest of
        Nothing -> spanFrom file a >>= \s -> failureAt UnterminatedLiteral s "unterminated literal"
        Just ('\n', _) -> spanFrom file a >>= \s -> failureAt UnterminatedLiteral s "unterminated literal"
        Just (c, _) | c == quote -> anySingle *> pure n
        Just ('\\', _) -> do
          esc <- position
          void anySingle
          c <- optional anySingle
          s <- spanFrom file esc
          when
            (maybe True (\x -> x `notElem` ("\\'\"nrt" <> if quote == '"' then "{}" else "" :: String)) c)
            (failureAt InvalidEscape s "invalid escape")
          contents quote a (n + 1)
        Just ('{', _) | quote == '"' -> do
          brace <- position
          void anySingle
          doubled <- optional (char '{')
          case doubled of
            Just _ -> contents quote a (n + 1)
            Nothing -> do
              body <- takeWhileP Nothing (\c -> c /= '}' && c /= '"' && c /= '\n')
              close <- optional (char '}')
              s <- spanFrom file brace
              when (close == Nothing) (failureAt UnmatchedInterpolationBrace (Span file brace brace) "unmatched opening brace")
              when (not (validInterpolation body)) (failureAt InvalidInterpolation s "expected lowercase interpolation name, optionally module-qualified")
              contents quote a (n + 1)
        Just ('}', _) | quote == '"' -> do
          brace <- position
          void anySingle
          doubled <- optional (char '}')
          when (doubled == Nothing) (failureAt UnmatchedInterpolationBrace (Span file brace brace) "unmatched closing brace")
          contents quote a (n + 1)
        _ -> anySingle *> contents quote a (n + 1)
    takeWhileUntil closing opening = do
      body <- manyTill anySingle (lookAhead (void (chunk closing) <|> eof))
      found <- optional (chunk closing)
      when (found == Nothing) (failureAt UnterminatedBlockComment opening "unterminated block comment")
      pure (T.pack body)

lineComment :: Text -> Bool
lineComment txt = case T.stripPrefix "--" txt of
  Nothing -> False
  Just rest -> maybe True (not . operatorChar . fst) (T.uncons rest)

validPragmaName :: Text -> Bool
validPragmaName txt = case T.uncons txt of
  Just (c, cs) -> asciiUpper c && T.all (\x -> asciiUpper x || x >= '0' && x <= '9' || x == '_') cs
  Nothing -> False
  where
    asciiUpper c = c >= 'A' && c <= 'Z'

validInterpolation :: Text -> Bool
validInterpolation txt = case reverse (T.splitOn "." txt) of
  value : modules -> lower value && all upper modules
  [] -> False
  where
    lower t = maybe False (\(c, cs) -> (isLower c || c == '_') && T.all identChar cs && t `notElem` ["use", "type", "trait", "impl", "with", "if", "where", "do"]) (T.uncons t)
    upper t = maybe False (\(c, cs) -> isUpper c && T.all identChar cs) (T.uncons t)

eofSpan :: FilePath -> Text -> Span
eofSpan = sourceEndSpan
