{-# LANGUAGE ExistentialQuantification #-}
import System.Environment
import Data.Char (toLower)
import Data.Ratio
import Data.Complex
import Data.Array
import Control.Monad
import Control.Monad.Error
import System.IO
import Data.IORef
import Text.ParserCombinators.Parsec hiding (spaces)
import Numeric

data LispVal = Atom String
             | List [LispVal]
             | DottedList [LispVal] LispVal
             | Number Integer
             | Float Double
             | Rational Rational
             | Complex (Complex Float)
             | String String
             | Vector (Array Int LispVal)
             | Bool Bool
             | Char Char
             | PrimitiveFunc ([LispVal] -> ThrowsError LispVal)
             | IOFunc ([LispVal] -> IOThrowsError LispVal)
             | Port Handle
             | Func { params :: [String], vararg :: (Maybe String),
                      body :: [LispVal], closure :: Env}

data LispError = NumArgs Integer [LispVal]
               | TypeMismatch String LispVal
               | Parser ParseError
               | BadSpecialForm String LispVal
               | NotFunction String String
               | UnboundVar String String
               | Assert String
               | Default String

showError :: LispError -> String
showError (UnboundVar message varname) = message ++ ": " ++ varname
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func) = message ++ ": " ++ show func
showError (NumArgs expected found) = "Expected " ++ show expected ++ " args; found values" ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected" ++ expected ++ ", found" ++ show found
showError (Parser parseErr) = "Parse error at" ++ show parseErr
showError (Assert parseErr) = "Assertion failed"

instance Show LispError where
  show = showError

instance Error LispError where
  noMsg = Default "An error has occured"
  strMsg = Default

type ThrowsError = Either LispError

trapError :: (Show a, MonadError a m) => m String -> m String
trapError action = catchError action (return . show)

extractValue :: ThrowsError a -> a
extractValue (Right val) = val

parseExpr :: Parser LispVal
parseExpr = try parseRational
        <|> try parseComplex
        <|> try parseNumber
        <|> try parseDec
        <|> parseString
        <|> try parseChar
        <|> parseAtom
        <|> parseQuoted
        <|> parseVector
        <|> do
              char '('
              x <- try parseList <|> parseDottedList
              char ')'
              return x
        <|> parseQuasiQuote

showVal :: LispVal -> String
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Char char) = char:[]
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (List contents) = "(" ++ unwordsList contents ++")"
showVal (DottedList head tail) = "(" ++ unwordsList head
                                     ++  "."
                                     ++ showVal tail
                                     ++ ")"
showVal (PrimitiveFunc _) = "<primitive>"
showVal (Port _) = "<IO port>"
showVal (IOFunc _) = "<IO primitive>"
showVal (Func {params = args, vararg = varargs, body = body, closure = env}) =
  "(lambda (" ++ unwords (map show args) ++
    (case varargs of
       Nothing -> ""
       Just arg -> " . " ++ arg) ++ ") ...)"

instance Show LispVal where
    show = showVal

unwordsList :: [LispVal] -> String
unwordsList = unwords . map showVal

readOrThrow :: Parser a -> String -> ThrowsError a
readOrThrow parser input = case parse parser "lisp" input of
    Left err  -> throwError $ Parser err
    Right val -> return val

readExpr :: String -> ThrowsError LispVal
readExpr = readOrThrow parseExpr
readExprList = readOrThrow (endBy parseExpr spaces)

spaces :: Parser ()
spaces = skipMany1 space

symbol :: Parser Char
symbol = oneOf "!$%&|*+-/:<=?>@i^_~#"

escapeChars =
  do
    char '\\'
    x <- oneOf ['"', '\\', 'n', 'r', 't']
    return $ (case x of
             '\\' -> '\\'
             '"' -> '"'
             'n'-> '\n'
             'r'-> '\r'
             't'-> '\t')

parseString :: Parser LispVal
parseString =
  do
    char '"'
    x <- many (escapeChars <|> noneOf "\"")
    char '"'
    return (String x)

parseAtom :: Parser LispVal
parseAtom =
  do
    first <- letter <|> symbol
    rest <- many (letter <|> digit <|> symbol)
    let atom = [first] ++ rest
    return $ case atom of
         "#t" -> Bool True
         "#f" -> Bool False
         otherwise -> Atom atom

parseNumber :: Parser LispVal
parseNumber = (liftM (Number . read) $ many1 digit ) <|> try parseHex <|> parseOct

parseHex :: Parser LispVal
parseHex = string "#x">> many (oneOf "0123456789abcdefABCDEF") >>= return . Number . fst . head . readHex

