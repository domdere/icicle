{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards#-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell#-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Icicle.Test.Arbitrary.Corpus where

import qualified Data.Set as Set
import qualified Data.Text as Text

import           Icicle.Common.Base

import           Icicle.Test.Arbitrary.Program
import           Icicle.Test.Arbitrary.Data

import qualified Icicle.Sea.Eval as S

import           Icicle.Dictionary.Data
import           Icicle.Data
import qualified Icicle.Data as Data
import qualified Icicle.Storage.Dictionary.Toml as DictionaryLoad

import qualified Icicle.Compiler.Source as Source
import qualified Icicle.Compiler        as Compiler

import           P

import           Test.QuickCheck

import qualified Icicle.Core                    as C
import qualified Icicle.Source.Lexer.Token as T

import qualified Prelude as Savage

inputs :: [(InputName, Encoding)]
inputs =
 [ ([inputname|int|]
   , IntEncoding)
 , ([inputname|string|]
   , StringEncoding)
 , ([inputname|injury|]
   , StructEncoding [field "location" StringEncoding, optfield "action" StringEncoding, field "severity" IntEncoding])
 ]
 where
  optfield name encoding
   = Data.StructField Data.Optional name encoding
  field name encoding
   = Data.StructField Data.Mandatory name encoding

queries :: [(OutputId, Text)]
queries =
 [ ([outputid|s:int_oldest|]
   , "feature int ~> oldest value")
 , ([outputid|s:string_oldest|]
   , "feature string ~> oldest value")
 , ([outputid|s:string_count|]
   , "feature string ~> count value")
 , ([outputid|s:string_group|]
   , "feature string ~> group value ~> count value")
 , ([outputid|s:string_group2|]
   , "feature string ~> group value ~> group value ~> count value")

 , ([outputid|i:injury_group2|]
   , "feature injury ~> group location ~> group action ~> sum severity")
 , ([outputid|i:injury_group3|]
   , "feature injury ~> group location ~> group action ~> group severity ~> sum severity")

 , ([outputid|i:injury_group_pair|]
   , "feature injury ~> group (location, action) ~> sum severity")

 , ([outputid|i:injury_group_crazy|]
   , Text.unlines
   [ "feature injury"
   , "~> windowed 7 days"
   , "~> let is_homer = location == \"homer\""
   , "~> fold x = (map_create, None)"
   , "   : case tombstone"
   , "     | True -> (map_create, Some time)"
   , "     | False ->"
   , "       case snd x"
   , "       | None ->"
   , "         case is_homer"
   , "         | True -> (map_insert location severity (fst x), Some time)"
   , "         | False -> (fst x, Some time)"
   , "         end"
   , "       | Some t ->"
   , "         case time == t"
   , "         | True ->"
   , "           case is_homer"
   , "           | True -> (map_insert location severity (fst x), Some time)"
   , "           | False -> (fst x, Some time)"
   , "           end"
   , "         | False ->"
   , "           case is_homer"
   , "           | True -> (map_insert location severity map_create, Some time)"
   , "           | False -> (map_create, Some time)"
   , "           end"
   , "         end"
   , "       end"
   , "     end"
   , "~> (group fold (k, v) = fst x ~> min v)"
   ])
 ]



wellTypedCorpus :: Gen WellTyped
wellTypedCorpus = genCore >>= genWellTyped

testAllCorpus :: (WellTyped -> Property) -> Property
testAllCorpus prop
 = conjoin $ fmap run queries
 where
  run q = forAll (gen q) prop

  gen (name,src)
   = case coreOfSource name src of
      Left u -> Savage.error (Text.unpack (renderOutputId name) <> ":\n" <> Text.unpack src <> "\n\n" <> u)
      Right core -> genWellTyped (name, core)

genWellTyped :: (OutputId, C.Program () Var) -> Gen WellTyped
genWellTyped (name, core)
 = do wt <- tryGenWellTypedFromCoreEither S.AllowDupTime (streamType core) core
      case wt of
       Left err  -> Savage.error (Text.unpack (renderOutputId name) <> "\n\n" <> err)
       Right wt' -> return wt'
 where
  streamType c
   = InputType $ C.inputType c


genCore :: Gen (OutputId, C.Program () Var)
genCore = do
  (name,src) <- elements queries
  case coreOfSource name src of
   Left u -> Savage.error (Text.unpack (renderOutputId name) <> ":\n" <> Text.unpack src <> "\n\n" <> u)
   Right core -> return (name, core)

prelude :: Either Savage.String [DictionaryFunction]
prelude =
  DictionaryLoad.fromFunEnv . mconcat <$>
    nobodyCares (mapM (uncurry $ Source.readIcicleLibrary "check") DictionaryLoad.prelude)

inputDictionary :: Either Savage.String Dictionary
inputDictionary =
  let
    mkEntry (n, v) =
      DictionaryInput (InputId [namespace|corpus|] n) v (Set.singleton tombstone) (InputKey Nothing)
  in
    Dictionary
      (mapOfInputs $ fmap mkEntry inputs)
      (mapOfOutputs [])
      <$> prelude

coreOfSource :: OutputId -> Text -> Either Savage.String (C.Program () Var)
coreOfSource oid src
 = do d0 <- inputDictionary
      parsed <- nobodyCares $ Source.queryOfSource Source.defaultCheckOptions d0 oid src
      core0 <- nobodyCares $ Compiler.coreOfSource1 Source.defaultCompileOptions d0 parsed
      let core1 = C.renameProgram varOfVariable core0
      return core1

varOfVariable :: Name T.Variable -> Name Var
varOfVariable = nameOf . fmap (\(T.Variable v) -> Var v 0) . nameBase

tombstone :: Text
tombstone = "💀"
