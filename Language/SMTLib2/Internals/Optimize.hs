module Language.SMTLib2.Internals.Optimize (optimizeBackend,optimizeExpr) where

import Language.SMTLib2.Internals
import Language.SMTLib2.Internals.Instances (bvSigned,bvUnsigned,bvRestrict,eqExpr)
import Language.SMTLib2.Internals.Operators
import Data.Proxy
import Data.Bits
import Data.Either (partitionEithers)
import Data.Typeable (cast)

optimizeBackend :: b -> OptimizeBackend b
optimizeBackend = OptB

data OptimizeBackend b = OptB b

instance SMTBackend b m => SMTBackend (OptimizeBackend b) m where
  smtHandle (OptB b) (SMTAssert expr grp cid)
    = let nexpr = case optimizeExpr expr of
            Just e -> e
            Nothing -> expr
      in case nexpr of
        Const True _ -> return ((),OptB b)
        _ -> do
          (res,nb) <- smtHandle b (SMTAssert nexpr grp cid)
          return (res,OptB nb)
  smtHandle (OptB b) (SMTDefineFun name prx ann body) = do
    let nbody = case optimizeExpr body of
                 Just e -> e
                 Nothing -> body
    (res,nb) <- smtHandle b (SMTDefineFun name prx ann nbody)
    return (res,OptB nb)
  smtHandle (OptB b) (SMTGetValue expr) = do
    let nexpr = case optimizeExpr expr of
                 Just e -> e
                 Nothing -> expr
    (res,nb) <- smtHandle b (SMTGetValue nexpr)
    return (res,OptB nb)
  smtHandle (OptB b) SMTGetProof = do
    (res,nb) <- smtHandle b SMTGetProof
    return (case optimizeExpr res of
             Just e -> e
             Nothing -> res,OptB nb)
  smtHandle (OptB b) (SMTSimplify expr) = do
    let nexpr = case optimizeExpr expr of
          Just e -> e
          Nothing -> expr
    (simp,nb) <- smtHandle b (SMTSimplify nexpr)
    return (case optimizeExpr simp of
             Nothing -> simp
             Just simp' -> simp',OptB nb)
  smtHandle (OptB b) (SMTGetInterpolant grps) = do
    (inter,nb) <- smtHandle b (SMTGetInterpolant grps)
    return (case optimizeExpr inter of
             Nothing -> inter
             Just e -> e,OptB nb)
  smtHandle (OptB b) req = do
    (res,nb) <- smtHandle b req
    return (res,OptB nb)
  smtGetNames (OptB b) = smtGetNames b
  smtNextName (OptB b) = smtNextName b

optimizeExpr :: SMTExpr t -> Maybe (SMTExpr t)
optimizeExpr (App fun x) = let (opt,x') = foldExprsId (\opt expr ann -> case optimizeExpr expr of
                                                          Nothing -> (opt,expr)
                                                          Just expr' -> (True,expr')
                                                      ) False x (extractArgAnnotation x)
                           in case optimizeCall fun x' of
                             Nothing -> if opt
                                        then Just $ App fun x'
                                        else Nothing
                             Just res -> Just res
optimizeExpr _ = Nothing

optimizeCall :: SMTFunction arg res -> arg -> Maybe (SMTExpr res)
optimizeCall SMTEq [] = Just (Const True ())
optimizeCall SMTEq [_] = Just (Const True ())
optimizeCall SMTEq [x,y] = case eqExpr x y of
  Nothing -> Nothing
  Just res -> Just (Const res ())
optimizeCall SMTNot (Const x _) = Just $ Const (not x) ()
optimizeCall (SMTLogic _) [x] = Just x
optimizeCall (SMTLogic And) xs = case removeConstsOf False xs of
  Just _ -> Just $ Const False ()
  Nothing -> case removeConstsOf True xs of
    Nothing -> case xs of
      [] -> Just $ Const True ()
      _ -> Nothing
    Just [] -> Just $ Const True ()
    Just [x] -> Just x
    Just xs' -> Just $ App (SMTLogic And) xs'