parseOct :: Parser LispVal
parseOct = string "#o" >> many (oneOf "01234567") >>= return . Number . fst . head . readOct

parseDec :: Parser LispVal
parseDec = string "#d" >> many (oneOf "0123456789.") >>= return . Float . rf
  where
    rf = read :: String -> Double

parseComplex :: Parser LispVal
parseComplex =
  do
    x <- many $ oneOf "0123456789."
    oneOf "+-"
    y <- many $ oneOf "0123456789."
    char 'i'
    return . Complex $ (read x :: Float) :+ (read y :: Float)

parseRational :: Parser LispVal
parseRational =
  do
    x <- many digit
    char '/'
    y <- many digit
    return . Rational $ (read x :: Integer) % (read y :: Integer)

parseChar :: Parser LispVal
parseChar =
  do
    string "#\\"
    x <- many1 letter
    return . Char $ case (map toLower x) of
            "newline" -> '\n'
            "space" -> ' '
            " " -> ' '
            [y] -> head x

parseList :: Parser LispVal
parseList = liftM List $ sepBy parseExpr spaces

parseDottedList :: Parser LispVal
parseDottedList =
  do
    head <- endBy parseExpr spaces
    tail <- char '.' >> spaces >> parseExpr
    return $ DottedList head tail

parseQuoted :: Parser LispVal
parseQuoted =
  do
    char '\''
    x <- parseExpr
    return $ List [Atom "quote", x]

parseQuasiQuote :: Parser LispVal
parseQuasiQuote =
  do
    char '`'
    char '('
    xs <- liftM List $ sepBy (try parseExpr <|> parseComma) spaces
    char ')'
    return $ List [Atom "quasiquote", xs]
  where
    parseComma :: Parser LispVal
    parseComma = do
                  char ','
                  x <- parseExpr
                  return $ List [Atom "unquote", x]

{-Come back later to this after reading about sets!-}
parseVector :: Parser LispVal
parseVector =
  do
    string "#("
    elems <- sepBy parseExpr spaces
    char ')'
    return . Vector $ listArray (0, (length elems) - 1 ) elems

eval :: Env -> LispVal -> IOThrowsError LispVal
eval env (List (Atom "define" : List (Atom var : params ) : body)) =
  makeNormalFunc env params body >>= defineVar env var
eval env (List (Atom "define" : DottedList (Atom var : params) varargs : body)) =
  makeVarArgs varargs env params body >>= defineVar env var
eval env (List (Atom "lambda" : List params : body)) =
  makeNormalFunc env params body
eval env (List (Atom "lambda" : DottedList params varargs : body)) =
  makeVarArgs varargs env params body
eval env (List (Atom "lambda" : varargs@(Atom _) : body)) =
  makeVarArgs varargs env [] body
eval env val@(Char _) = return val
eval env val@(String _) = return val
eval env val@(Number _) = return val
eval env val@(Bool _) = return val
eval env val@(Atom "else") = return $ Bool True
eval env (Atom var) = getVar env var
eval env (List [Atom "load", String filename]) =
    load filename >>= liftM last . mapM (eval env)
eval env (List [Atom "quote", val]) = return val
eval env (List [Atom "if", pred, conseq, alt]) =
  do
    result <- eval env pred
    x <- case result of
          Bool True -> (eval env conseq)
          Bool False -> (eval env alt)
    return x

eval env (List [Atom "set!", Atom var, form]) =
     eval env form >>= setVar env var

eval env (List [Atom "define", Atom var, form]) =
     eval env form >>= defineVar env var

-- For now it relies on eval 'else to return true. I am not sure if that's the
-- best way to go about this.
eval env (List (Atom "cond": args)) = (filterM f args) >>= (eval env) . clause . head
  where
    clause (List [_, c ]) = c
    unbool (Bool b) = b
    f arg = let
              List [condition, _] = arg
            in
              (eval env condition) >>= return . unbool

eval env (List (Atom "case" : key : clauses )) =
  do
    evalKey <- eval env key
    result <- let
                unbool (Bool b) = b
                memv el (List xs) =  liftM (any ((== True) . unbool)) . sequence $ (\x -> eqv [el, x]) <$> xs
                compareDatum key (List (datum:_)) = memv key datum
              in
                case (last clauses) of
                  val@(List [Atom "else", key]) -> case (liftM null $ clausesWithoutElse) of
                                                     Right True -> liftThrows $ Right [val]
                                                     _ -> liftThrows $ filterM (compareDatum evalKey) (init clauses)
                                                     where
                                                        clausesWithoutElse = filterM (compareDatum evalKey) (init clauses)
                  _ -> liftThrows $ filterM (compareDatum evalKey) clauses
    let List (datum:ckey:[]) = head result in (eval env ckey)

