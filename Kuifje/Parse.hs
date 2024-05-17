{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs, StandaloneDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}

module Kuifje.Parse where

import Debug.Trace

import Control.Monad
import Data.Char (generalCategory, GeneralCategory(..))
import Data.Functor.Identity
import Data.Ratio
import Data.Set (Set)
import qualified Data.Set as Set
import System.IO
import Text.ParserCombinators.Parsec
import Text.Parsec.Char
import Text.Parsec (ParsecT)
import Text.ParserCombinators.Parsec.Expr
import Text.ParserCombinators.Parsec.Language
import qualified Text.Parsec.Indent as Indent
import qualified Text.Parsec as ParsecCl
import qualified Text.Parsec.Indent.Explicit as Explicit
import qualified Text.Parsec.Indent.Internal as Internal
import qualified Text.ParserCombinators.Parsec.Token as Token

import Kuifje.Syntax

--
-- Parsec Language Setup
--

languageDef =
   emptyDef { Token.commentStart    = "/*"
            , Token.commentEnd      = "*/"
            , Token.commentLine     = "//"
            , Token.identStart      = letter
            , Token.identLetter     = alphaNum
            , Token.reservedNames   = [ "if"
                                      , "then"
                                      , "else"
                                      , "fi"
                                      , "while"
                                      , "do"
                                      , "od"
                                      , "set"
                                      , "skip"
                                      , "true"
                                      , "false"
                                      , "~"
                                      , "&&"
                                      , "||"
                                      , "hid"
                                      , "vis"
                                      , "print"
                                      , "leak"
                                      , "observe"
                                      , "uniform"
                                      , "geometric"
                                      , "|"
                                      , "function"
                                      , "return"
                                      , "csv"
                                      , "for"
                                      ]
            , Token.reservedOpNames = ["+"
                                      , "-"
                                      , "^"
                                      , "*"
                                      , "/"
                                      , "div"
                                      , "<"
                                      , ">"
                                      , "~"
                                      , ":="
                                      , "<="
                                      , ">="
                                      , "=="
                                      , "!="
                                      , "&&"
                                      , "||"
                                      , "%"
                                      , "@"
                                      , "::"
                                      , "strIsSub"
                                      , "isSub"
                                      , "powerSet"
                                      , "in"
                                      , "nin"
                                      , "filterSet"
                                      ]
            }

lexer = Token.makeTokenParser languageDef

-- identifier    = Token.identifier    lexer -- parses an identifier
variable = Token.identifier lexer <?> "variable" -- parses a variable
fnname = Token.identifier lexer <?> "function name" -- parses a function name

reserved      = Token.reserved      lexer -- parses a reserved name
reservedOp    = Token.reservedOp    lexer -- parses an operator
parens        = Token.parens        lexer -- parses surrounding parenthesis:
brackets      = Token.brackets      lexer -- exterior choice
angles        = Token.angles        lexer -- interior choice
braces        = Token.braces        lexer 
semi          = Token.semi          lexer -- parses a semicolon
whiteSpace    = Token.whiteSpace    lexer -- parses whitespace
natural       = Token.natural       lexer
integer       = Token.integer       lexer
symbol        = Token.symbol        lexer
stringLiteral = Token.stringLiteral lexer

--
-- Generic
--

s << t = do { x <- s;  t; return x }

stringSymbol :: Parser String
stringSymbol = 
  do reserved "\""
     text <- many1 digit
     reserved "\""
     return text

decimalRat :: Parser Rational
decimalRat = 
  do ns <- many1 digit
     ms <- try (char '.' >> many digit) <|> return [] 
     let pow10 = toInteger $ length ms
     let (Right n) = parse natural "" (ns ++ ms)
     return (n % (10 ^ pow10))

kChoice :: (a -> a -> Expr -> a) -> Parser (a -> a -> a)
kChoice c =
      do symbol "["
         expr <- expression
         symbol "]"
         return $ \x y -> c x y expr  

--
-- Statements
--

-- | End of Line
eol :: Parser ()
eol = void endOfLine <|> eof

collapsedSeq :: [Stmt] -> Stmt
collapsedSeq cs = case cs of
                     [] -> Skip     -- the empty program is skip
                     [s] -> s       -- a single statement is just itself
                     ps -> Seq ps   -- multiple statements are sequenced

sOperators =
   [[Infix (kChoice Echoice) AssocLeft]]

