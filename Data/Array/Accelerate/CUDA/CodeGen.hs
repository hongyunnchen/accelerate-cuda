{-# LANGUAGE GADTs               #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS -fno-warn-name-shadowing #-}

-- |
-- Module      : Data.Array.Accelerate.CUDA.CodeGen
-- Copyright   : [2008..2010] Manuel M T Chakravarty, Gabriele Keller, Sean Lee
--               [2009..2012] Manuel M T Chakravarty, Gabriele Keller, Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.CUDA.CodeGen (

--  CUTranslSkel, codegenAcc,

) where

-- libraries
import Prelude                                                  hiding ( id, exp, replicate )
import Control.Applicative                                      ( (<$>), (<*>) )
import Control.Monad.State.Strict
import Data.Loc
import Data.Char
import Data.HashSet                                             ( HashSet )
import Foreign.CUDA.Analysis
import Language.C.Quote.CUDA
import qualified Language.C                                     as C
import qualified Data.HashSet                                   as Set
import qualified Data.Map                                       as M
import qualified Data.HashMap.Strict                    as Map
import Data.HashMap.Strict                              ( HashMap ) 

-- friends
-- import Data.Array.Accelerate.Type
-- import Data.Array.Accelerate.Tuple
-- import Data.Array.Accelerate.Pretty                             ()
-- import Data.Array.Accelerate.Analysis.Shape
-- import Data.Array.Accelerate.Array.Sugar                        ( Array, Shape, Elt, EltRepr )
-- import Data.Array.Accelerate.Array.Representation               ( SliceIndex(..) )
-- import qualified Data.Array.Accelerate.Trafo                    as Trafo
-- import qualified Data.Array.Accelerate.Array.Sugar              as Sugar
-- import qualified Data.Array.Accelerate.Analysis.Type            as Sugar

import Data.Array.Accelerate.BackendKit.IRs.SimpleAcc as S
import Data.Array.Accelerate.Error
-- import Data.Array.Accelerate.Type
-- import Data.Array.Accelerate.Tuple
-- import Data.Array.Accelerate.Trafo
-- import Data.Array.Accelerate.Pretty                             ()
-- import Data.Array.Accelerate.Analysis.Shape
-- import Data.Array.Accelerate.Array.Sugar                        ( Array, Shape, Elt, EltRepr )
-- import Data.Array.Accelerate.Array.Representation               ( SliceIndex(..) )
-- import qualified Data.Array.Accelerate.Array.Sugar              as Sugar
-- import qualified Data.Array.Accelerate.Analysis.Type            as Sugar

import Data.Array.Accelerate.CUDA.AST                           hiding ( Val(..), prj )
import Data.Array.Accelerate.CUDA.CodeGen.Base                  hiding ( zipWith ) 
import Data.Array.Accelerate.CUDA.CodeGen.Type
import Data.Array.Accelerate.CUDA.CodeGen.Monad
import Data.Array.Accelerate.CUDA.CodeGen.Mapping
import Data.Array.Accelerate.CUDA.CodeGen.IndexSpace
import Data.Array.Accelerate.CUDA.CodeGen.PrefixSum

-- import Data.Array.Accelerate.CUDA.CodeGen.Reduction
-- import Data.Array.Accelerate.CUDA.CodeGen.Stencil
-- import Data.Array.Accelerate.CUDA.CodeGen.Reduction
-- import Data.Array.Accelerate.CUDA.CodeGen.Stencil
-- import Data.Array.Accelerate.CUDA.Foreign.Import                ( canExecuteExp ) 


-- #include "accelerate.h"


-- Local environments
-- data Val = Empty | Push Val S.Type [C.Exp]
-- type ValEnv = [(S.Type,[C.Exp])]
type ValEnv = M.Map S.Var (S.Type,[C.Exp])

-- Local environments
--
-- data Val env where
--   Empty ::                       Val ()
--   Push  :: Val env -> [C.Exp] -> Val (env, s)

-- prj :: Idx env t -> Val env -> [C.Exp]
-- prj ZeroIdx      (Push _   v) = v
-- prj (SuccIdx ix) (Push val _) = prj ix val
-- prj _            _            = $internalError "prj" "inconsistent valuation"
-- >>>>>>> master

-- prj :: Idx env t -> Val env -> [C.Exp]
-- prj ZeroIdx      (Push _   v) = v
-- prj (SuccIdx ix) (Push val _) = prj ix val
-- prj _            _            = INTERNAL_ERROR(error) "prj" "inconsistent valuation"

-- Array expressions
-- -----------------

-- | Instantiate an array computation with a set of concrete function and type
-- definitions to fix the parameters of an algorithmic skeleton. The generated
-- code can then be pretty-printed to file, and compiled to object code
-- executable on the device. This generates a set of __global__ device functions
-- required to compute the given computation node.
--
-- The code generator requires that the only array form allowed within scalar
-- expressions are array variables. The list of array-valued scalar inputs are
-- taken as the environment.
--
-- TODO: include a measure of how much shared memory a kernel requires.
--

cpberror s = error $ "codedenProgBind: " ++ s

codegenProgBind :: DeviceProperties -> S.ProgBind decor -> Gamma -> CUDA [CUTranslSkel]
codegenProgBind dev (ProgBind v t decor (Left e)) aenv = undefined
codegenProgBind dev (ProgBind v t decor (Right ae)) aenv = doAE ae
  where
    doAE ae = case ae of
      Vr v          -> cpberror "Variable"
      Unit e        -> cpberror "Unit not implemented"
      Cond e1 e2 e3 -> cpberror "Cond not implemented"
      Use  a        -> cpberror "Use not implemented"
        -- I need a shape type and an element type. Cheat for now. 
      Generate e f  ->
        do f' <- codegenFun1 dev aenv  f
           return $ mkGenerate S.TInt t dev aenv f'

      Map f arrVar  ->
        do f' <- codegenFun1 dev aenv f
           return $ mkMap S.TInt t dev aenv f' arrVar
      
        

--mkGenerate shapeTy eltTy .. 
--mkGenerate :: S.Type -> S.Type -> 
--       DeviceProperties -> Gamma -> CUFun1 -> [CUTranslSkel]

codegenFun1 :: DeviceProperties -> Gamma -> S.Fun1 S.Exp -> CUDA CUFun1 -- aenv (a -> b))
codegenFun1 dev aenv (Lam1 (v,t) e) =
  let
    -- overkill simplify 
    go :: Rvalue x => [x] -> Gen ([C.BlockItem], [C.Exp])
    go x = do
      code  <- mapM use =<< codegenOpenExp dev e (M.singleton v (t,[cvar (show v)]) ) -- (Empty `Push` map rvalue x)
      env'  <- getEnv
      return (env', code)

      -- Initial code generation proceeds with dummy variable names. The real
      -- names are substituted later when we instantiate the skeleton.
    (_,u,_) = locals t (show v) -- "undefined_x" (undefined :: a)
  in do
    n                   <- get
    ExpST _ used lrms   <- execCGM (go u)
    return $ CUFun1 (mark used u)
      $ \xs -> evalState (evalCGM (go xs)) n 
 


codegenAcc :: DeviceProperties -> S.Prog a -> Gamma -> [ CUTranslSkel ]
codegenAcc dev prog@(S.Prog {progBinds}) aenv
  = concat (map doProgBind progBinds)
 where
    doProgBind (S.ProgBind {}) = undefined
    
    doAE ae = case ae of
--      Map f a -> mkMap dev aenv       <$> travF1 f <*> travS a
      _ -> error "FINISH codegenAcc"


      
      
{- RNTODO
      -- Producers


codegenAcc :: forall aenv arrs. DeviceProperties -> DelayedOpenAcc aenv arrs -> Gamma aenv -> [ CUTranslSkel aenv arrs ]
codegenAcc _   Delayed{}       _    = $internalError "codegenAcc" "expected manifest array"
codegenAcc dev (Manifest pacc) aenv
  = codegen
  $ case pacc of

      -- Producers
      Map f a                   -> mkMap dev aenv       <$> travF1 f <*> travD a
      Generate _ f              -> mkGenerate dev aenv  <$> travF1 f
      Transform _ p f a         -> mkTransform dev aenv <$> travF1 p <*> travF1 f  <*> travD a
      Backpermute _ p a         -> mkTransform dev aenv <$> travF1 p <*> travF1 id <*> travD a

      -- Consumers
      Fold f z a                -> mkFold  dev aenv     <$> travF2 f <*> travE z  <*> travD a
      Fold1 f a                 -> mkFold1 dev aenv     <$> travF2 f <*> travD a
      FoldSeg f z a s           -> mkFoldSeg dev aenv   <$> travF2 f <*> travE z  <*> travD a <*> travD s
      Fold1Seg f a s            -> mkFold1Seg dev aenv  <$> travF2 f <*> travD a  <*> travD s
      Scanl f z a               -> mkScanl dev aenv     <$> travF2 f <*> travE z  <*> travD a
      Scanr f z a               -> mkScanr dev aenv     <$> travF2 f <*> travE z  <*> travD a
      Scanl' f z a              -> mkScanl' dev aenv    <$> travF2 f <*> travE z  <*> travD a
      Scanr' f z a              -> mkScanr' dev aenv    <$> travF2 f <*> travE z  <*> travD a
      Scanl1 f a                -> mkScanl1 dev aenv    <$> travF2 f <*> travD a
      Scanr1 f a                -> mkScanr1 dev aenv    <$> travF2 f <*> travD a
      Permute f _ p a           -> mkPermute dev aenv   <$> travF2 f <*> travF1 p <*> travD a
      Stencil f b a             -> mkStencil dev aenv   <$> travF1 f <*> travB a b
      Stencil2 f b1 a1 b2 a2    -> mkStencil2 dev aenv  <$> travF2 f <*> travB a1 b1 <*> travB a2 b2

      -- Non-computation forms -> sadness
      Alet _ _                  -> unexpectedError
      Avar _                    -> unexpectedError
      Apply _ _                 -> unexpectedError
      Acond _ _ _               -> unexpectedError
      Atuple _                  -> unexpectedError
      Aprj _ _                  -> unexpectedError
      Use _                     -> unexpectedError
      Unit _                    -> unexpectedError

      Reshape _ _               -> fusionError
      Replicate _ _ _           -> fusionError
      Slice _ _ _               -> fusionError
      ZipWith _ _ _             -> fusionError
-}

    codegen :: CUDA a -> a
    codegen cuda = evalState cuda 0

    -- id :: Elt a => Fun aenv (a -> a)
    -- id = Lam (Body (Var ZeroIdx))

    -- scalar code generation
   -- travF1 :: S.Fun1 S.Exp -> CUDA (CUFun1)
   -- travF1 = codegenFun1 dev

    -- travF2 :: Fun aenv (a -> b -> c) -> CUDA (CUFun2 aenv (a -> b -> c))
    -- travF2 = codegenFun2 dev

    -- travE :: Exp aenv t -> CUDA (CUExp aenv t)
    -- travE = codegenExp dev

--    travS :: (Shape sh, Elt e) => OpenAcc aenv (Array sh e) -> CUDA (CUDelayedAcc aenv sh e)
    travS = error "travS "-- codegenDelayedAcc dev

    -- travB :: forall aenv sh e. Elt e
    --       => OpenAcc aenv (Array sh e) -> Boundary (EltRepr e) -> CUDA (Boundary (CUExp aenv e))
    -- travB _ Clamp        = return Clamp
    -- travB _ Mirror       = return Mirror
    -- travB _ Wrap         = return Wrap
    -- travB _ (Constant c) = return . Constant $ CUExp ([], codegenConst (Sugar.eltType (undefined::e)) c)

    -- -- caffeine and misery
    -- prim :: String
    -- prim                = showPreAccOp pacc
    -- unexpectedError     = INTERNAL_ERROR(error) "codegenAcc" $ "unexpected array primitive: " ++ prim
    -- fusionError         = INTERNAL_ERROR(error) "codegenAcc" $ "unexpected fusible material: " ++ prim

--codegenFun1=error"codegenFun1"
codegenFun2=error"codegenFun2"

  --     Alet{}                    -> unexpectedError
  --     Avar{}                    -> unexpectedError
  --     Apply{}                   -> unexpectedError
  --     Acond{}                   -> unexpectedError
  --     Awhile{}                  -> unexpectedError
  --     Atuple{}                  -> unexpectedError
  --     Aprj{}                    -> unexpectedError
  --     Use{}                     -> unexpectedError
  --     Unit{}                    -> unexpectedError
  --     Aforeign{}                -> unexpectedError
  --     Reshape{}                 -> unexpectedError

  --     Replicate{}               -> fusionError
  --     Slice{}                   -> fusionError
  --     ZipWith{}                 -> fusionError

  -- where
  --   codegen :: CUDA [CUTranslSkel aenv a] -> [CUTranslSkel aenv a]
  --   codegen cuda =
  --     let (skeletons, st)                = runCUDA cuda
  --         addTo (CUTranslSkel name code) =
  --           CUTranslSkel name (Set.foldr (\h c -> [cedecl| $esc:("#include \"" ++ h ++ "\"") |] : c) code (headers st))
  --     in
  --     map addTo skeletons

  --   id :: Elt a => DelayedFun aenv (a -> a)
  --   id = Lam (Body (Var ZeroIdx))

  --   -- code generation for delayed arrays
  --   travD :: (Shape sh, Elt e) => DelayedOpenAcc aenv (Array sh e) -> CUDA (CUDelayedAcc aenv sh e)
  --   travD Manifest{}  = $internalError "codegenAcc" "expected delayed array"
  --   travD Delayed{..} = CUDelayed <$> travE extentD
  --                                 <*> travF1 indexD
  --                                 <*> travF1 linearIndexD

  --   -- scalar code generation
  --   travF1 :: DelayedFun aenv (a -> b) -> CUDA (CUFun1 aenv (a -> b))
  --   travF1 = codegenFun1 dev aenv

  --   travF2 :: DelayedFun aenv (a -> b -> c) -> CUDA (CUFun2 aenv (a -> b -> c))
  --   travF2 = codegenFun2 dev aenv

  --   travE :: DelayedExp aenv t -> CUDA (CUExp aenv t)
  --   travE = codegenExp dev aenv

  --   travB :: forall sh e. Elt e
  --         => DelayedOpenAcc aenv (Array sh e) -> Boundary (EltRepr e) -> CUDA (Boundary (CUExp aenv e))
  --   travB _ Clamp        = return Clamp
  --   travB _ Mirror       = return Mirror
  --   travB _ Wrap         = return Wrap
  --   travB _ (Constant c) = return . Constant $ CUExp ([], codegenConst (Sugar.eltType (undefined::e)) c)

  --   -- caffeine and misery
  --   prim :: String
  --   prim                = showPreAccOp pacc
  --   unexpectedError     = $internalError "codegenAcc" $ "unexpected array primitive: " ++ prim
  --   fusionError         = $internalError "codegenAcc" $ "unexpected fusible material: " ++ prim

{- RNTODO

-- Scalar function abstraction
-- ---------------------------

-- Generate code for scalar function abstractions.
--
-- This is quite awkward: we have an outer monad to generate fresh variable
-- names, but since we know that even if the function in applied many times (for
-- example, collective operations such as 'fold' and 'scan'), the variables will
-- not shadow each other. Thus, we don't need fresh names at _every_ invocation
-- site, so we hack this a bit to return a pure closure.
--
-- Note that the implementation of def-use analysis used for dead code
-- elimination requires that we always generate code for closed functions.
-- Additionally, we require two passes over the function: once when performing
-- the analysis, and a second time when instantiating the function in the
-- skeleton.
--
codegenFun1
    :: forall aenv a b. DeviceProperties
    -> Gamma aenv
    -> DelayedFun aenv (a -> b)
    -> CUDA (CUFun1 aenv (a -> b))
codegenFun1 dev aenv fun
  | Lam (Body f) <- fun
  = let
        go :: Rvalue x => [x] -> Gen ([C.BlockItem], [C.Exp])
        go x = do
          code  <- mapM use =<< codegenOpenExp dev aenv f (Empty `Push` map rvalue x)
          env'  <- getEnv
          return (env', code)

        -- Initial code generation proceeds with dummy variable names. The real
        -- names are substituted later when we instantiate the skeleton.
        (_,u,_) = locals "undefined_x" (undefined :: a)
    in do
      n                 <- get
      ExpST _ used      <- execCGM (go u)
      return $ CUFun1 (mark used u)
             $ \xs -> evalState (evalCGM (go xs)) n
  --
  | otherwise
  = $internalError "codegenFun1" "expected unary function"


codegenFun2
    :: forall aenv a b c. DeviceProperties
    -> Gamma aenv
    -> DelayedFun aenv (a -> b -> c)
    -> CUDA (CUFun2 aenv (a -> b -> c))
codegenFun2 dev aenv fun
  | Lam (Lam (Body f)) <- fun
  = let
        go :: (Rvalue x, Rvalue y) => [x] -> [y] -> Gen ([C.BlockItem], [C.Exp])
        go x y = do
          code  <- mapM use =<< codegenOpenExp dev aenv f (Empty `Push` map rvalue x `Push` map rvalue y)
          env'  <- getEnv
          return (env', code)

        (_,u,_)  = locals "undefined_x" (undefined :: a)
        (_,v,_)  = locals "undefined_y" (undefined :: b)
    in do
      n                 <- get
      ExpST _ used      <- execCGM (go u v)
      return $ CUFun2 (mark used u) (mark used v)
             $ \xs ys -> evalState (evalCGM (go xs ys)) n
  --
  | otherwise
  = $internalError "codegenFun2" "expected binary function"


-- It is important to filter output terms of a function that will not be used.
-- Consider this pattern from the map kernel:
--
--   items:(x      .=. get ix)
--   items:(set ix .=. f x)
--
-- If this is applied to the following expression where we extract the first
-- component of a 4-tuple:
--
--   map (\t -> let (x,_,_,_) = unlift t in x) vec4
--
-- Then the first line 'get ix' still reads all four components of the input
-- vector, even though only one is used. Conversely, if we directly apply the
-- data fetch to f, then the redundant reads are eliminated, but this is simply
-- inlining the read into the function body, so if the argument is used multiple
-- times so to is the data read multiple times.
--
-- The procedure for determining which variables are used is to record each
-- singleton expression produced throughout code generation to a set. It doesn't
-- matter if the expression is a variable (which we are interested in) or
-- something else. Once generation completes, we can test which of the input
-- variables also appear in the output set. Later, we integrate this information
-- when assigning to l-values: if the variable is not in the set, simply elide
-- that statement.
--
-- In the above map example, this means that the usage data is taken from 'f',
-- but applies to which results of 'get ix' are committed to memory.
--
-}
mark :: HashSet C.Exp -> [C.Exp] -> ([a] -> [(Bool,a)])
mark used xs
  = let flags = map (\x -> x `Set.member` used) xs
    in  zipWith (,) flags


visit :: [C.Exp] -> Gen [C.Exp]
visit exp
  | [x] <- exp  = use x >> return exp
  | otherwise   =          return exp


{-  RNTODO

-- Delayed arrays
-- --------------

-- The fusion transform places producer functions adjacent consumers, so that
-- these array functions can be converted into scalar expressions and embedded
-- directly into the consumer.
--
codegenDelayedAcc
    :: (Shape sh, Elt e)
    => DeviceProperties
    -> OpenAcc aenv (Array sh e)
    -> CUDA (CUDelayedAcc aenv sh e)
codegenDelayedAcc dev acc
  | Just delayed <- Trafo.embedOpenAcc acc
  = CUDelayed <$> codegenExp  dev (Trafo.extent delayed)
              <*> codegenFun1 dev (Trafo.index  delayed)
              <*> codegenFun1 dev (Trafo.linearIndex delayed)

  | otherwise
  = INTERNAL_ERROR(error) "codegenDelayedAcc" "expected delayable array"


-- Scalar expressions
-- ------------------

-- Generation of scalar expressions
--
codegenExp :: DeviceProperties -> Gamma aenv -> DelayedExp aenv t -> CUDA (CUExp aenv t)
codegenExp dev aenv exp =
  evalCGM $ do
    code        <- codegenOpenExp dev aenv exp Empty
    env         <- getEnv
    return      $! CUExp (env,code)


-}

-- The core of the code generator, building lists of untyped C expression
-- fragments. This is tricky to get right!
--

codegenOpenExp :: DeviceProperties -> S.Exp -> ValEnv -> Gen [C.Exp]
codegenOpenExp dev ex env = cvtE env ex
  where

    -- Generate code for a scalar expression in depth-first order. We run under
    -- a monad that generates fresh names and keeps track of let bindings.
    --
--    forall env aenv t. OpenExp env aenv t
    cvtE :: ValEnv -> S.Exp -> Gen [C.Exp]
    cvtE env exp  = visit =<<
    -- cvtE :: forall env t. DelayedOpenExp env aenv t -> Val env -> Gen [C.Exp]
    -- cvtE exp env = visit =<<
      case exp of
        ELet bnd body -> elet bnd body env
        EVr  v        -> return $ snd $ env # v
        EConst c      -> return $ codegenConst c
        EPrimApp ty p args -> do lls <- mapM (cvtE env) args
                                 return [codegenPrim p (concat lls)]
{- RNTODO
        PrimConst c             -> return $ [codegenPrimConst c]
        Tuple t                 -> cvtT t env
        Prj i t                 -> prjT i t exp env
        Cond p t e              -> cond p t e env
        While p f x             -> while p f x env

        -- Shapes and indices
        IndexNil                -> return []
        IndexAny                -> return []
        IndexCons sh sz         -> (++) <$> cvtE sh env <*> cvtE sz env
        IndexHead ix            -> return . cindexHead <$> cvtE ix env
        IndexTail ix            ->          cindexTail <$> cvtE ix env
        IndexSlice ix slix sh   -> indexSlice ix slix sh env
        IndexFull  ix slix sl   -> indexFull  ix slix sl env
        ToIndex sh ix           -> toIndex   sh ix env
        FromIndex sh ix         -> fromIndex sh ix env

        -- Arrays and indexing
        Index acc ix            -> index acc ix env
        LinearIndex acc ix      -> linearIndex acc ix env
        Shape acc               -> shape acc env
        ShapeSize sh            -> shapeSize sh env
        Intersect sh1 sh2       -> intersect sh1 sh2 env

        --Foreign function
        Foreign ff _ e          -> foreignE ff e env

    -- The heavy lifting
    -- -----------------
-}
    -- Scalar let expressions evaluate their terms and generate new (const)
    -- variable bindings to store these results. These are carried the monad
    -- state, which also gives us a supply of fresh names. The new names are
    -- added to the environment for use in the body via the standard Var term.
    --
    -- Note that we have not restricted the scope of these new bindings: once
    -- something is added, it remains in scope forever. We are relying on
    -- liveness analysis of the CUDA compiler to manage register pressure.
    --

    elet :: (S.Var,S.Type,S.Exp) -> S.Exp -> ValEnv -> Gen [C.Exp]
    elet (vr,ty,rhs) body env = do
      rhs'      <- cvtE env rhs 
      x         <- pushEnv ty rhs rhs'
      body'     <- cvtE (M.insert vr (ty,rhs') env) body 
      return body'
{-
    -- Convert an OpenExp into a sequence of C expressions. We retain snoc-list
    -- ordering, so the element at tuple index zero is at the end of the list.
    -- Note that nested tuple structures are flattened.
    elet :: DelayedOpenExp env aenv bnd -> DelayedOpenExp (env, bnd) aenv body -> Val env -> Gen [C.Exp]
    elet bnd body env = do
      bnd'      <- cvtE bnd env >>= pushEnv bnd
      body'     <- cvtE body (env `Push` bnd')
      return body'

    -- Convert an open expression into a sequence of C expressions. We retain
    -- snoc-list ordering, so the element at tuple index zero is at the end of
    -- the list. Note that nested tuple structures are flattened.
    --
    cvtT :: Tuple (DelayedOpenExp env aenv) t -> Val env -> Gen [C.Exp]
    cvtT tup env =
      case tup of
        NilTup          -> return []
        SnocTup t e     -> (++) <$> cvtT t env <*> cvtE e env

    -- Project out a tuple index. Since the nested tuple structure is flattened,
    -- this actually corresponds to slicing out a subset of the list of C
    -- expressions, rather than picking out a single element.
    --
    prjT :: forall env t e. TupleIdx (TupleRepr t) e
         -> DelayedOpenExp env aenv t
         -> DelayedOpenExp env aenv e
         -> Val env
         -> Gen [C.Exp]
    prjT ix t e env =
      let subset = reverse
                 . take (length      $ expType e)
                 . drop (prjToInt ix $ Sugar.preExpType Sugar.delayedAccType t)
                 . reverse
      in
      subset <$> cvtE t env

    -- Convert a tuple index into the corresponding integer. Since the internal
    -- representation is flat, be sure to walk over all sub components when indexing
    -- past nested tuples.
    --
    prjToInt :: TupleIdx t e -> TupleType a -> Int
    prjToInt ZeroTupIdx     _                 = 0
    prjToInt (SuccTupIdx i) (b `PairTuple` a) = sizeTupleType a + prjToInt i b
    prjToInt _              _                 = $internalError "prjToInt" "inconsistent valuation"

    sizeTupleType :: TupleType a -> Int
    sizeTupleType UnitTuple       = 0
    sizeTupleType (SingleTuple _) = 1
    sizeTupleType (PairTuple a b) = sizeTupleType a + sizeTupleType b

    -- Scalar conditionals. To keep the return type as an expression list we use
    -- the ternery C condition operator (?:). For tuples this is not
    -- particularly good, so the least we can do is make sure the predicate
    -- result is evaluated only once and bound to a local variable.
    --
    cond :: DelayedOpenExp env aenv Bool
         -> DelayedOpenExp env aenv t
         -> DelayedOpenExp env aenv t
         -> Val env -> Gen [C.Exp]
    cond p t e env = do
      p'        <- cvtE p env
      ok        <- single "Cond" <$> pushEnv p p'
      zipWith (\a b -> [cexp| $exp:ok ? $exp:a : $exp:b |]) <$> cvtE t env <*> cvtE e env

    -- Value recursion
    --
    while :: forall env a. Elt a
          => DelayedOpenFun env aenv (a -> Bool)        -- continue while predicate returns true
          -> DelayedOpenFun env aenv (a -> a)           -- loop body
          -> DelayedOpenExp env aenv a                  -- initial value
          -> Val env
          -> Gen [C.Exp]
    while test step x env
      | Lam (Body p)    <- test
      , Lam (Body f)    <- step
      = do
           -- Generate code for the initial value, then bind this to a fresh
           -- (mutable) variable. We need build the declarations ourselves, and
           -- twiddle the names a bit to avoid clobbering.
           --
           x'           <- cvtE x env
           var_acc      <- lift fresh
           var_ok       <- lift fresh
           var_tmp      <- lift fresh

           let (tn_acc, acc, _)         = locals ('l':var_acc) (undefined :: a)
               (tn_ok,  ok,  _)         = locals ('l':var_ok)  (undefined :: Bool)
               (_    ,  tmp, decltemp)  = locals ('l':var_tmp) (undefined :: a)

           -- Generate code for the predicate and body expressions, with the new
           -- names baked in directly. We can't use 'codegenFun1', because
           -- def-use analysis won't be able to see into this new function.
           --
           -- However, we do need to generate the function with a clean set of
           -- local bindings, and extract and new declarations afterwards.
           --
           let cvtF :: forall env t. Elt t => DelayedOpenExp env aenv t -> Val env -> Gen ([C.BlockItem], [C.Exp])
               cvtF e env = do
                 old  <- state (\s -> ( localBindings s, s { localBindings = []  } ))
                 e'   <- cvtE e env
                 env' <- state (\s -> ( localBindings s, s { localBindings = old } ))
                 return (reverse env', e')

           p'   <- cvtF p (env `Push` acc)
           f'   <- cvtF f (env `Push` acc)

           -- Piece it all together. Note that declarations are added to the
           -- localBindings in reverse order. Also, we have to be careful not
           -- to assign the results of f' direction into acc. Why? Some of the
           -- variables in acc are referenced in f'. We risk overwriting values
           -- that are still needed to computer f'.
           let loop = [citem| while ( $exp:(single "while" ok) ) {
                                  $decls:decltemp
                                  $items:(tmp .=. f')
                                  $items:(acc .=. tmp)
                                  $items:(ok  .=. p')
                              } |]
                    : (ok .=. p')
                   ++ map     (\(t,n)   -> [citem| $ty:t $id:n ; |])      tn_ok
                   ++ zipWith (\(t,n) v -> [citem| $ty:t $id:n = $v ; |]) tn_acc x'

           modify (\s -> s { localBindings = loop ++ localBindings s })
           return acc

      | otherwise
      = error "Would you say we'd be venturing into a zone of danger?"

    -- Restrict indices based on a slice specification. In the SliceAll case we
    -- elide the presence of IndexAny from the head of slx, as this is not
    -- represented in by any C term (Any ~ [])
    --
    indexSlice :: SliceIndex (EltRepr slix) sl co (EltRepr sh)
               -> DelayedOpenExp env aenv slix
               -> DelayedOpenExp env aenv sh
               -> Val env
               -> Gen [C.Exp]
    indexSlice sliceIndex slix sh env =
      let restrict :: SliceIndex slix sl co sh -> [C.Exp] -> [C.Exp] -> [C.Exp]
          restrict SliceNil              _       _       = []
          restrict (SliceAll   sliceIdx) slx     (sz:sl) = sz : restrict sliceIdx slx sl
          restrict (SliceFixed sliceIdx) (_:slx) ( _:sl) =      restrict sliceIdx slx sl
          restrict _ _ _ = $internalError "IndexSlice" "unexpected shapes"
          --
          slice slix' sh' = reverse $ restrict sliceIndex (reverse slix') (reverse sh')
      in
      slice <$> cvtE slix env <*> cvtE sh env

    -- Extend indices based on a slice specification. In the SliceAll case we
    -- elide the presence of Any from the head of slx.
    --
    indexFull :: SliceIndex (EltRepr slix) (EltRepr sl) co sh
              -> DelayedOpenExp env aenv slix
              -> DelayedOpenExp env aenv sl
              -> Val env
              -> Gen [C.Exp]
    indexFull sliceIndex slix sl env =
      let extend :: SliceIndex slix sl co sh -> [C.Exp] -> [C.Exp] -> [C.Exp]
          extend SliceNil              _        _       = []
          extend (SliceAll   sliceIdx) slx      (sz:sh) = sz : extend sliceIdx slx sh
          extend (SliceFixed sliceIdx) (sz:slx) sh      = sz : extend sliceIdx slx sh
          extend _ _ _ = $internalError "IndexFull" "unexpected shapes"
          --
          replicate slix' sl' = reverse $ extend sliceIndex (reverse slix') (reverse sl')
      in
      replicate <$> cvtE slix env <*> cvtE sl env

    -- Convert between linear and multidimensional indices
    --
    toIndex :: DelayedOpenExp env aenv sh -> DelayedOpenExp env aenv sh -> Val env -> Gen [C.Exp]
    toIndex sh ix env = do
      sh'   <- mapM use =<< cvtE sh env
      ix'   <- mapM use =<< cvtE ix env
      return [ ctoIndex sh' ix' ]

    fromIndex :: DelayedOpenExp env aenv sh -> DelayedOpenExp env aenv Int -> Val env -> Gen [C.Exp]
    fromIndex sh ix env = do
      sh'   <- mapM use =<< cvtE sh env
      ix'   <- cvtE ix env
      tmp   <- lift fresh
      let (ls, sz) = cfromIndex sh' (single "fromIndex" ix') tmp
      modify (\st -> st { localBindings = reverse ls ++ localBindings st })
      return sz

    -- Project out a single scalar element from an array. The array expression
    -- does not contain any free scalar variables (strictly flat data
    -- parallelism) and has been floated out to be replaced by an array index.
    --
    -- As we have a non-parametric array representation, be sure to bind the
    -- linear array index as it will be used to access each component of a
    -- tuple.
    --
    -- Note that after evaluating the linear array index we bind this to a fresh
    -- variable of type 'int', so there is an implicit conversion from
    -- Int -> Int32.
    --
    index :: (Shape sh, Elt e)
          => DelayedOpenAcc aenv (Array sh e)
          -> DelayedOpenExp env aenv sh
          -> Val env
          -> Gen [C.Exp]
    index acc ix env
      | Manifest (Avar idx) <- acc
      = let (sh, arr)   = namesOfAvar aenv idx
            ty          = accType acc
        in do
        ix'     <- mapM use =<< cvtE ix env
        i       <- bind cint $ ctoIndex (cshape (expDim ix) sh) ix'
        return   $ zipWith (\t a -> indexArray dev t (cvar a) i) ty arr
      --
      | otherwise
      = $internalError "Index" "expected array variable"


    linearIndex :: (Shape sh, Elt e)
                => DelayedOpenAcc aenv (Array sh e)
                -> DelayedOpenExp env aenv Int
                -> Val env
                -> Gen [C.Exp]
    linearIndex acc ix env
      | Manifest (Avar idx) <- acc
      = let (_, arr)    = namesOfAvar aenv idx
            ty          = accType acc
        in do
        ix'     <- mapM use =<< cvtE ix env
        i       <- bind [cty| int |] $ single "LinearIndex" ix'
        return   $ zipWith (\t a -> indexArray dev t (cvar a) i) ty arr
      --
      | otherwise
      = $internalError "LinearIndex" "expected array variable"

    -- Array shapes created in this method refer to the shape of free array
    -- variables. As such, they are always passed as arguments to the kernel,
    -- not computed as part of the scalar expression. These shapes are
    -- transferred to the kernel as a structure, and so the individual fields
    -- need to be "unpacked", to work with our handling of tuple structures.
    --
    shape :: (Shape sh, Elt e) => DelayedOpenAcc aenv (Array sh e) -> Val env -> Gen [C.Exp]
    shape acc _env
      | Manifest (Avar idx) <- acc
      = return $ cshape (delayedDim acc) (fst (namesOfAvar aenv idx))

      | otherwise
      = $internalError "Shape" "expected array variable"

    -- The size of a shape, as the product of the extent in each dimension. The
    -- definition is inlined, but we could also call the C function helpers.
    --
    shapeSize :: DelayedOpenExp env aenv sh -> Val env -> Gen [C.Exp]
    shapeSize sh env = return . csize <$> cvtE sh env

    -- Intersection of two shapes, taken as the minimum in each dimension.
    --
    intersect :: forall env sh. Elt sh
              => DelayedOpenExp env aenv sh
              -> DelayedOpenExp env aenv sh
              -> Val env -> Gen [C.Exp]
    intersect sh1 sh2 env =
      zipWith (\a b -> ccall "min" [a,b]) <$> cvtE sh1 env <*> cvtE sh2 env

    -- Foreign scalar functions. We need to extract any header files that might
    -- be required so they can be added to the top level definitions.
    --
    -- Additionally, we insert an explicit type cast from the foreign function
    -- result back into Accelerate types (c.f. Int vs int).
    --
    foreignE :: forall f a b env. (Sugar.Foreign f, Elt a, Elt b)
             => f a b
             -> DelayedOpenExp env aenv a
             -> Val env
             -> Gen [C.Exp]
    foreignE ff x env = case canExecuteExp ff of
      Nothing      -> $internalError "codegenOpenExp" "Non-CUDA foreign expression encountered"
      Just (hs, f) -> do
        lift $ modify (\st -> st { headers = foldl (flip Set.insert) (headers st) hs })
        args    <- cvtE x env
        mapM_ use args
        return  $  [ccall f (ccastTup (Sugar.eltType (undefined::a)) args)]

    -- Some terms demand we extract only singly typed expressions
    --
    single :: String -> [C.Exp] -> C.Exp
    single _   [x] = x
    single loc _   = $internalError loc "expected single expression"

-}

-- Scalar Primitives
-- -----------------

-- codegenPrimConst :: PrimConst a -> C.Exp
-- codegenPrimConst (PrimMinBound ty) = codegenMinBound ty
-- codegenPrimConst (PrimMaxBound ty) = codegenMaxBound ty
-- codegenPrimConst (PrimPi       ty) = codegenPi ty

codegenPrim :: S.Prim -> [C.Exp] -> C.Exp
codegenPrim (NP Add                ) [a,b] = [cexp|$exp:a + $exp:b|]
codegenPrim (NP Sub                ) [a,b] = [cexp|$exp:a - $exp:b|]
{- RNTODO
codegenPrim (PrimMul              _) [a,b] = [cexp|$exp:a * $exp:b|]
codegenPrim (PrimNeg              _) [a]   = [cexp| - $exp:a|]
codegenPrim (PrimAbs             ty) [a]   = codegenAbs ty a
codegenPrim (PrimSig             ty) [a]   = codegenSig ty a
codegenPrim (PrimQuot             _) [a,b] = [cexp|$exp:a / $exp:b|]
codegenPrim (PrimRem              _) [a,b] = [cexp|$exp:a % $exp:b|]
codegenPrim (PrimIDiv             _) [a,b] = ccall "idiv" [a,b]
codegenPrim (PrimMod              _) [a,b] = ccall "mod"  [a,b]
codegenPrim (PrimBAnd             _) [a,b] = [cexp|$exp:a & $exp:b|]
codegenPrim (PrimBOr              _) [a,b] = [cexp|$exp:a | $exp:b|]
codegenPrim (PrimBXor             _) [a,b] = [cexp|$exp:a ^ $exp:b|]
codegenPrim (PrimBNot             _) [a]   = [cexp|~ $exp:a|]
codegenPrim (PrimBShiftL          _) [a,b] = [cexp|$exp:a << $exp:b|]
codegenPrim (PrimBShiftR          _) [a,b] = [cexp|$exp:a >> $exp:b|]
codegenPrim (PrimBRotateL         _) [a,b] = ccall "rotateL" [a,b]
codegenPrim (PrimBRotateR         _) [a,b] = ccall "rotateR" [a,b]
codegenPrim (PrimFDiv             _) [a,b] = [cexp|$exp:a / $exp:b|]
codegenPrim (PrimRecip           ty) [a]   = codegenRecip ty a
codegenPrim (PrimSin             ty) [a]   = ccall (FloatingNumType ty `postfix` "sin")   [a]
codegenPrim (PrimCos             ty) [a]   = ccall (FloatingNumType ty `postfix` "cos")   [a]
codegenPrim (PrimTan             ty) [a]   = ccall (FloatingNumType ty `postfix` "tan")   [a]
codegenPrim (PrimAsin            ty) [a]   = ccall (FloatingNumType ty `postfix` "asin")  [a]
codegenPrim (PrimAcos            ty) [a]   = ccall (FloatingNumType ty `postfix` "acos")  [a]
codegenPrim (PrimAtan            ty) [a]   = ccall (FloatingNumType ty `postfix` "atan")  [a]
codegenPrim (PrimAsinh           ty) [a]   = ccall (FloatingNumType ty `postfix` "asinh") [a]
codegenPrim (PrimAcosh           ty) [a]   = ccall (FloatingNumType ty `postfix` "acosh") [a]
codegenPrim (PrimAtanh           ty) [a]   = ccall (FloatingNumType ty `postfix` "atanh") [a]
codegenPrim (PrimExpFloating     ty) [a]   = ccall (FloatingNumType ty `postfix` "exp")   [a]
codegenPrim (PrimSqrt            ty) [a]   = ccall (FloatingNumType ty `postfix` "sqrt")  [a]
codegenPrim (PrimLog             ty) [a]   = ccall (FloatingNumType ty `postfix` "log")   [a]
codegenPrim (PrimFPow            ty) [a,b] = ccall (FloatingNumType ty `postfix` "pow")   [a,b]
codegenPrim (PrimLogBase         ty) [a,b] = codegenLogBase ty a b
codegenPrim (PrimTruncate     ta tb) [a]   = codegenTruncate ta tb a
codegenPrim (PrimRound        ta tb) [a]   = codegenRound ta tb a
codegenPrim (PrimFloor        ta tb) [a]   = codegenFloor ta tb a
codegenPrim (PrimCeiling      ta tb) [a]   = codegenCeiling ta tb a
codegenPrim (PrimAtan2           ty) [a,b] = ccall (FloatingNumType ty `postfix` "atan2") [a,b]
codegenPrim (PrimLt               _) [a,b] = [cexp|$exp:a < $exp:b|]
codegenPrim (PrimGt               _) [a,b] = [cexp|$exp:a > $exp:b|]
codegenPrim (PrimLtEq             _) [a,b] = [cexp|$exp:a <= $exp:b|]
codegenPrim (PrimGtEq             _) [a,b] = [cexp|$exp:a >= $exp:b|]
codegenPrim (PrimEq               _) [a,b] = [cexp|$exp:a == $exp:b|]
codegenPrim (PrimNEq              _) [a,b] = [cexp|$exp:a != $exp:b|]
codegenPrim (PrimMax             ty) [a,b] = codegenMax ty a b
codegenPrim (PrimMin             ty) [a,b] = codegenMin ty a b
codegenPrim PrimLAnd                 [a,b] = [cexp|$exp:a && $exp:b|]
codegenPrim PrimLOr                  [a,b] = [cexp|$exp:a || $exp:b|]
codegenPrim PrimLNot                 [a]   = [cexp| ! $exp:a|]
codegenPrim PrimOrd                  [a]   = codegenOrd a
codegenPrim PrimChr                  [a]   = codegenChr a
codegenPrim PrimBoolToInt            [a]   = codegenBoolToInt a
codegenPrim (PrimFromIntegral ta tb) [a]   = codegenFromIntegral ta tb a
-}
-- If the argument lists are not the correct length
codegenPrim _ _ =
  $internalError "codegenPrim" "inconsistent valuation"


-- Scalar and tuple constants:
codegenConst :: S.Const -> [C.Exp]
codegenConst cnst =
  case cnst of
    B b   -> [cbool b]
    C x   -> [[cexp|$char:x|]]
    CC x  -> [[cexp|$char:(chr (fromIntegral x))|]]
    CUC x -> [[cexp|$char:(chr (fromIntegral x))|]]
    CSC x -> [[cexp|$char:(chr (fromIntegral x))|]]

--    x | S.isIntType x -> [cexp| ( $ty:(codegenIntegralType ty) ) $exp:(cintegral x) |]

{- RNTODO:


codegenIntegralScalar :: IntegralType a -> a -> C.Exp
codegenIntegralScalar ty x | IntegralDict <- integralDict ty = [cexp| ( $ty:(codegenIntegralType ty) ) $exp:(cintegral x) |]

codegenFloatingScalar :: FloatingType a -> a -> C.Exp
codegenFloatingScalar (TypeFloat   _) x = C.Const (C.FloatConst (shows x "f") (toRational x) noLoc) noLoc
codegenFloatingScalar (TypeCFloat  _) x = C.Const (C.FloatConst (shows x "f") (toRational x) noLoc) noLoc
codegenFloatingScalar (TypeDouble  _) x = C.Const (C.DoubleConst (show x) (toRational x) noLoc) noLoc
codegenFloatingScalar (TypeCDouble _) x = C.Const (C.DoubleConst (show x) (toRational x) noLoc) noLoc


-- Constant methods of floating
--
codegenPi :: FloatingType a -> C.Exp
codegenPi ty | FloatingDict <- floatingDict ty = codegenFloatingScalar ty pi


-- Constant methods of bounded
--
codegenMinBound :: BoundedType a -> C.Exp
codegenMinBound (IntegralBoundedType ty) | IntegralDict <- integralDict ty = codegenIntegralScalar ty minBound
codegenMinBound (NonNumBoundedType   ty) | NonNumDict   <- nonNumDict   ty = codegenNonNumScalar   ty minBound


codegenMaxBound :: BoundedType a -> C.Exp
codegenMaxBound (IntegralBoundedType ty) | IntegralDict <- integralDict ty = codegenIntegralScalar ty maxBound
codegenMaxBound (NonNumBoundedType   ty) | NonNumDict   <- nonNumDict   ty = codegenNonNumScalar   ty maxBound


-- Methods from Num, Floating, Fractional and RealFrac
--
codegenAbs :: NumType a -> C.Exp -> C.Exp
codegenAbs (FloatingNumType ty) x = ccall (FloatingNumType ty `postfix` "fabs") [x]
codegenAbs (IntegralNumType ty) x =
  case ty of
    TypeWord _          -> x
    TypeWord8 _         -> x
    TypeWord16 _        -> x
    TypeWord32 _        -> x
    TypeWord64 _        -> x
    TypeCUShort _       -> x
    TypeCUInt _         -> x
    TypeCULong _        -> x
    TypeCULLong _       -> x
    _                   -> ccall "abs" [x]

codegenSig :: NumType a -> C.Exp -> C.Exp
codegenSig (IntegralNumType ty) = codegenIntegralSig ty
codegenSig (FloatingNumType ty) = codegenFloatingSig ty

codegenIntegralSig :: IntegralType a -> C.Exp -> C.Exp
codegenIntegralSig ty x = [cexp|$exp:x == $exp:zero ? $exp:zero : $exp:(ccall "copysign" [one,x]) |]
  where
    zero | IntegralDict <- integralDict ty = codegenIntegralScalar ty 0
    one  | IntegralDict <- integralDict ty = codegenIntegralScalar ty 1

codegenFloatingSig :: FloatingType a -> C.Exp -> C.Exp
codegenFloatingSig ty x =
  [cexp|$exp:x == $exp:zero
            ? $exp:zero
            : $exp:(ccall (FloatingNumType ty `postfix` "copysign") [one,x]) |]
  where
    zero | FloatingDict <- floatingDict ty = codegenFloatingScalar ty 0
    one  | FloatingDict <- floatingDict ty = codegenFloatingScalar ty 1


codegenRecip :: FloatingType a -> C.Exp -> C.Exp
codegenRecip ty x | FloatingDict <- floatingDict ty = [cexp|$exp:(codegenFloatingScalar ty 1) / $exp:x|]


codegenLogBase :: FloatingType a -> C.Exp -> C.Exp -> C.Exp
codegenLogBase ty x y = let a = ccall (FloatingNumType ty `postfix` "log") [x]
                            b = ccall (FloatingNumType ty `postfix` "log") [y]
                        in
                        [cexp|$exp:b / $exp:a|]
-}

codegenMin :: S.Type -> C.Exp -> C.Exp -> C.Exp
codegenMin ty a b | S.isIntType ty   = ccall (ty `postfix` "min")  [a,b]
                  | S.isFloatType ty = ccall (ty `postfix` "fmin") [a,b]
                  | otherwise = let ty = S.TInt32 
                                in  codegenMin ty (ccast ty a) (ccast ty b)

codegenMax :: S.Type -> C.Exp -> C.Exp -> C.Exp
codegenMax ty a b | S.isIntType ty   = ccall (ty `postfix` "max")  [a,b]
                  | S.isFloatType ty = ccall (ty `postfix` "fmax") [a,b]
                  | otherwise = let ty = S.TInt32
                                in  codegenMax ty (ccast ty a) (ccast ty b)

-- Type coercions
--
codegenOrd :: C.Exp -> C.Exp
codegenOrd = ccast S.TInt

codegenChr :: C.Exp -> C.Exp
codegenChr = ccast S.TChar

codegenBoolToInt :: C.Exp -> C.Exp
codegenBoolToInt = ccast S.TInt

codegenFromIntegral :: S.Type -> S.Type -> C.Exp -> C.Exp
codegenFromIntegral _ ty | S.isNumType ty = ccast ty
                         | otherwise = error$"codegenFromIntegral: not a numtype: "++show ty

-- RNTODO:
-- codegenTruncate :: FloatingType a -> IntegralType b -> C.Exp -> C.Exp
-- codegenTruncate ta tb x
--   = ccast (NumScalarType (IntegralNumType tb))
--   $ ccall (FloatingNumType ta `postfix` "trunc") [x]

-- codegenRound :: FloatingType a -> IntegralType b -> C.Exp -> C.Exp
-- codegenRound ta tb x
--   = ccast (NumScalarType (IntegralNumType tb))
--   $ ccall (FloatingNumType ta `postfix` "round") [x]

-- codegenFloor :: FloatingType a -> IntegralType b -> C.Exp -> C.Exp
-- codegenFloor ta tb x
--   = ccast (NumScalarType (IntegralNumType tb))
--   $ ccall (FloatingNumType ta `postfix` "floor") [x]

-- codegenCeiling :: FloatingType a -> IntegralType b -> C.Exp -> C.Exp
-- codegenCeiling ta tb x
--   = ccast (NumScalarType (IntegralNumType tb))
--   $ ccall (FloatingNumType ta `postfix` "ceil") [x]


-- Auxiliary Functions
-- -------------------

-- Scalar types only, satisfies `isNumType`
ccast :: S.Type -> C.Exp -> C.Exp
ccast ty x = [cexp|($ty:(codegenType ty)) $exp:x|]

postfix :: S.Type -> String -> String
postfix S.TFloat  x = x ++ "f"
postfix S.TCFloat x = x ++ "f"
postfix _         x = x


-- Debugging
-- ---------
{-
showPreAccOp :: PreOpenAcc acc aenv a -> String
showPreAccOp pacc =
  case pacc of
    Alet _ _            -> "Alet"
    Avar _              -> "Avar"
    Atuple _            -> "Atuple"
    Aprj _ _            -> "Aprj"
    Apply _ _           -> "Apply"
    Acond _ _ _         -> "Acond"
    Use _               -> "Use"
    Unit _              -> "Unit"
    Reshape _ _         -> "Reshape"
    Generate _ _        -> "Generate"
    Transform _ _ _ _   -> "Transform"
    Replicate _ _ _     -> "Replicate"
    Slice _ _ _         -> "Slice"
    Map _ _             -> "Map"
    ZipWith _ _ _       -> "ZipWith"
    Fold _ _ _          -> "Fold"
    Fold1 _ _           -> "Fold1"
    FoldSeg _ _ _ _     -> "FoldSeg"
    Fold1Seg _ _ _      -> "Fold1Seg"
    Scanl _ _ _         -> "Scanl"
    Scanl1 _ _          -> "Scanl1"
    Scanl' _ _ _        -> "Scanl'"
    Scanr _ _ _         -> "Scanr"
    Scanr1 _ _          -> "Scanr1"
    Scanr' _ _ _        -> "Scanr'"
    Permute _ _ _ _     -> "Permute"
    Backpermute _ _ _   -> "Backpermute"
    Stencil _ _ _       -> "Stencil"
    Stencil2 _ _ _ _ _  -> "Stencil2"
-}


-- | For debugging purposes we should really never use Data.Map.!  This is an
-- alternative with a better error message.
(#) :: (Ord a1, Show a, Show a1) => M.Map a1 a -> a1 -> a
mp # k = case M.lookup k mp of
          Nothing -> error$"Map.lookup: key "++show k++" is not in map:\n  "++show mp
          Just x  -> x

-- ccastTup :: TupleType e -> [C.Exp] -> [C.Exp]
-- ccastTup ty = fst . travTup ty
--   where
--     travTup :: TupleType e -> [C.Exp] -> ([C.Exp],[C.Exp])
--     travTup UnitTuple         xs     = ([], xs)
--     travTup (SingleTuple ty') (x:xs) = ([ccast ty' x], xs)
--     travTup (PairTuple l r)   xs     = let
--                                          (ls, xs' ) = travTup l xs
--                                          (rs, xs'') = travTup r xs'
--                                        in (ls ++ rs, xs'')
--     travTup _ _                      = $internalError "ccastTup" "not enough expressions to match type"


-- postfix :: NumType a -> String -> String
-- postfix (FloatingNumType (TypeFloat  _)) x = x ++ "f"
-- postfix (FloatingNumType (TypeCFloat _)) x = x ++ "f"
-- postfix _                                x = x