eval env (List (function : args)) = do
  func <- eval env function
  argVals <- mapM (eval env) args
  apply func argVals

eval env badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

isNumber, isList, isSymbol, isString, isBoolean, notOp, symbolToString, stringToSymbol :: LispVal -> ThrowsError LispVal
isNumber (Number _) = return $ Bool True
isNumber (_) = return $ Bool False

isList (List _) = return $ Bool True
isList (_) = return $ Bool False

isSymbol (Atom _) = return $ Bool True
isSymbol (List [Atom "quote", _]) = return $ Bool True
isSymbol (_) = return $ Bool False

isString (String _) = return $ Bool True
isString (_) = return $ Bool False

isBoolean (Bool _) = return $ Bool True
isBoolean (_) = return $ Bool False

notOp (Bool False) = return $ Bool True
notOp (_) = return $ Bool False

symbolToString (List [Atom "quote", x]) = return $ x
symbolToString val@(_) = return val
stringToSymbol val@(String _) = return $ List [Atom "quote", val]

makeString, stringLength, stringRef, substring, stringAppend :: [LispVal] -> ThrowsError LispVal
makeString [Number n] = return $ String $ replicate (fromIntegral n) ' '
makeString [Number n, Char x] = return $ String $ replicate (fromIntegral n) x
stringLength [String str] = return . Number .fromIntegral $ length str
stringRef [String str, Number n] = return . Char $ str !! (fromIntegral n)
substring [String str, Number n, Number m] = return . String $  take mi $ drop ni str
  where
    [mi, ni] = map fromIntegral [m-1,n]
stringAppend strList = String <$> foldr1 (++) <$> sequence (unpackStr <$> strList)
joinString str = String <$> sequence (unpackChar <$> str)

stringToList, listToString :: [LispVal] -> ThrowsError LispVal
stringToList [String str] = return . List $ Char <$> str
listToString [List listOfChars] = String <$> mapM unpackChar listOfChars

-- apply :: String -> [LispVal] -> ThrowsError LispVal
-- apply func args = maybe (throwError $ NotFunction "Unrecognized primitive function args" func) ($ args) $ lookup func primitives
apply :: LispVal -> [LispVal] -> IOThrowsError LispVal
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (IOFunc func) args = func args
apply (Func params varargs body closure) args =
  if num params /= num args && varargs == Nothing
     then throwError $ NumArgs (num params) args
          else (liftIO $ bindVars closure $ zip params args) >>= bindVarArgs varargs >>= evalBody
  where remainingArgs = drop (length params) args
        num = toInteger . length
        evalBody env = liftM last $ mapM (eval env) body
        bindVarArgs arg env =
          case arg of
            Just argName -> liftIO $ bindVars env [(argName, List $ remainingArgs)]
            Nothing -> return env

ioPrimitives :: [(String, [LispVal] -> IOThrowsError LispVal)]
ioPrimitives = [("apply", applyProc),
                ("open-input-file", makePort ReadMode),
                ("oppen-output-file", makePort WriteMode),
                ("close-input-port", closePort),
                ("close-output-port", closePort),
                ("read", readProc),
                ("write", writeProc),
                ("read-contents", readContents),
                ("read-all", readAll)]

primitives:: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
             ("-", numericBinop (-)),
             ("*", numericBinop (*)),
             ("/", numericBinop div),
             ("mod", numericBinop mod),
             ("quotient", numericBinop quot),
             ("remainder", numericBinop rem),
             ("=", numBoolBinop (==)),
             ("<", numBoolBinop (<)),
             (">", numBoolBinop (>)),
             (">=", numBoolBinop (>=)),
             ("<=", numBoolBinop (<=)),
             ("&&", boolBoolBinop (&&)),
             ("||", boolBoolBinop (||)),

             ("string=?", strBoolBinop(==)),
             ("string<?", strBoolBinop (<)),
             ("string>?", strBoolBinop (>)),
             ("string<=?", strBoolBinop (<=)),
             ("string>=?", strBoolBinop (>=)),
             ("make-string", makeString),
             ("string-length", stringLength),
             ("string-ref", stringRef),
             ("substring", substring),
             ("string-append", stringAppend),
             ("string", joinString),
             ("string->list", stringToList),
             ("list->string", listToString),


             ("number?", unaryOperator isNumber),
             ("list?", unaryOperator isList),
             ("symbol?", unaryOperator isSymbol),
             ("string?", unaryOperator isString),
             ("boolean?", unaryOperator isBoolean),

             ("not", unaryOperator notOp),
             ("symbol->string", unaryOperator symbolToString),
             ("string->symbol", unaryOperator stringToSymbol),
             ("assert", assert),
             ("eq?", eqv),
             ("eqv?", eqv),
             ("equal?", equal),
             ("cons", cons),
             ("car", car),
             ("cdr", cdr)]

