{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Lookahead.Main
  ( Range (..)
  , range
  , Reason (..)
  , ErrF (..)
  , Err (..)
  , errRange
  , errReason
  , Side (..)
  , ParserT
  , Parser
  , parseT
  , parse
  , parseI
  , throwP
  , mapErrorP
  , endP
  , optP
  , altP
  , greedyP
  , greedy1P
  , lookP
  , expectP
  -- , breakOnP
  , infixP
  , takeP
  , dropP
  , takeWhileP
  , dropWhileP
  , betweenP
  , sepByP
  , spaceP
  , HasErrMessage (..)
  , errataE
  , renderE
  , printE
  , Value (..)
  , jsonParser
  , Arith (..)
  , arithParser
  )
where

import Control.Applicative (liftA2)
import Control.Exception (Exception)
import Control.Monad (void)
import Control.Monad.Except (ExceptT (..), MonadError (..), runExceptT)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Identity (Identity (..))
import Control.Monad.Reader (MonadReader)
import Control.Monad.State.Strict (MonadState (..), StateT (..), gets)
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.Writer.Strict (MonadWriter)
import Data.Bifoldable (Bifoldable (..))
import Data.Bifunctor (Bifunctor (..))
import Data.Bifunctor.TH (deriveBifoldable, deriveBifunctor, deriveBitraversable)
import Data.Bitraversable (Bitraversable (..))
import Data.Char (isAlpha, isSpace)
import Data.Foldable (foldl', toList)
import Data.Functor.Foldable (Base, Corecursive (..), Recursive (..))
import Data.Sequence (Seq (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Typeable (Typeable)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Void (Void, absurd)
import Errata qualified as E
import Errata.Styles qualified as E
import Errata.Types qualified as E
import System.IO (stderr)

modifyError :: Monad m => (e -> x) -> ExceptT e m a -> ExceptT x m a
modifyError f m = lift (runExceptT m) >>= either (throwError . f) pure

type OffsetVec = Vector (Int, Int)

mkOffsetVec :: Text -> OffsetVec
mkOffsetVec t = V.unfoldrN (T.length t) go ((0, 0), T.unpack t)
 where
  go (p@(!line, !col), xs) =
    case xs of
      [] -> Nothing
      x : xs' -> Just (p, if x == '\n' then ((line + 1, 0), xs') else ((line, col + 1), xs'))

data Range = Range {rangeStart :: !Int, rangeEnd :: !Int}
  deriving stock (Eq, Ord, Show)

range :: Text -> Range
range t = Range 0 (T.length t)

data St = St
  { stHay :: !Text
  , stRange :: !Range
  , stLabels :: !(Seq Text)
  }
  deriving stock (Eq, Ord, Show)

data Side = SideLeft | SideRight
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Reason e r
  = ReasonCustom !e
  | ReasonExpect !Text !Text
  | ReasonDemand !Int !Int
  | ReasonLeftover !Int
  | ReasonAlt !Text !(Seq (Text, r))
  | ReasonInfix !Text !(Seq (Int, Side, r))
  | ReasonEmptySearch
  | ReasonFail !Text
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

deriveBifunctor ''Reason
deriveBifoldable ''Reason
deriveBitraversable ''Reason

data ErrF e r = ErrF {efRange :: !Range, efReason :: !(Reason e r)}
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

deriveBifunctor ''ErrF
deriveBifoldable ''ErrF
deriveBitraversable ''ErrF

newtype Err e = Err {unErr :: ErrF e (Err e)}
  deriving stock (Eq, Ord, Show)

instance Functor Err where
  fmap f = go
   where
    go (Err (ErrF ra re)) = Err (ErrF ra (bimap f go re))

instance Foldable Err where
  foldr f = flip go
   where
    go (Err (ErrF _ re)) z = bifoldr f go z re

instance Traversable Err where
  traverse f = go
   where
    go (Err (ErrF ra re)) = fmap (Err . ErrF ra) (bitraverse f go re)

instance (Typeable e, Show e) => Exception (Err e)

type instance Base (Err e) = ErrF e

instance Recursive (Err e) where
  project = unErr

instance Corecursive (Err e) where
  embed = Err

errRange :: Err e -> Range
errRange = efRange . unErr

errReason :: Err e -> Reason e (Err e)
errReason = efReason . unErr

newtype ParserT e m a = ParserT {unP :: ExceptT (Err e) (StateT St m) a}
  deriving newtype (Functor, Applicative, Monad)

type Parser e = ParserT e Identity

instance Monad m => MonadFail (ParserT e m) where
  fail = errP . ReasonFail . T.pack

instance MonadTrans (ParserT e) where
  lift = ParserT . lift . lift

deriving instance MonadReader r m => MonadReader r (ParserT e m)

deriving instance MonadWriter w m => MonadWriter w (ParserT e m)

deriving instance MonadIO m => MonadIO (ParserT e m)

instance MonadState s m => MonadState s (ParserT e m) where
  get = lift get
  put = lift . put
  state = lift . state

-- private

runParserT :: ParserT e m a -> St -> m (Either (Err e) a, St)
runParserT p = runStateT (runExceptT (unP p))

errP :: Monad m => Reason e (Err e) -> ParserT e m a
errP re = do
  ra <- ParserT (gets stRange)
  ParserT (throwError (Err (ErrF ra re)))

leftoverP :: Monad m => ParserT e m Int
leftoverP = do
  Range s e <- ParserT (gets stRange)
  return (e - s)

-- public

parseT :: Monad m => ParserT e m a -> Text -> m (Either (Err e) a)
parseT p h = fmap fst (runParserT (p <* endP) (St h (range h) Empty))

parse :: Parser e a -> Text -> Either (Err e) a
parse p h = runIdentity (parseT p h)

parseI :: HasErrMessage e => Parser e a -> Text -> IO (Maybe a)
parseI p h =
  case parse p h of
    Left e -> Nothing <$ printE "<interactive>" h e
    Right a -> pure (Just a)

throwP :: Monad m => e -> ParserT e m a
throwP = errP . ReasonCustom

mapErrorP :: Monad m => (e -> x) -> ParserT e m a -> ParserT x m a
mapErrorP f p = ParserT (modifyError (fmap f) (unP p))

endP :: Monad m => ParserT e m ()
endP = do
  l <- leftoverP
  if l == 0
    then pure ()
    else errP (ReasonLeftover l)

optP :: Monad m => ParserT e m a -> ParserT e m (Maybe a)
optP p = do
  st0 <- ParserT get
  (ea, st1) <- lift (runParserT p st0)
  case ea of
    Left _ -> pure Nothing
    Right a -> Just a <$ ParserT (put st1)

altP :: Monad m => Foldable f => Text -> f (Text, ParserT e m a) -> ParserT e m a
altP lab = go . toList
 where
  go xps = do
    st0 <- ParserT get
    goNext st0 Empty xps
  goNext st0 !errs = \case
    [] -> errP (ReasonAlt lab errs)
    (x, p) : xps' -> do
      (ea, st1) <- lift (runParserT p st0)
      case ea of
        Left err -> goNext st0 (errs :|> (x, err)) xps'
        Right a -> a <$ ParserT (put st1)

greedyP :: Monad m => ParserT e m a -> ParserT e m (Seq a)
greedyP p = go Empty
 where
  go !acc = do
    ma <- optP p
    case ma of
      Nothing -> pure acc
      Just a -> go (acc :|> a)

greedy1P :: Monad m => ParserT e m a -> ParserT e m (Seq a)
greedy1P p = liftA2 (:<|) p (greedyP p)

lookP :: Monad m => ParserT e m a -> ParserT e m a
lookP p = do
  st0 <- ParserT get
  (ea, _) <- lift (runParserT p st0)
  case ea of
    Left err -> ParserT (throwError err)
    Right a -> pure a

expectP :: Monad m => Text -> ParserT e m ()
expectP n = do
  o <- takeP (T.length n)
  if n == o
    then pure ()
    else errP (ReasonExpect n o)

-- breakOnP :: Monad m => Text -> ParserT e m a -> ParserT e m a
-- breakOnP n p = go where
--   go =
--     if T.null n
--       then errP ReasonEmptySearch
--       else do
--         undefined

infixP :: Monad m => Text -> ParserT e m a -> ParserT e m b -> ParserT e m (a, b)
infixP n pa pb = go
 where
  go =
    if T.null n
      then errP ReasonEmptySearch
      else do
        st0 <- ParserT get
        goNext st0 Empty (T.breakOnAll n (stHay st0))
  goNext st0 !eacc = \case
    [] -> errP (ReasonInfix n eacc)
    (h1, h2) : rest -> do
      let r = stRange st0
          e1 = rangeStart r + T.length h1
          st1 = st0 {stHay = h1, stRange = r {rangeEnd = e1}}
          l = T.length n
          st2 = st0 {stHay = T.drop l h2, stRange = r {rangeStart = e1 + l}}
      (ea1, _) <- lift (runParserT (pa <* endP) st1)
      case ea1 of
        Left err1 -> goNext st0 (eacc :|> (e1, SideLeft, err1)) rest
        Right a -> do
          (ea2, st3) <- lift (runParserT pb st2)
          case ea2 of
            Left err2 -> goNext st0 (eacc :|> (e1, SideRight, err2)) rest
            Right b -> (a, b) <$ ParserT (put st3)

takeP :: Monad m => Int -> ParserT e m Text
takeP i = ParserT $ state $ \st ->
  let h = stHay st
      (o, h') = T.splitAt i h
      l = T.length o
      r = stRange st
      r' = r {rangeStart = rangeStart r + l}
      st' = st {stHay = h', stRange = r'}
  in  (o, st')

takeExactP :: Monad m => Int -> ParserT e m Text
takeExactP i = do
  et <- ParserT $ state $ \st ->
    let h = stHay st
        (o, h') = T.splitAt i h
        l = T.length o
        r = stRange st
        r' = r {rangeStart = rangeStart r + T.length o}
        st' = st {stHay = h', stRange = r'}
    in  if l == i then (Right o, st') else (Left l, st)
  case et of
    Left l -> errP (ReasonDemand i l)
    Right a -> pure a

dropP :: Monad m => Int -> ParserT e m Int
dropP = fmap T.length . takeP

dropExactP :: Monad m => Int -> ParserT e m ()
dropExactP = void . takeExactP

takeWhileP :: Monad m => (Char -> Bool) -> ParserT e m Text
takeWhileP f = ParserT $ state $ \st ->
  let h = stHay st
      o = T.takeWhile f h
      l = T.length o
      h' = T.drop l h
      r = stRange st
      r' = r {rangeStart = rangeStart r + l}
  in  (o, st {stHay = h', stRange = r'})

takeWhile1P :: Monad m => (Char -> Bool) -> ParserT e m Text
takeWhile1P f = do
  mt <- ParserT $ state $ \st ->
    let h = stHay st
        o = T.takeWhile f h
        l = T.length o
        h' = T.drop l h
        r = stRange st
        r' = r {rangeStart = rangeStart r + l}
        st' = st {stHay = h', stRange = r'}
    in  if l > 0 then (Just o, st') else (Nothing, st)
  case mt of
    Nothing -> errP (ReasonDemand 1 0)
    Just a -> pure a

dropWhileP :: Monad m => (Char -> Bool) -> ParserT e m Int
dropWhileP = fmap T.length . takeWhileP

dropWhile1P :: Monad m => (Char -> Bool) -> ParserT e m Int
dropWhile1P = fmap T.length . takeWhile1P

betweenP :: Monad m => ParserT e m x -> ParserT e m y -> ParserT e m a -> ParserT e m a
betweenP px py pa = px *> pa <* py

sepByP :: Monad m => ParserT e m x -> ParserT e m a -> ParserT e m (Seq a)
sepByP c p = go
 where
  go = do
    ma <- optP p
    case ma of
      Nothing -> pure Empty
      Just a -> goNext (Empty :|> a)
  goNext !acc = do
    mc <- optP c
    case mc of
      Nothing -> pure acc
      Just _ -> do
        a <- p
        goNext (acc :|> a)

spaceP :: Monad m => ParserT e m ()
spaceP = void (dropWhileP isSpace)

class HasErrMessage e where
  getErrMessage :: e -> [Text]

instance HasErrMessage Void where
  getErrMessage = absurd

indent :: Int -> [Text] -> [Text]
indent i = let s = T.replicate (2 * i) " " in fmap (s <>)

instance HasErrMessage e => HasErrMessage (Err e) where
  getErrMessage (Err (ErrF _ re)) =
    case re of
      ReasonCustom e -> getErrMessage e
      ReasonExpect expected actual -> ["Expected string: '" <> expected <> "' but found: '" <> actual <> "'"]
      ReasonDemand expected actual -> ["Expected num chars: " <> T.pack (show expected) <> " but got: " <> T.pack (show actual)]
      ReasonLeftover count -> ["Expected end but had leftover: " <> T.pack (show count)]
      ReasonAlt name errs ->
        let hd = "Alternatives failed: " <> name
            tl = indent 1 $ do
              (n, e) <- toList errs
              let x = "Tried alternative: " <> n
              x : indent 1 (getErrMessage e)
        in  hd : tl
      ReasonInfix op errs ->
        let hd = "Infix operator failed: " <> op
            tl = indent 1 $ do
              (i, s, e) <- toList errs
              let x = "Tried position: " <> T.pack (show i) <> " (" <> (if s == SideLeft then "left" else "right") <> ")"
              x : indent 1 (getErrMessage e)
        in  hd : tl
      ReasonEmptySearch -> ["Empty string search"]
      ReasonFail msg -> ["User reported failure: " <> msg]

errataE :: HasErrMessage e => FilePath -> (Int -> (E.Line, E.Column)) -> Err e -> [E.Errata]
errataE fp mkP e =
  let (line, col) = mkP (rangeStart (errRange e))
      msg = getErrMessage e
      block = E.blockSimple E.basicStyle E.basicPointer fp Nothing (line, col, col, Nothing) (Just (T.unlines msg))
  in  [E.Errata Nothing [block] Nothing]

renderE :: HasErrMessage e => FilePath -> Text -> Err e -> Text
renderE fp h e =
  let ov = mkOffsetVec h
      mkP = if V.null ov then const (1, 1) else \i -> let (!l, !c) = ov V.! i in (l + 1, c + 1)
  in  TL.toStrict (E.prettyErrors h (errataE fp mkP e))

printE :: HasErrMessage e => FilePath -> Text -> Err e -> IO ()
printE fp h e = TIO.hPutStrLn stderr (renderE fp h e)

data Value = ValueNull | ValueString !Text | ValueArray !(Seq Value) | ValueObject !(Seq (Text, Value))
  deriving stock (Eq, Ord, Show)

jsonParser :: Parser Void Value
jsonParser = valP
 where
  valP = spaceP *> rawValP <* spaceP
  rawValP =
    altP
      "value"
      [ ("null", nullP)
      , ("str", strP)
      , ("array", arrayP)
      , ("object", objectP)
      ]
  nullP = ValueNull <$ expectP "null"
  rawStrP = betweenP (expectP "\"") (expectP "\"") (takeWhileP (/= '"'))
  strP = ValueString <$> rawStrP
  arrayP = ValueArray <$> betweenP (expectP "[") (expectP "]") (sepByP (expectP ",") valP)
  rawPairP = do
    s <- rawStrP
    spaceP
    expectP ":"
    spaceP
    v <- rawValP
    pure (s, v)
  pairP = spaceP *> rawPairP <* spaceP
  objectP = ValueObject <$> betweenP (expectP "{") (expectP "}") (sepByP (expectP ",") pairP)

data Arith
  = ArithNum !Int
  | ArithVar !Text
  | ArithNeg Arith
  | ArithMul Arith Arith
  | ArithAdd Arith Arith
  | ArithSub Arith Arith
  deriving stock (Eq, Ord, Show)

arithParser :: Parser Void Arith
arithParser = rootP
 where
  addDigit n d = n * 10 + d
  digitP = altP "digit" (fmap (\i -> let j = T.pack (show i) in (j, i <$ expectP j)) [0 .. 9])
  identP = takeWhile1P isAlpha
  numP = foldl' addDigit 0 <$> greedy1P digitP
  binaryP f op = uncurry f <$> infixP op rootP rootP
  rawRootP =
    altP
      "root"
      [ ("add", binaryP ArithAdd "+")
      , ("sub", binaryP ArithSub "-")
      , ("mul", binaryP ArithMul "*")
      , -- , ("neg", _)
        ("paren", betweenP (expectP "(") (expectP ")") rootP)
      , ("num", ArithNum <$> numP)
      , ("var", ArithVar <$> identP)
      ]
  rootP = spaceP *> rawRootP <* spaceP