-- | Parse a statement.
statement :: Parser Stmt
statement = buildExpressionParser sOperators sTerm << whiteSpace <?> "statement"

sTerm :: Parser Stmt
sTerm = (    (try plusplusStmt  <?> "sTerm:plusplus")
--         <|> (braces codeBlock  <?> "sTerm:braces")  -- doesn't really work well with indent-sensitivity
         <|> (try lesslessStmt  <?> "sTerm:lessless")
         <|> (try samplingStmt  <?> "sTerm:sampling")
         <|> (try supportStmt   <?> "sTerm:support")
         <|> (try readStmt      <?> "sTerm:read")
         <|> (try listCallStmt  <?> "sTerm:listCall")
         <|> (funcStmt          <?> "sTerm:func")
         <|> (returnStmt        <?> "sTerm:return")
         <|> (ifStmt            <?> "sTerm:if")
         <|> (whileStmt         <?> "sTerm:while")
         <|> (forStmt           <?> "sTerm:for")
         <|> (skipStmt          <?> "sTerm:skip")
         <|> (vidStmt           <?> "sTerm:vid")
         <|> (leakStmt          <?> "sTerm:leak")
         <|> (assignStmt        <?> "sTerm:assign"))

elseStmt :: Parser (Expr,Stmt)
elseStmt = 
   do ref <- indentationBlock
      reserved "else"
      reservedOp ":"
      body <- codeBlock ref
      -- For else statements, the condition should be always true
      input <- getInput
--      error ("Input is:\n" ++ (show input))
      return $ ((RBinary Eq (RationalConst (1 % 1)) (RationalConst (1 % 1))) , body)

ifCondStmt :: Parser (Expr,Stmt)
ifCondStmt =
   do lookAhead (reserved "if") -- fail early
      ref <- indentationBlock
      reserved "if"
      cond <- expression
      reservedOp ":"
      body <- codeBlock ref
      input <- getInput
      return $ (cond, body)

elifCondStmt :: Parser (Expr,Stmt)
elifCondStmt =
   do ref <- indentationBlock
      reserved "elif"
      cond <- expression
      reservedOp ":"
      body <- codeBlock ref
      input <- getInput
      return $ (cond, body)
      
checkIndent :: Expr -> Internal.Indentation -> Internal.Indentation -> Bool
checkIndent expr ref pos = 
   if expr == (RBinary Ne (RationalConst (1 % 1)) (RationalConst (1 % 1)))
      then False
      else (isInBlock ref pos) 

-- | Parses a block of lines at the same indentation level starting at the
-- current position
getIfBlock :: Bool -> Internal.Indentation -> Parser Stmt
getIfBlock False _ = return $ Skip
getIfBlock True ref = do
      pos <- indentation
      (cond, stmt) <- option ((RBinary Ne (RationalConst (1 % 1)) (RationalConst (1 % 1))),Skip) (elifCondStmt <|> elseStmt)
      newPos <- indentation
      if (isSameCol pos newPos)
         then return stmt
         else 
           do elseBlock <- (getIfBlock (not (isSameCol pos newPos)) ref)
              return (If cond stmt elseBlock)

ifStmt :: Parser Stmt
ifStmt =
   do ref <- indentation
      (cond, stmt) <- ifCondStmt
      pos <- indentation
      elseBlock <- (getIfBlock (isInBlock ref pos) ref)
      input <- getInput
      setInput (";" ++ input)
      return $ (If cond stmt elseBlock)

-- | Obtain the current indentation, to be used as a reference later.
indentation :: Monad m => ParsecT s u m Internal.Indentation
indentation = do
    pos <- getPosition
    return $! Internal.Indentation {Internal.iLine = sourceLine pos, Internal.iColumn = sourceColumn pos}

-- | Obtain the current indentation, to be used as a reference later.
indentationBlock :: Monad m => ParsecT s u m Internal.Indentation
indentationBlock = do
    pos <- getPosition
    return $! Internal.Indentation {Internal.iLine = sourceLine pos, Internal.iColumn = ((sourceColumn pos) + 2)}

-- | Verifies if the position is in the same position
--   N.B. requires both the same column, and the same *line*
isSamePosition :: Internal.Indentation -> Internal.Indentation -> Bool
isSamePosition ref pos = ((Internal.iColumn pos == Internal.iColumn ref) && (Internal.iLine pos == Internal.iLine ref))