unaryOperator :: (LispVal -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
unaryOperator f [v] = f v

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args  = if length args /= 2
                                then throwError $ NumArgs 2 args
                                else do left <- unpacker $ args !! 0
                                        right <- unpacker $ args !! 1
                                        return $ Bool $ left `op` right

numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> ThrowsError LispVal
numericBinop op [] = throwError $ NumArgs 2 []
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params = mapM unpackNum params >>= return . Number . foldl1 op

numBoolBinop = boolBinop unpackNum
strBoolBinop = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (List [n]) = unpackNum n
unpackNum notNum = throwError $ TypeMismatch "number" notNum

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return . show $ s
unpackStr (Bool s) = return . show $ s
unpackStr notStr = throwError $ TypeMismatch "string" notStr

unpackChar :: LispVal -> ThrowsError Char
unpackChar (Char c) = return c
unpackChar notChar = throwError $ TypeMismatch "char" notChar


unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool b) = return b
unpackBool notBool = throwError $ TypeMismatch "bool" notBool

-- Other functions
eqv :: [LispVal] -> ThrowsError LispVal
eqv [Bool arg1, Bool arg2] = return $ Bool (arg1 == arg2)
eqv [Number arg1, Number arg2] = return $ Bool (arg1 == arg2)
eqv [String arg1, String arg2] = return $ Bool (arg1 == arg2)
eqv [Atom arg1, Atom arg2] = return $ Bool (arg1 == arg2)
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [(List arg1), (List arg2)]             = return $ Bool $ (length arg1 == length arg2) &&
                                                             (all eqvPair $ zip arg1 arg2)
     where eqvPair (x1, x2) = case eqv [x1, x2] of
                                Left err -> False
                                Right (Bool val) -> val
{-eqv [List arg1, List arg2] = return $ Bool ((length arg1 == length arg2) && (and $ zipWith (==) arg1 arg2)) --different from Tang's-}
eqv [_, _] = return $ Bool False
eqv badArgsList = throwError $ NumArgs 2 badArgsList

assert :: [LispVal] -> ThrowsError LispVal
assert [arg1, arg2] =
    do
      result <- eqv [arg1, arg2]
      case result of
        Bool True -> return $ Bool True
        Bool False -> throwError $ Assert "false"

data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

unpackerEqual :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool
unpackerEqual arg1 arg2 (AnyUnpacker unpacker) =
  do
    unpacked1 <- unpacker arg1
    unpacked2 <- unpacker arg2
    return (unpacked1 == unpacked2)
    `catchError` (const (return $ False))

listEquals :: LispVal -> LispVal -> ThrowsError LispVal
listEquals (List list1) (List list2) =
  let
    Right boolList = zipWithM (\x y -> equal [x, y]) list1 list2
  in
   (Bool <$> (length list1 == length list2 &&) <$> (or <$> mapM unpackBool boolList))
    `catchError` (const $ return $ Bool False)

listEquals _ _ = return $ Bool False

equal :: [LispVal] -> ThrowsError LispVal
equal [arg1, arg2] =
  do
    primitiveEquals <- or <$> mapM (unpackerEqual arg1 arg2) [AnyUnpacker unpackNum,
                                                                  AnyUnpacker unpackStr,
                                                                  AnyUnpacker unpackBool]
    eqvEquals <- eqv [arg1, arg2]
    lstEquals <- listEquals arg1 arg2
    return $ Bool (primitiveEquals || let Bool x = eqvEquals in x || let Bool x = lstEquals in x)

equal badArgList = throwError $ NumArgs 2 badArgList

-- Implement basic Lisp handling
car :: [LispVal] -> ThrowsError LispVal
car [List (x:xs)] = return x
car [DottedList (x:xs) _] = return x
car [badArg] = throwError $ TypeMismatch "pair" badArg
car badArgList = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x:xs)] = return (List xs)
cdr [DottedList (x:[]) y ] = return (List [y])
cdr [DottedList (x:xs) y ] = return (DottedList xs y)
cdr [badArg] = throwError $ TypeMismatch "pair" badArg
cdr badArgList = throwError $ NumArgs 1 badArgList

cons :: [LispVal] -> ThrowsError LispVal
cons [x, List []] = return (List [x])
cons [x, List y] = return (List (x:y))
cons [x, DottedList ys y] = return (DottedList (x:ys) y)
cons [x, y] = return (DottedList [x] y)
cons [badArg] = throwError $ TypeMismatch "pair" badArg
cons badArgList = throwError $ NumArgs 1 badArgList

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

