{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Core.Exp.Simp
     ( simp
     , simpX
     , simpP
     , simpMP
     ) where

import           Icicle.Common.Base
import           Icicle.Common.Exp              hiding (simp)
import qualified Icicle.Common.Exp.Prim.Minimal as M
import           Icicle.Common.Exp.Simp.ANormal
import qualified Icicle.Common.Exp.Simp.Beta    as B
import           Icicle.Common.Fresh
import           Icicle.Common.Type
import qualified Icicle.Core.Exp                as C
import           Icicle.Core.Exp.Prim

import           P


-- | Core Simplifier:
--   * a normal
--   * beta reduction
--   * constant folding for some primitives
--   * ...something exciting???
--
simp :: Ord n => (C.Exp n -> Bool) -> C.Exp n -> Fresh n (C.Exp n)
simp isValue = anormal . simpX isValue


simpX :: Ord n => (C.Exp n -> Bool) -> C.Exp n -> C.Exp n
simpX isValue = go
  where
    beta  = B.beta isValue
    go xx = case beta xx of
      -- * constant folding for some primitives
      XApp{}
        | Just (p, as) <- takePrimApps xx
        , Just args    <- sequenceA (fmap takeValue as)
        -> fromMaybe xx (simpP p args)

      -- * beta reduce primitive arguments
      XApp{}
        | Just (p, as) <- takePrimApps xx
        -> makeApps (XPrim p) (fmap beta as)

      -- * leaves everything else alone
      _ -> xx

-- | Primitive Simplifier
--
simpP :: Prim -> [(ValType, BaseValue)] -> Maybe (C.Exp n)
simpP = go
  where
    go pp args = case pp of
      PrimMinimal mp  -> simpMP mp args
      -- * leaves fold and map alone for now..?
      PrimFold    _ _ -> Nothing
      PrimMap     _   -> Nothing

simpMP :: M.Prim -> [(ValType, BaseValue)] -> Maybe (C.Exp n)
simpMP = go
  where
    go pp args = case pp of
      -- * arithmetic on constant integers
      M.PrimArith M.PrimArithPlus
        -> arith2 pp args (+)
      M.PrimArith M.PrimArithMinus
        -> arith2 pp args (-)
      M.PrimArith M.PrimArithDiv
        -> arith2 pp args div
      M.PrimArith M.PrimArithMul
        -> arith2 pp args (*)
      M.PrimArith M.PrimArithNegate
        | [(_, VInt x)] <- args
        -> let t = functionReturns (M.typeOfPrim pp)
           in  return $ XValue t (VInt (-x))

      -- * predicates on integers
      M.PrimRelation M.PrimRelationGt IntT
        -> int2 args (>)
      M.PrimRelation M.PrimRelationGe IntT
        -> int2 args (>=)
      M.PrimRelation M.PrimRelationLt IntT
        -> int2 args (<)
      M.PrimRelation M.PrimRelationLe IntT
        -> int2 args (<)
      M.PrimRelation M.PrimRelationEq IntT
        -> int2 args (==)
      M.PrimRelation M.PrimRelationNe IntT
        -> int2 args (/=)

      -- * logical
      M.PrimLogical M.PrimLogicalAnd
        -> bool2 args (&&)
      M.PrimLogical M.PrimLogicalOr
        -> bool2 args (||)
      M.PrimLogical M.PrimLogicalNot
        -> bool1 args not

      -- * leaves baked-in constants and datetime alone
      M.PrimConst    _ -> Nothing
      M.PrimDateTime _ -> Nothing

    bool1 args f
      | [(_, VBool x)] <- args
      = return $ XValue BoolT (VBool (f x))

    bool2 args f
      | [(_, VBool x), (_, VBool y)] <- args
      = return $ XValue BoolT (VBool (f x y))

    int2 args f
      | [(_, VInt x), (_, VInt y)] <- args
      = return $ XValue BoolT (VBool (f x y))

    arith2 pp args f
      | [(_, VInt x), (_, VInt y)] <- args
      = let t = functionReturns (M.typeOfPrim pp)
            v = x + y
        in  return $ XValue t (VInt v)


takeValue :: Exp n p -> Maybe (ValType, BaseValue)
takeValue (XValue a b) = Just (a, b)
takeValue _            = Nothing