optimizeCall (SMTLogic Or) xs = case removeConstsOf True xs of
  Just _ -> Just $ Const True ()
  Nothing -> case removeConstsOf False xs of
    Nothing -> case xs of
      [] -> Just $ Const False ()
      _ -> Nothing
    Just [] -> Just $ Const False ()
    Just [x] -> Just x
    Just xs' -> Just $ App (SMTLogic Or) xs'
optimizeCall (SMTLogic XOr) [] = Just $ Const False ()
optimizeCall (SMTLogic Implies) [] = Just $ Const True ()
optimizeCall (SMTLogic Implies) xs
  = let (args,res) = splitLast xs
    in case res of
      Const True _ -> Just (Const True ())
      _ -> case removeConstsOf False args of
        Just _ -> Just $ Const True ()
        Nothing -> case removeConstsOf True args of
          Nothing -> case args of
            [] -> Just res
            _ -> Nothing
          Just [] -> Just res
          Just args' -> Just $ App (SMTLogic Implies) (args'++[res])
optimizeCall SMTITE (Const True _,ifT,_) = Just ifT
optimizeCall SMTITE (Const False _,_,ifF) = Just ifF
optimizeCall SMTITE (_,ifT,ifF) = case eqExpr ifT ifF of
  Just True -> Just ifT
  _ -> Nothing
optimizeCall (SMTBVBin op) args = bvBinOpOptimize op args
optimizeCall SMTConcat (Const (BitVector v1::BitVector b1) ann1,Const (BitVector v2::BitVector b2) ann2)
  = Just (Const (BitVector $ (v1 `shiftL` (fromInteger $ getBVSize (Proxy::Proxy b2) ann2)) .|. v2)
          (concatAnnotation (undefined::b1) (undefined::b2) ann1 ann2))
optimizeCall (SMTExtract pstart plen) (Const from@(BitVector v) ann)
  = let start = reflectNat pstart 0
        undefFrom :: BitVector from -> from
        undefFrom _ = undefined
        undefLen :: SMTExpr (BitVector len) -> len
        undefLen _ = undefined
        len = reflectNat plen 0
        res = Const (BitVector $ (v `shiftR` (fromInteger start)) .&. (1 `shiftL` (fromInteger $ reflectNat plen 0) - 1))
              (extractAnn (undefFrom from) (undefLen res) len ann)
    in Just res
optimizeCall (SMTBVComp op) args = bvCompOptimize op args
optimizeCall (SMTArith op) args = case cast args of
  Just args' -> case cast (intArithOptimize op args') of
    Just res -> res
  Nothing -> Nothing
optimizeCall SMTMinus args = case cast args of
  Just args' -> case cast (intMinusOptimize args') of
    Just res -> res
  Nothing -> Nothing
optimizeCall (SMTOrd op) args = case cast args of
  Just args' -> case cast (intCmpOptimize op args') of
    Just res -> res
  Nothing -> Nothing
optimizeCall _ _ = Nothing

removeConstsOf :: Bool -> [SMTExpr Bool] -> Maybe [SMTExpr Bool]
removeConstsOf val = removeItems (\e -> case e of
                                     Const c _ -> c==val
                                     _ -> False)

removeItems :: (a -> Bool) -> [a] -> Maybe [a]
removeItems f [] = Nothing
removeItems f (x:xs) = if f x
                       then (case removeItems f xs of
                                Nothing -> Just xs
                                Just xs' -> Just xs')
                       else (case removeItems f xs of
                                Nothing -> Nothing
                                Just xs' -> Just (x:xs'))

