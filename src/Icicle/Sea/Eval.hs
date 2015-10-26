{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
module Icicle.Sea.Eval (
    SeaError (..)
  , seaEval
  ) where

import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Either (EitherT(..), hoistEither)

import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Vector.Storable.Mutable (IOVector)
import qualified Data.Vector.Storable.Mutable as MV
import           Data.Word (Word64)

import           Foreign.ForeignPtr (ForeignPtr, touchForeignPtr, castForeignPtr)
import           Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import           Foreign.Marshal (mallocBytes, free)
import           Foreign.Ptr (Ptr)
import           Foreign.Storable (Storable(..))

import           Icicle.Avalanche.Prim.Flat (Prim)
import           Icicle.Avalanche.Program (Program)
import           Icicle.Avalanche.Statement.Statement (FactLoopType(..))
import           Icicle.Common.Annot (Annot)
import           Icicle.Common.Base
import           Icicle.Common.Data (asAtValueToCore, valueFromCore)
import           Icicle.Common.Type (ValType(..), defaultOfType)
import qualified Icicle.Data as D
import           Icicle.Data.DateTime (dateOfDays, daysOfDate)
import           Icicle.Internal.Pretty ((<+>), pretty, text)
import           Icicle.Internal.Pretty (Doc, Pretty, displayS, renderPretty)
import           Icicle.Sea.FromAvalanche (factVarsOfProgram, outputsOfProgram)
import           Icicle.Sea.FromAvalanche (seaOfProgram, stateWordsOfProgram)

import           Jetski

import           P hiding (count)

import           System.IO (IO)

import           X.Control.Monad.Catch (bracketEitherT')
import           X.Control.Monad.Trans.Either (firstEitherT)

------------------------------------------------------------------------

data SeaMVector
  = I64 (IOVector Int64)
  | U64 (IOVector Word64)
  | F64 (IOVector Double)

data SeaError
  = SeaJetskiError              JetskiError
  | SeaValueConversionError     D.Value   ValType
  | SeaBaseValueConversionError BaseValue ValType
  | SeaTypeConversionError      ValType
  | SeaNoFactLoop
  | SeaNoOutputs
  deriving (Eq, Show)

instance Pretty SeaError where
  pretty = \case
    SeaValueConversionError v t
     -> text "Cannot convert value " <> pretty v <+> text ":" <+> pretty t

    SeaBaseValueConversionError v t
     -> text "Cannot convert core value " <> pretty v <+> text ":" <+> pretty t

    SeaTypeConversionError t
     -> text "Cannot convert type " <> pretty t

    SeaNoFactLoop
     -> text "No fact loop"

    SeaNoOutputs
     -> text "No outputs"

    SeaJetskiError (CompilerError _ _ stderr)
     -> pretty stderr

    SeaJetskiError je
     -> pretty (show je)

------------------------------------------------------------------------

seaEval :: (Show a, Show n, Pretty n, Ord n)
        => Program (Annot a) n Prim
        -> D.DateTime
        -> [D.AsAt D.Value]
        -> EitherT SeaError IO [(OutputName, D.Value)]

seaEval program date values = do
  let words = stateWordsOfProgram program

  facts <- case factVarsOfProgram FactLoopNew program of
             Nothing     -> hoistEither (Left SeaNoFactLoop)
             Just (t, _) -> vectorsOfFacts values t

  withWords      words $ \pState -> do
  withSeaVectors facts $ \count psFacts -> do

    let dateIx    = 0
        countIx   = 1
        factsIx   = 2
        outputsIx = 2 + length psFacts

    -- clear the pState struct
    forM_ [0..(words-1)] $ \off ->
      pokeWordOff pState off (0 :: Word64)

    pokeWordOff pState dateIx  (wordOfDate date)
    pokeWordOff pState countIx (fromIntegral count :: Int64)

    zipWithM_ (pokeWordOff pState) [factsIx..] psFacts

    let code    = textOfDoc (seaOfProgram program)
        acquire = firstEitherT SeaJetskiError (compileLibrary compilerOptions code)
        release = releaseLibrary

    bracketEitherT' acquire release $ \lib -> do

      compute <- firstEitherT SeaJetskiError (function lib "compute" retVoid)
      _       <- liftIO (compute [argPtr pState])

      fmap (second valueFromCore) <$> peekOutputs pState outputsIx (outputsOfProgram program)

compilerOptions :: [CompilerOption]
compilerOptions =
  [ "-O3"           -- 🔨
  , "-march=native" -- 🚀  all optimisations valid for the current CPU (AVX512, etc)
  , "-std=c99"      -- 👹  variable declarations anywhere!
  , "-fPIC"         -- 🌏  position independent code, required on Linux
  ]

textOfDoc :: Doc -> Text
textOfDoc doc = T.pack (displayS (renderPretty 0.8 80 (pretty doc)) "")

------------------------------------------------------------------------

lengthOfSeaVector :: SeaMVector -> Int
lengthOfSeaVector = \case
  I64 v -> MV.length v
  U64 v -> MV.length v
  F64 v -> MV.length v

ptrOfSeaVector :: SeaMVector -> ForeignPtr Word64
ptrOfSeaVector = \case
  I64 v -> castForeignPtr . fst $ MV.unsafeToForeignPtr0 v
  U64 v -> castForeignPtr . fst $ MV.unsafeToForeignPtr0 v
  F64 v -> castForeignPtr . fst $ MV.unsafeToForeignPtr0 v


withSeaVectors :: [SeaMVector]
               -> (Int -> [Ptr Word64] -> EitherT SeaError IO a)
               -> EitherT SeaError IO a
withSeaVectors []       io = io 0 []
withSeaVectors (sv:svs) io =
  withSeaVector  sv  $ \len ptr  ->
  withSeaVectors svs $ \_   ptrs ->
  io len (ptr : ptrs)

withSeaVector :: SeaMVector
              -> (Int -> Ptr Word64 -> EitherT SeaError IO a)
              -> EitherT SeaError IO a
withSeaVector sv io =
  withForeignPtr (ptrOfSeaVector sv) (io (lengthOfSeaVector sv))

------------------------------------------------------------------------


vectorsOfFacts :: [D.AsAt D.Value] -> ValType -> EitherT SeaError IO [SeaMVector]
vectorsOfFacts vs t = do
  let vs' = fmap asAtValueToCore vs
  svs <- newSeaVectors (length vs') t
  zipWithM_ (pokeInput svs t) [0..] vs'
  pure svs

newSeaVectors :: Int -> ValType -> EitherT SeaError IO [SeaMVector]
newSeaVectors sz t =
  case t of
    IntT{}      -> (:[]) . I64 <$> liftIO (MV.new sz)
    DoubleT{}   -> (:[]) . F64 <$> liftIO (MV.new sz)
    UnitT{}     -> (:[]) . U64 <$> liftIO (MV.new sz)
    BoolT{}     -> (:[]) . U64 <$> liftIO (MV.new sz)
    DateTimeT{} -> (:[]) . I64 <$> liftIO (MV.new sz)
    ErrorT{}    -> (:[]) . U64 <$> liftIO (MV.new sz)

    StringT{}   -> hoistEither (Left (SeaTypeConversionError t))
    ArrayT{}    -> hoistEither (Left (SeaTypeConversionError t))
    MapT{}      -> hoistEither (Left (SeaTypeConversionError t))
    StructT{}   -> hoistEither (Left (SeaTypeConversionError t))
    BufT{}      -> hoistEither (Left (SeaTypeConversionError t))

    PairT ta tb
     -> do va <- newSeaVectors sz ta
           vb <- newSeaVectors sz tb
           pure (va <> vb)

    SumT ta tb
     -> do vi <- newSeaVectors sz BoolT
           va <- newSeaVectors sz ta
           vb <- newSeaVectors sz tb
           pure (vi <> va <> vb)

    OptionT tx
     -> do vb <- newSeaVectors sz BoolT
           vx <- newSeaVectors sz tx
           pure (vb <> vx)

pokeInput :: [SeaMVector] -> ValType -> Int -> BaseValue -> EitherT SeaError IO ()
pokeInput svs t ix val = do
  svs' <- pokeInput' svs t ix val
  case svs' of
    [] -> pure ()
    _  -> hoistEither (Left (SeaBaseValueConversionError val t))

pokeInput' :: [SeaMVector] -> ValType -> Int -> BaseValue -> EitherT SeaError IO [SeaMVector]
pokeInput' []            t _  val = hoistEither (Left (SeaBaseValueConversionError val t))
pokeInput' svs0@(sv:svs) t ix val =
  case (sv, val, t) of
    (U64 v, VBool False, BoolT{})     -> pure svs <* liftIO (MV.write v ix 0)
    (U64 v, VBool  True, BoolT{})     -> pure svs <* liftIO (MV.write v ix 1)
    (I64 v, VInt      x, IntT{})      -> pure svs <* liftIO (MV.write v ix (fromIntegral x))
    (F64 v, VDouble   x, DoubleT{})   -> pure svs <* liftIO (MV.write v ix x)
    (I64 v, VDateTime x, DateTimeT{}) -> pure svs <* liftIO (MV.write v ix (wordOfDate x))
    (U64 v, VError    x, ErrorT{})    -> pure svs <* liftIO (MV.write v ix (wordOfError x))

    (_, VPair a b, PairT ta tb)
     -> do svs1 <- pokeInput' svs0 ta ix a
           svs2 <- pokeInput' svs1 tb ix b
           pure svs2

    (_, VLeft a, SumT ta tb)
     -> do svs1 <- pokeInput' svs0 BoolT ix (VBool False)
           svs2 <- pokeInput' svs1 ta    ix a
           svs3 <- pokeInput' svs2 tb    ix (defaultOfType tb)
           pure svs3

    (_, VRight b, SumT ta tb)
     -> do svs1 <- pokeInput' svs0 BoolT ix (VBool True)
           svs2 <- pokeInput' svs1 ta    ix (defaultOfType ta)
           svs3 <- pokeInput' svs2 tb    ix b
           pure svs3

    _
     -> hoistEither (Left (SeaBaseValueConversionError val t))

------------------------------------------------------------------------

peekOutputs :: Ptr a
            -> Int
            -> [(OutputName, (ValType, [ValType]))]
            -> EitherT SeaError IO [(OutputName, BaseValue)]

peekOutputs _ _ []                     = pure []
peekOutputs ptr ix ((n, (t, _)) : ots) = do
  nvs    <- peekOutputs ptr (ix+1) ots
  (_, v) <- peekOutput  ptr ix t
  pure ((n, v) : nvs)


peekOutput :: Ptr a -> Int -> ValType -> EitherT SeaError IO (Int, BaseValue)
peekOutput ptr ix0 t =
  case t of
    UnitT{}     -> (ix0+1,)                           <$> pure VUnit
    IntT{}      -> (ix0+1,) . VInt      . fromInt64   <$> peekWordOff ptr ix0
    DoubleT{}   -> (ix0+1,) . VDouble                 <$> peekWordOff ptr ix0
    DateTimeT{} -> (ix0+1,) . VDateTime . dateOfWord  <$> peekWordOff ptr ix0
    ErrorT{}    -> (ix0+1,) . VError    . errorOfWord <$> peekWordOff ptr ix0

    StringT{}   -> hoistEither (Left (SeaTypeConversionError t))
    ArrayT{}    -> hoistEither (Left (SeaTypeConversionError t))
    MapT{}      -> hoistEither (Left (SeaTypeConversionError t))
    StructT{}   -> hoistEither (Left (SeaTypeConversionError t))
    BufT{}      -> hoistEither (Left (SeaTypeConversionError t))

    BoolT{}
     -> do b <- peekWordOff ptr ix0
           case (b :: Word64) of
             0 -> pure (ix0+1, VBool False)
             _ -> pure (ix0+1, VBool True)

    PairT ta tb
     -> do (ix1, va) <- peekOutput ptr ix0 ta
           (ix2, vb) <- peekOutput ptr ix1 tb
           pure (ix2, VPair va vb)

    SumT ta tb
     -> do (ix1, vi) <- peekOutput ptr ix0 BoolT
           (ix2, va) <- peekOutput ptr ix1 ta
           (ix3, vb) <- peekOutput ptr ix2 tb
           pure (ix3, if vi == VBool False then VLeft va else VRight vb)

    OptionT tx
     -> do (ix1, vb) <- peekOutput ptr ix0 BoolT
           (ix2, vx) <- peekOutput ptr ix1 tx
           pure (ix2, if vb == VBool False then VNone else VSome vx)

------------------------------------------------------------------------

withForeignPtr :: ForeignPtr a -> (Ptr a -> EitherT SeaError IO b) -> EitherT SeaError IO b
withForeignPtr fp io = do
  x <- io (unsafeForeignPtrToPtr fp)
  liftIO (touchForeignPtr fp)
  pure x

withWords :: Int -> (Ptr a -> EitherT SeaError IO b) -> EitherT SeaError IO b
withWords n = bracketEitherT' (mallocWords n) (liftIO . free)

mallocWords :: MonadIO m => Int -> m (Ptr a)
mallocWords n = liftIO (mallocBytes (n*8))

pokeWordOff :: (MonadIO m, Storable a) => Ptr x -> Int -> a -> m ()
pokeWordOff ptr off x = liftIO (pokeByteOff ptr (off*8) x)

peekWordOff :: (MonadIO m, Storable a) => Ptr x -> Int -> m a
peekWordOff ptr off = liftIO (peekByteOff ptr (off*8))

fromInt64 :: Int64 -> Int
fromInt64 = fromIntegral

wordOfDate :: D.DateTime -> Int64
wordOfDate = fromIntegral . daysOfDate

dateOfWord :: Int64 -> D.DateTime
dateOfWord = dateOfDays . fromIntegral

wordOfError :: ExceptionInfo -> Word64
wordOfError = \case
  ExceptTombstone                  -> 0
  ExceptFold1NoValue               -> 1
  ExceptScalarVariableNotAvailable -> 2

errorOfWord :: Word64 -> ExceptionInfo
errorOfWord = \case
  0 -> ExceptTombstone
  1 -> ExceptFold1NoValue
  2 -> ExceptScalarVariableNotAvailable
  _ -> ExceptTombstone