-- | Verifies if the position is in the same column.
isSameCol :: Internal.Indentation -> Internal.Indentation -> Bool
isSameCol ref pos = (Internal.iColumn pos == Internal.iColumn ref)

-- | Verifies if the position is on the same line.
isSameLine :: Internal.Indentation -> Internal.Indentation -> Bool
isSameLine ref pos = (Internal.iLine pos == Internal.iLine ref)

-- | Verifies if the position is in the same block as the reference position
isInBlock :: Internal.Indentation -> Internal.Indentation -> Bool
isInBlock ref pos = (Internal.iColumn pos >= Internal.iColumn ref)

-- | Collect a block of statements at the same indentation level.
stmtBlock :: Internal.Indentation -> Parser [Stmt]
stmtBlock ref =
  (do
    whiteSpace -- clear whitespace before the first statement
    curr <- indentation
    guard (isSameCol ref curr || isSameLine ref curr) -- when not the same, early exit
   --  input <- take 10 <$> getInput
   --  !c <- traceShow input . traceShowId <$> statement
    c <- statement
    -- statement eats its trailing whitespace
    try (semi << whiteSpace) -- remove semicolon if there is one
    cs2 <- (eof >> return []) <|> stmtBlock ref
    return (c : cs2)) <?> "statement block"

-- | Collect a block of statements at the same indentation level, as a statement.
codeBlock :: Internal.Indentation -> Parser Stmt
codeBlock ref = collapsedSeq <$> stmtBlock ref <?> "code block"

funcStmt :: Parser Stmt
funcStmt = 
  do lookAhead (reserved "def") -- fail early
     ref <- indentationBlock
     reserved "def"
     name <- fnname
     inputs <- parens (sepBy variable (symbol ","))
     reservedOp ":"
     body <- codeBlock ref
     -- Output Parameters - Only in the end of the function:
     input <- getInput
     setInput (";" ++ input)
     return $ FuncStmt name body inputs

returnStmt :: Parser Stmt
returnStmt = reserved "return" >> ReturnStmt <$> expression

whileStmt :: Parser Stmt
whileStmt =
  do lookAhead (reserved "while") -- fail early
     ref <- indentationBlock -- expected indentation in the following block
     reserved "while"
     cond <- expression
     reservedOp ":"
     endOfLine
     curr <- indentation -- actual indentation at the start of the block
     unless (isSameCol ref curr) (fail "incorrect indentation in while")
     stmt <- statement -- we expect at least one statement in the body
     stmts <- stmtBlock ref
     return $ While cond (collapsedSeq (stmt : stmts))

forStmt :: Parser Stmt
forStmt =
  do ref <- indentationBlock
     reserved "for"
     var <- variable
     reservedOp "in"
     list <- expression
     reservedOp ":"
     stmt <- codeBlock ref
     input <- getInput
     setInput (";" ++ input)
     return $ For var list stmt

assignStmt :: Parser Stmt
assignStmt =
  do var <- variable
     reservedOp "="
     expr <- expression
     return $ Assign var expr

plusplusStmt :: Parser Stmt
plusplusStmt =
  do var <- variable
     reservedOp "++"
     return $ Plusplus var

lesslessStmt :: Parser Stmt
lesslessStmt =
  do var <- variable
     reservedOp "--"
     return $ Lessless var

samplingStmt :: Parser Stmt
samplingStmt =
  do var <- variable
     reservedOp "<-"
     expr <- expression
     return $ Sampling var expr

supportStmt :: Parser Stmt
supportStmt =
  do var <- variable
     reservedOp "="
     reserved "set"
     expr <- expression
     return $ Support var expr

skipStmt :: Parser Stmt
skipStmt = reserved "skip" >> return Skip

vidStmt :: Parser Stmt
vidStmt = 
  do reserved "vis" 
     var <- variable
     return $ Vis var

leakStmt :: Parser Stmt
leakStmt = 
  do reserved "leak" <|> reserved "observe" -- <|> reserved "print"
     reservedOp "("
     expr <- expression
     reservedOp ")"
     return $ Leak expr

readStmt :: Parser Stmt
readStmt =
  do var <- variable
     reservedOp "="
     reserved "csv"
     reservedOp "("
     file <- expression
     reservedOp ","
     columns <- expression
     reservedOp ","
     limit <- expression
     reservedOp ","
     tVal <- expression
     reservedOp ")"
     return $ Csv var file columns limit tVal

