module Parser (LispVal (..), readExpr) where

import System.Environment
import Data.Char
import Data.Ratio
import Data.Complex
import Data.Array
import Control.Monad
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
            deriving (Eq)

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
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (List contents) = "(" ++ unwordsList contents ++")"
showVal (DottedList head tail) = "(" ++ unwordsList head
                                     ++  "."
                                     ++ showVal tail
                                     ++ ")"

instance Show LispVal where
    show = showVal

unwordsList = unwords . map showVal
readExpr :: String -> LispVal
readExpr input = case parse (parseExpr) "lisp" input  of
                   Left err -> String ("No match: " ++ (show err))
                   Right val -> val

parser rule text = parse rule "(source)" text

main :: IO()
main = do args <- getArgs
          putStrLn . show . readExpr $ args !! 0

-------------------------------------------------------------------------------

spaces :: Parser ()
spaces = skipMany1 space

symbol :: Parser Char
symbol = oneOf "!$%&|*+-/:<=?>@i^_~#"

escapeChars = do
    char '\\'
    x <- oneOf ['"', '\\', 'n', 'r', 't']
    return $ (case x of
             '\\' -> '\\'
             '"' -> '"'
             'n'-> '\n'
             'r'-> '\r'
             't'-> '\t')

parseString :: Parser LispVal
parseString = do
            char '"'
            x <- many (escapeChars <|> noneOf "\"")
            char '"'
            return (String x)

parseAtom :: Parser LispVal
parseAtom = do first <- letter <|> symbol
               rest <- many (letter <|> digit <|> symbol)
               let atom = [first] ++ rest
               return $ case atom of
                    "#t" -> Bool True
                    "#f" -> Bool False
                    otherwise -> Atom atom

parseNumber :: Parser LispVal
parseNumber = (liftM (Number . read) $ many1 digit ) <|> try parseHex <|> parseOct

parseHex :: Parser LispVal
parseHex = string "#x">> many (oneOf "0123456789abcdefABCDEF") >>= (\x -> return . Number . fst . head . readHex $ x)

parseOct :: Parser LispVal
parseOct = string "#o" >> many (oneOf "01234567") >>= (\x -> return . Number . fst . head . readOct $ x)

parseDec :: Parser LispVal
parseDec = string "#d" >> many (oneOf "0123456789.") >>= (\x -> return . Float . rf $ x)
  where
    rf = read :: String -> Double

parseComplex :: Parser LispVal
parseComplex =  do
    x <- many $ oneOf "0123456789."
    oneOf "+-"
    y <- many $ oneOf "0123456789."
    char 'i'
    return . Complex $ (read x :: Float) :+ (read y :: Float)

parseRational :: Parser LispVal
parseRational = do
    x <- many digit
    char '/'
    y <- many digit
    return . Rational $ (read x :: Integer) % (read y :: Integer)

parseChar :: Parser LispVal
parseChar = do
    string "#\\"
    x <- many1 letter
    return . Char $ case (map toLower x) of
            "newline" -> '\n'
            "space" -> ' '
            " " -> ' '
            [x] -> x

parseList :: Parser LispVal
parseList = liftM List $ sepBy parseExpr spaces

parseDottedList :: Parser LispVal
parseDottedList = do
    head <- endBy parseExpr spaces
    tail <- char '.' >> spaces >> parseExpr
    return $ DottedList head tail

parseQuoted :: Parser LispVal
parseQuoted = do
    char '\''
    x <- parseExpr
    return $ List [Atom "quote", x]

parseQuasiQuote :: Parser LispVal
parseQuasiQuote = do
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
parseVector = do
  string "#("
  elems <- sepBy parseExpr spaces
  char ')'
  return . Vector $ listArray (0, (length elems) - 1 ) elems