splitLast :: [a] -> ([a],a)
splitLast [x] = ([],x)
splitLast (x:xs) = let (xs',last) = splitLast xs
                   in (x:xs',last)

bvBinOpOptimize :: IsBitVector a => SMTBVBinOp -> (SMTExpr (BitVector a),SMTExpr (BitVector a)) -> Maybe (SMTExpr (BitVector a))
bvBinOpOptimize BVAdd (Const (BitVector 0) _,y) = Just y
bvBinOpOptimize BVAdd (x,Const (BitVector 0) _) = Just x
bvBinOpOptimize BVAdd (Const (BitVector x) w,Const (BitVector y) _) = Just (Const (bvRestrict (BitVector $ x+y) w) w)
bvBinOpOptimize BVAnd (Const (BitVector x) w,Const (BitVector y) _) = Just (Const (BitVector $ x .&. y) w)
bvBinOpOptimize BVOr (Const (BitVector x) w,Const (BitVector y) _) = Just (Const (BitVector $ x .|. y) w)
bvBinOpOptimize BVOr (Const (BitVector 0) _,oth) = Just oth
bvBinOpOptimize BVOr (oth,Const (BitVector 0) _) = Just oth
bvBinOpOptimize BVSHL (Const (BitVector x) w,Const (BitVector y) _)
  = Just (Const (bvRestrict (BitVector $ x `shiftL` (fromInteger y)) w) w)
bvBinOpOptimize BVSHL (Const (BitVector 0) w,_) = Just (Const (BitVector 0) w)
bvBinOpOptimize BVSHL (oth,Const (BitVector 0) w) = Just oth
bvBinOpOptimize _ _ = Nothing

bvCompOptimize :: IsBitVector a => SMTBVCompOp -> (SMTExpr (BitVector a),SMTExpr (BitVector a)) -> Maybe (SMTExpr Bool)
bvCompOptimize op (Const b1 ann1,Const b2 ann2)
  = Just $ Const (case op of
                     BVULE -> u1 <= u2
                     BVULT -> u1 < u2
                     BVUGE -> u1 >= u2
                     BVUGT -> u1 > u2
                     BVSLE -> s1 <= s2
                     BVSLT -> s1 < s2
                     BVSGE -> s1 >= s2
                     BVSGT -> s1 > s2) ()
  where
    u1 = bvUnsigned b1 ann1
    u2 = bvUnsigned b2 ann2
    s1 = bvSigned b1 ann1
    s2 = bvSigned b2 ann2
bvCompOptimize _ _ = Nothing

intArithOptimize :: SMTArithOp -> [SMTExpr Integer] -> Maybe (SMTExpr Integer)
intArithOptimize Plus xs
  = let (consts,nonconsts) = partitionEithers $ fmap (\e -> case e of
                                                         Const i _ -> Left i
                                                         _ -> Right e
                                                     ) xs
    in case consts of
      [] -> Nothing
      [x] -> case nonconsts of
        [] -> Just (Const x ())
        [y] -> if x==0
               then Just y
               else Nothing
        _ -> Nothing
      _ -> let s = sum consts
           in case nonconsts of
             [] -> Just (Const s ())
             [x] -> if s==0
                    then Just x
                    else Just (App (SMTArith Plus) [x,Const s ()])
             _ -> Just (App (SMTArith Plus) (nonconsts++(if s==0
                                                         then []
                                                         else [Const s ()])))
intArithOptimize Mult xs
  = let (consts,nonconsts) = partitionEithers $ fmap (\e -> case e of
                                                         Const i _ -> Left i
                                                         _ -> Right e
                                                     ) xs
    in case consts of
      [] -> Nothing
      [_] -> Nothing
      _ -> case nonconsts of
        [] -> Just (Const (product consts) ())
        _ -> Just (App (SMTArith Mult) (nonconsts++[Const (product consts) ()]))

intMinusOptimize :: (SMTExpr Integer,SMTExpr Integer) -> Maybe (SMTExpr Integer)
intMinusOptimize (Const x _,Const y _) = Just (Const (x-y) ())
intMinusOptimize (x,Const 0 _) = Just x
intMinusOptimize _ = Nothing

intCmpOptimize :: SMTOrdOp -> (SMTExpr Integer,SMTExpr Integer) -> Maybe (SMTExpr Bool)
intCmpOptimize op (Const x _,Const y _)
  = Just (Const (case op of
                    Ge -> x >= y
                    Gt -> x > y
                    Le -> x <= y
                    Lt -> x < y) ())
intCmpOptimize _ _ = Nothing