evalString :: Env -> String -> IO String
evalString env expr = runIOThrows $ liftM show $ (liftThrows $ readExpr expr) >>= eval env

evaluator :: String -> IO String
evaluator expr = nullEnv >>= flip evalString expr

evalAndPrint :: Env -> String -> IO ()
evalAndPrint env expr = evalString env expr >>= putStrLn

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ pred prompt action = do
  result <- prompt
  if pred result
    then return ()
    else action result >> until_ pred prompt action

runOne :: [String] -> IO ()
runOne args = do
    env <- primitiveBindings >>= flip bindVars [("args", List $ map String $ drop 1 args)]
    (runIOThrows $ liftM show $ eval env (List [Atom "load", String (args !! 0)]))
      >>= hPutStrLn stderr

runRepl :: IO ()
runRepl = primitiveBindings >>= until_ (== "quit") (readPrompt "Lisp>>> ") . evalAndPrint

type Env = IORef [(String, IORef LispVal)]
nullEnv :: IO Env
nullEnv = newIORef []
type IOThrowsError = ErrorT LispError IO
liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left err) = throwError err
liftThrows (Right val) = return val
runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = runErrorT (trapError action) >>= return . extractValue
isBound :: Env -> String -> IO Bool
isBound envRef var = readIORef envRef >>= return . maybe False (const True) . lookup var
getVar :: Env -> String -> IOThrowsError LispVal
getVar envRef var =
  do
    env <- liftIO $ readIORef envRef
    maybe (throwError $ UnboundVar "Getting an ubound variable" var) (liftIO . readIORef) (lookup var env)

setVar :: Env -> String -> LispVal -> IOThrowsError LispVal
setVar envRef var value =
  do
    env <- liftIO $ readIORef envRef
    maybe (throwError $ UnboundVar "Setting an unbound variable" var) (liftIO . (flip writeIORef value)) (lookup var env)
    return value

defineVar :: Env -> String -> LispVal -> IOThrowsError LispVal
defineVar envRef var value =
  do
    alreadyDefined <- liftIO $ isBound envRef var
    if alreadyDefined
       then setVar envRef var value >> return value
       else liftIO $ do
            valueRef <- newIORef value
            env <- readIORef envRef
            writeIORef envRef ((var, valueRef) : env)
            return value

bindVars :: Env -> [(String, LispVal)] -> IO Env
bindVars envRef bindings = readIORef envRef >>= extendEnv bindings >>= newIORef
  where
    extendEnv bindings env = liftM (++ env) (mapM addBinding bindings)
    addBinding (var, value) =
      do ref <- newIORef value
         return (var, ref)

applyProc :: [LispVal] -> IOThrowsError LispVal
applyProc [func, List args] = apply func args
applyProc (func : args) = apply func args

makePort :: IOMode -> [LispVal] -> IOThrowsError LispVal
makePort mode [String filename] = liftM Port $ liftIO $ openFile filename mode

closePort :: [LispVal] -> IOThrowsError LispVal
closePort [Port port] = liftIO $ hClose port >> (return $ Bool True)
closePort _ = return $ Bool False

readProc :: [LispVal] -> IOThrowsError LispVal
readProc [] = readProc [Port stdin]
readProc [Port port] = (liftIO $ hGetLine port) >>= liftThrows . readExpr

writeProc :: [LispVal] -> IOThrowsError LispVal
writeProc [obj] = writeProc [obj, Port stdout]
writeProc [obj, Port port] = liftIO $ hPrint port obj >> (return $ Bool True)

readContents :: [LispVal] -> IOThrowsError LispVal
readContents [String filename] = liftM String $ liftIO $ readFile filename

load :: String -> IOThrowsError [LispVal]
load filename = (liftIO $ readFile filename) >>= liftThrows . readExprList

readAll :: [LispVal] -> IOThrowsError LispVal
readAll [String filename] = liftM List $ load filename

primitiveBindings :: IO Env
primitiveBindings =
    nullEnv >>= (flip bindVars $ map (makeFunc IOFunc) ioPrimitives
              ++ map (makeFunc PrimitiveFunc) primitives)
  where makeFunc constructor (var, func) = (var, constructor func)

makeFunc varargs env params body = return $ Func (map showVal params) varargs body env
makeNormalFunc = makeFunc Nothing
makeVarArgs = makeFunc . Just . showVal

main :: IO ()
main =
  do
    args <- getArgs
    if null args then runRepl else runOne $ args
