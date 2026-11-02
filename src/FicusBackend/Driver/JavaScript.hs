-- | The JS driver shares entry checking and lowering with the interpreter.
module FicusBackend.Driver.JavaScript (compileJavaScript) where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile (CompileResult)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Syntax.Name (ModuleId)
import FicusBackend.Driver.Run (ReturnForm (..), prepareEntry)
import FicusBackend.JavaScript.Emit
import FicusBackend.Lower.Runtime (loweredProgram)
import FicusBackend.Pass.Normalize (validateNormalized)
import FicusBackend.Runtime.AST (ConstructorIndex (..), GlobalIndex (..))
import FicusBackend.Runtime.Validate (validatedProgram)

-- | Supply the installed runtime/javascript.mjs support source. The result
-- embeds it completely; the output has no dependency on the compiler install.
compileJavaScript :: Text -> ModuleId -> CompileResult -> Either [D.Diagnostic] Text
compileJavaScript runtime owner result = do
  (lowered, GlobalIndex entry, form, _) <- prepareEntry owner result
  normalized <- either (Left . map D.toDiagnostic) Right (validateNormalized (validatedProgram (loweredProgram lowered)))
  let finish = case form of
        UnitReturn -> "if(result!==null)throw new Error('entry returned an invalid runtime representation');"
        ResultReturn (ConstructorIndex err) (ConstructorIndex ok) ->
          T.unlines
            [ "if(result&&result.tag===" <> number err <> "){fs.writeSync(2,result.fields[0]+'\\n');process.exitCode=1;}",
              "else if(!result||result.tag!==" <> number ok <> "||result.fields[0]!==null)throw new Error('entry returned an invalid runtime representation');"
            ]
  pure
    ( runtime
        <> "\n"
        <> emitProgram normalized
        <> T.unlines
          [ "try {",
            "const run=createProgram();",
            "const result=run(" <> number entry <> ",[list(process.argv.slice(2))]);",
            finish,
            "}catch(error){fs.writeSync(2,'error[R0001]: '+error.message+'\\n');process.exitCode=1;}"
          ]
    )
  where
    number = T.pack . show
