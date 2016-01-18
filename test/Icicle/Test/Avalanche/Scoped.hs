{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Icicle.Test.Avalanche.Scoped where

import           Icicle.Test.Core.Arbitrary
import           Icicle.Test.Arbitrary

import           Icicle.Core.Program.Check
import qualified Icicle.Core.Eval.Exp       as XV

import qualified Icicle.Avalanche.FromCore  as AC
import qualified Icicle.Avalanche.Eval      as AE
import qualified Icicle.Avalanche.Statement.Scoped    as AS
import qualified Icicle.Avalanche.Program   as AP


import           Icicle.Internal.Pretty

import           P

import           System.IO

import           Test.QuickCheck

-- We need a way to differentiate stream variables from scalars
namer = AC.namerText (flip Var 0)


-- Turning to Scoped and back doesn't affect evaluation
prop_scoped_and_back t =
 forAll (programForStreamType t)
 $ \p ->
 forAll (inputsForType t)
 $ \(vs,d) ->
    isRight     (checkProgram p) ==>
     let p' = AC.programFromCore namer p

         scop = AS.scopedOfStatement $ AP.statements p'
         p''  = p' { AP.statements = AS.statementOfScoped scop }
         eval = AE.evalProgram XV.evalPrim d vs
     in counterexample (show $ pretty p')
      $ counterexample (show $ pretty scop)
      $ counterexample (show $ pretty p'')
       (eval p' === eval p'')


return []
tests :: IO Bool
-- tests = $quickCheckAll
-- tests = $forAllProperties $ quickCheckWithResult (stdArgs {maxSuccess = 10000})

tests = $forAllProperties $ quickCheckWithResult (stdArgs {maxSuccess = 100, maxSize = 10, maxDiscardRatio = 10000})