listCallStmt :: Parser Stmt
listCallStmt =
  do var <- variable
     char '.'
     input <- getInput
     setInput (var ++ " ls_" ++ input)
     expr <- expression
     --error ("Input is " ++ input)
     return $ Assign var expr

--
-- Expressions
--

expression :: Parser Expr
expression =
   buildExpressionParser eOperators eTerm << whiteSpace
      <?> "expression"

eOperators =
        [ [Prefix (reservedOp "-"   >> return Neg               )          ]
        , [Prefix (reservedOp "~"   >> return Not               )          ]
        , [Prefix (reservedOp "powerSet"   >> return PowerSet   )          ]
        , [Infix  (reservedOp "*"   >> return (ABinary Multiply)) AssocLeft,
           Infix  (reservedOp "/"   >> return (ABinary Divide  )) AssocLeft,
           Infix  (reservedOp "div" >> return (ABinary IDivide )) AssocLeft,
           Infix  (reservedOp "+"   >> return (ABinary Add     )) AssocLeft,
           Infix  (reservedOp "%"   >> return (ABinary Rem     )) AssocLeft,
           Infix  (reservedOp "^"   >> return (ABinary Pow     )) AssocLeft,
           Infix  (reservedOp "&"   >> return (ABinary Intersection)) AssocLeft,
           Infix  (reservedOp "filterSet"   >> return (ABinary Filter)) AssocLeft,
           Infix  (reservedOp "-"   >> return (ABinary Subtract)) AssocLeft]
        , [Infix  (reservedOp "in"  >> return (SBinary In        )) AssocLeft,
           Infix  (reservedOp "nin"  >> return (SBinary NIn      )) AssocLeft,
           Infix  (reservedOp "isSub"  >> return (SBinary IsSubOf)) AssocLeft]
        , [Infix  (reservedOp "&&"  >> return (BBinary And     )) AssocLeft,
           Infix  (reservedOp "||"  >> return (BBinary Or      )) AssocLeft]
        , [Infix  (kChoice IchoiceDist)                               AssocLeft]
        , [Infix  (reservedOp ">"   >> return (RBinary Gt)      ) AssocLeft] 
        , [Infix  (reservedOp "<"   >> return (RBinary Lt)      ) AssocLeft] 
        , [Infix  (reservedOp ">="  >> return (RBinary Ge)      ) AssocLeft] 
        , [Infix  (reservedOp "<="  >> return (RBinary Le)      ) AssocLeft] 
        , [Infix  (reservedOp "=="  >> return (RBinary Eq)      ) AssocLeft] 
        , [Infix  (reservedOp "!="  >> return (RBinary Ne)      ) AssocLeft]
        , [Infix  (reservedOp "strIsSub"  >> return (RBinary IsSubstrOf) ) AssocLeft]
        , [Infix  (reservedOp "@"   >> return Tuple             ) AssocLeft]
        ]

eTermR :: Parser Expr
eTermR = (parens expression
        <|> ((reserved "true" <|> reserved "True")    >> return (BoolConst True)  <?> "eTerm:true")
        <|> ((reserved "false" <|> reserved "False")  >> return (BoolConst False) <?> "eTerm:false")
        <|> (setExpr                              <?> "eTerm:setExpr")
        <|> (listExpr                             <?> "eTerm:listExpr")
        <|> (try listElExpr                       <?> "eTerm:listElExpr")
        <|> (try listAppend                       <?> "eTerm:listAppend")
        <|> (try listInsert                       <?> "eTerm:listInsert")
        <|> (try listExtend                       <?> "eTerm:listExtend")
        <|> (try listRemove                       <?> "eTerm:listRemove")
        <|> (try listLength                       <?> "eTerm:listLength")
        <|> (try listRange                        <?> "eTerm:listRange")
        <|> (try callExpr                         <?> "eTerm:callExpr")
        <|> (try uniformFromSet                   <?> "eTerm:uniformFromSet")
        <|> (try uniformIchoices                  <?> "eTerm:uniformIchoices")
        <|> (try uniformSetVar                    <?> "eTerm:uniformSetVar")
        <|> (try uniformIchoicesListComp          <?> "eTerm:uniformIchoicesListComp")
        <|> (try notUniformIchoices               <?> "eTerm:notUniformIchoices")
        <|> (geometricIchoices                    <?> "eTerm:geometricIchoices")
        <|> (liftM RationalConst (try decimalRat) <?> "eTerm:rat")
        <|> (liftM Var variable                   <?> "eTerm:var")
        <|> (liftM Text stringLiteral             <?> "eTerm:text")
        <?> "eTerm") << whiteSpace

