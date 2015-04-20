-- | Working with values and their encodings.
-- Parsing, rendering etc.
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Encoding (
    DecodeError (..)
  , renderDecodeError
  , renderValue
  , parseValue
  , encodingOfValue
  , primitiveEncoding
  , valueOfJSON
  , jsonOfValue
  , attributeOfStructField
  ) where

import           Data.Attoparsec.ByteString
import           Data.Text      as T
import           Data.Text.Read as T
import           Data.Text.Encoding as T

import qualified Data.Aeson     as A
import qualified Data.Scientific as S

import qualified Data.HashMap.Strict as HM
import qualified Data.Vector         as V
import qualified Data.ByteString.Lazy as BS

import           Icicle.Data

import           P


data DecodeError =
   DecodeErrorBadInput Text Encoding
 | DecodeErrorMissingStructField Attribute
   deriving (Eq, Show)


renderDecodeError :: DecodeError -> Text
renderDecodeError (DecodeErrorBadInput val enc) =
  "Could not decode value '" <> val <> "' of type " <> T.pack (show enc)
renderDecodeError (DecodeErrorMissingStructField attr) =
  "Missing struct field " <> getAttribute attr

primitiveEncoding :: Encoding -> Bool
primitiveEncoding e
 = case e of
   StringEncoding   -> True
   IntEncoding      -> True
   DoubleEncoding   -> True
   BooleanEncoding  -> True
   DateEncoding     -> True
   _                -> False


-- | Attempt to get encoding of value.
-- This can fail in two ways:
--   - a list is given, but not all values of the list are the same;
--   - a tombstone is given.
--
-- There is one ambiguous case, the empty list, where we default to list of string.
encodingOfValue :: Value -> Maybe Encoding
encodingOfValue val
 = case val of
    StringValue  _ -> return StringEncoding
    IntValue     _ -> return IntEncoding
    DoubleValue  _ -> return DoubleEncoding
    BooleanValue _ -> return BooleanEncoding
    DateValue    _ -> return DateEncoding
    StructValue  s -> StructEncoding <$> encodingOfStruct s
    ListValue    l -> ListEncoding   <$> encodingOfList   l

    Tombstone      -> Nothing
 where
  encodingOfStruct (Struct s)
   = mapM getStructField s

  getStructField (a,v)
   = MandatoryField a <$> encodingOfValue v

  encodingOfList (List vals)
   = do es <- mapM encodingOfValue vals
        case es of
         []
          -> return StringEncoding
         (x:xs)
          -> if   P.all (==x) xs
             then return x
             else Nothing



-- | Render value in a form readable by "parseValue".
renderValue :: Text -> Value -> Text
renderValue tombstone val
 = case val of
   StringValue v
    -> v
   IntValue v
    -> T.pack $ show v
   DoubleValue v
    -> T.pack $ show v
   BooleanValue v
    -> T.pack $ show v
   DateValue (Date v)
    -> v

   StructValue _
    -> json
   ListValue _
    -> json
   Tombstone
    -> tombstone
 where
  json
   = T.decodeUtf8
   $ BS.toStrict
   $ A.encode
   $ jsonOfValue (A.String tombstone) val
   

-- | Attempt to decode value with given encoding.
-- Some values may fit multiple encodings.
parseValue :: Encoding -> Text -> Either DecodeError Value
parseValue e t
 = case e of
    StringEncoding
     -> return (StringValue t)

    IntEncoding
     -> tryDecode IntValue      (T.signed T.decimal)
    DoubleEncoding
     -> tryDecode DoubleValue   (T.signed T.double)

    BooleanEncoding
     | T.toLower t == "true"
     -> return $ BooleanValue True
     | T.toLower t == "false"
     -> return $ BooleanValue False
     | otherwise
     -> Left err
       
    DateEncoding
     -- TODO parse date
     -> return $ DateValue $ Date t

    StructEncoding _
     | Right v <- parsed
     -> valueOfJSON e v
     | otherwise
     -> Left err

    ListEncoding _
     | Right v <- parsed
     -> valueOfJSON e v
     | otherwise
     -> Left err

 where
  tryDecode f p
   = f <$> maybeToRight err (readAll p t)
  err
   = DecodeErrorBadInput t e

  parsed
   = parseOnly A.json
   $ T.encodeUtf8 t


-- | Attempt to decode value from JSON
valueOfJSON :: Encoding -> A.Value -> Either DecodeError Value
valueOfJSON e v
 = case e of
    StringEncoding
     | A.String t <- v
     -> return $ StringValue t
     | A.Number n <- v
     -> return $ StringValue $ T.pack $ show n
     | otherwise
     -> Left err

    IntEncoding
     | A.Number n <- v
     , Just   i <- S.toBoundedInteger n
     -> return $ IntValue $ i
     | otherwise
     -> Left err

    DoubleEncoding
     | A.Number n <- v
     -> return $ DoubleValue $ S.toRealFloat n
     | otherwise
     -> Left err

    BooleanEncoding
     | A.Bool b <- v
     -> return $ BooleanValue b
     | otherwise
     -> Left err
       
    DateEncoding
     -- TODO parse date
     | A.String t <- v
     -> return $ DateValue $ Date t
     | otherwise
     -> Left err

    StructEncoding fields
     | A.Object obj <- v
     ->  StructValue . Struct . P.concat
     <$> mapM (getStructField obj) fields
     | otherwise
     -> Left err

    ListEncoding l
     | A.Array arr <- v
     ->  ListValue . List
     <$> mapM (valueOfJSON l) (V.toList arr)
     | otherwise
     -> Left err

 where
  err
   = DecodeErrorBadInput (T.pack $ show v) e

  getStructField obj field
   = case field of
      MandatoryField attr enc
       | Just val <- getField obj attr
       -> do    v' <- valueOfJSON enc val
                return [(attr, v')]
       | otherwise
       -> Left  (DecodeErrorMissingStructField attr)

      OptionalField  attr enc
       | Just val <- getField obj attr
       -> do    v' <- valueOfJSON enc val
                return [(attr, v')]
       | otherwise
       -> return []

  getField obj attr
   = HM.lookup (getAttribute attr) obj
      

jsonOfValue :: A.Value -> Value -> A.Value
jsonOfValue tombstone val
 = case val of
    StringValue v
     -> A.String v
    IntValue v
     -> A.Number $ P.fromIntegral v
    DoubleValue v
     -> A.Number $ S.fromFloatDigits v
    BooleanValue v
     -> A.Bool   v
    DateValue    (Date v)
     -- TODO dates
     -> A.String v
    StructValue (Struct sfs)
     -> A.Object $ P.foldl insert HM.empty sfs
    ListValue (List l)
     -> A.Array  $ V.fromList $ fmap (jsonOfValue tombstone) l
    Tombstone
     -> tombstone
 where
  insert hm (attr,v)
   = HM.insert (getAttribute attr) (jsonOfValue tombstone v) hm


-- | Perform read, only succeed if all input is used
readAll :: T.Reader a -> T.Text -> Maybe a
readAll r t
 | Right (v, rest) <- r t
 , T.null rest
 = Just v

 | otherwise
 = Nothing


attributeOfStructField :: StructField -> Attribute
attributeOfStructField (MandatoryField attr _)
  = attr
attributeOfStructField (OptionalField attr _)
  = attr

