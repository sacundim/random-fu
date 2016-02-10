{-# LANGUAGE RankNTypes, FlexibleInstances, MultiParamTypeClasses #-}
module Data.Random.RVar
    ( RVar, runRVar, hoistRVar
    , RVarT, runRVarT, runRVarTWith, hoistRVarT
    ) where

import Data.Random.Lift
import Data.Random.Internal.Source
import Data.RVar hiding (runRVarT)

-- |Like 'runRVarTWith', but using an implicit lifting (provided by the 
-- 'Lift' class)
runRVarT :: (Lift n m, RandomSource m s) => RVarT n a -> s -> m a
runRVarT = runRVarTWith lift