eTermL :: Parser Expr
eTermL = ifExpr

eTerm :: Parser Expr
eTerm = (try eTermL) <|> ((try tupleExpr) <|> eTermR)

ifExpr =
  do exprIf <- eTermR
     reserved "if"
     cond <- expression
     reserved "else"
     exprElse <- expression
     return $ ExprIf cond exprIf exprElse

uniformIchoices = 
        do reserved "uniform"
           reservedOp "["
           list <- sepBy expression (symbol ",")
           reservedOp "]"
           return $ IchoicesDist list
           -- return $ Ichoices list

notUniformIchoices = 
        do reservedOp "["
           list <- sepBy expression (symbol ",")
           reservedOp "]"
           return $ INUchoicesDist list

uniformIchoicesListComp = 
        do reserved "uniform"
           reservedOp "["
           l <- integer
           symbol ".."
           r <- integer
           reservedOp "]"
           return $ IchoicesDist [(RationalConst (x % 1)) | x <- [l..r]]
           -- return $ Ichoices [(RationalConst (x % 1)) | x <- [l..r]]

uniformFromSet = 
        do reserved "uniform"
           reservedOp "{"
           list <- sepBy expression (symbol ",")
           reservedOp "}"
           let values = Set.fromList list
           return $ SetIchoiceDist (Eset values)

uniformSetVar = 
        do reserved "uniform"
           expr <- liftM Var variable
           return $ SetIchoiceDist expr

getParam :: Integer -> [Expr] -> Expr
getParam 0 ls = (head ls)
getParam n ls = getParam (n-1) (tail ls)

geometricIchoices =
        do reserved "geometric"
           reservedOp "("
           params <- sepBy expression (symbol ",")
           reservedOp ")"
           return $ Geometric (getParam 0 params) (getParam 1 params) (getParam 2 params) (getParam 3 params)

setExpr = 
        do reservedOp "{"
           list <- sepBy expression (symbol ",")
           reservedOp "}"
           let values = Set.fromList list
           return $ Eset values

tupleExpr =
        do reservedOp "("
           exp <- expression
           reserved ","
           list <- sepBy expression (symbol ",")
           reservedOp ")"
           return $ TupleExpr ([exp] ++ list)

listExpr = 
        do reservedOp "["
           elements <- sepBy expression (symbol ",")
           reservedOp "]"
           return $ ListExpr elements

listElExpr =
        do varID <- variable
           reservedOp "["
           varIndex <- expression
           reservedOp "]"
           return $ ListElem varID varIndex

listAppend =
        do var <- variable
           reserved "ls_append"
           reservedOp "("
           elem <- expression
           reservedOp ")"
           return $ ListAppend var elem

listInsert =
        do var <- variable
           reserved "ls_insert"
           reservedOp "("
           index <- expression
           reservedOp ","
           elem <- expression
           reservedOp ")"
           return $ ListInsert var index elem

listRemove =
        do var <- variable
           reserved "ls_remove"
           reservedOp "("
           elem <- expression
           reservedOp ")"
           return $ ListRemove var elem

listLength =
        do reserved "len"
           reservedOp "("
           list <- expression
           reservedOp ")"
           return $ ListLength list

listExtend =
        do l1 <- variable
           reserved "ls_extend"
           reservedOp "("
           l2 <- variable
           reservedOp ")"
           return $ ListExtend l1 l2

listRange =
        do reserved "range"
           symbol "("
           l <- integer
           symbol ","
           r <- integer
           symbol ")"
           return $ ListExpr [(RationalConst (x % 1)) | x <- [l..r]]

callExpr =
        do name <- fnname
           reservedOp "("
           parameters <- sepBy expression (symbol ",")
           reservedOp ")" 
           return $ CallExpr name parameters

-- Output only
parseString :: String -> Stmt
parseString str =
        case parse (indentation >>= codeBlock) "" str of
          Left e  -> error $ show e
          Right r -> r

parseFile :: String -> IO Stmt
parseFile file =
        do program  <- readFile file
           case parse (indentation >>= codeBlock) "" program of
                Left e  -> print e >> fail "parse error"
                Right r -> return r
