{-
 -      ``Data/Random/Distribution/Ziggurat''
 -      A generic \"ziggurat algorithm\" implementation.  Fairly rough right
 -      now.
 -      
 -      There is a lot of room for improvement in 'findBin0' especially.
 -      It needs a fair amount of cleanup and elimination of redundant
 -      calculation, as well as either a justification for using the simple
 -      'findMinFrom' or a proper root-finding algorithm. 
 -      
 -      It would also be nice to add (preferably via its own library)
 -      support for numerical integration and differentiation, so that
 -      tables can be derived from only a PDF (if the end user is
 -      willing to take the performance hit for the convenience).
 -}
{-# LANGUAGE
        MultiParamTypeClasses,
        FlexibleInstances, FlexibleContexts,
        RecordWildCards
  #-}

module Data.Random.Distribution.Ziggurat
    ( Ziggurat(..)
    , mkZigguratRec
    , mkZiggurat
    , mkZiggurat_
    , findBin0
    , runZiggurat
    ) where

import Data.Random.Internal.Find

import Data.Random.Distribution.Uniform
import Data.Random.Distribution
import Data.Random.RVar
import Data.StorableVector as Vec
import Foreign.Storable

vec ! i = index vec i

-- |A data structure containing all the data that is needed
-- to implement Marsaglia & Tang's \"ziggurat\" algorithm for
-- sampling certain kinds of random distributions.
--
-- The documentation here is probably not sufficient to tell a user exactly
-- how to build one of these from scratch, but it is not really intended to
-- be.  There are several helper functions that will build 'Ziggurat's.
-- The pathologically curious may wish to read the 'runZiggurat' source.
-- That is the ultimate specification of the semantics of all these fields.
data Ziggurat t = Ziggurat {
        -- |The X locations of each bin in the distribution.  Bin 0 is the
        -- 'infinite' one.
        -- 
        -- In the case of bin 0, the value given is sort of magical - x[0] is
        -- defined to be V/f(R).  It's not actually the location of any bin, 
        -- but a value computed to make the algorithm more concise and slightly 
        -- faster by not needing to specially-handle bin 0 quite as often.
        -- If you really need to know why it works, see the 'runZiggurat'
        -- source or \"the literature\" - it's a fairly standard setup.
        zTable_xs         :: Vector t,
        -- |The ratio of each bin's Y value to the next bin's Y value
        zTable_x_ratios   :: Vector t,
        -- |The Y value (zFunc x) of each bin
        zTable_ys         :: Vector t,
        -- |An RVar providing a random tuple consisting of:
        --
        --  * a bin index, uniform over [0,c) :: Int (where @c@ is the
        --    number of bins in the tables)
        -- 
        --  * a uniformly distributed fractional value, from -1 to 1 
        --    if not mirrored, from 0 to 1 otherwise.
        --
        -- This is provided as a single 'RVar' because it can be implemented
        -- more efficiently than naively sampling 2 separate values - a
        -- single random word (64 bits) can be efficiently converted to
        -- a double (using 52 bits) and a bin number (using up to 12 bits),
        -- for example.
        zGetIU            :: RVar (Int, t),
        
        -- |The distribution for the final \"virtual\" bin
        -- (the ziggurat algorithm does not handle distributions
        -- that wander off to infinity, so another distribution is needed
        -- to handle the last \"bin\" that stretches to infinity)
        zTailDist         :: RVar t,
        
        -- |A copy of the uniform RVar generator for the base type,
        -- so that @Distribution Uniform t@ is not needed when sampling
        -- from a Ziggurat (makes it a bit more self-contained).
        zUniform          :: t -> t -> RVar t,
        
        -- |The (one-sided antitone) PDF, not necessarily normalized
        zFunc             :: t -> t,
        
        -- |A flag indicating whether the distribution should be
        -- mirrored about the origin (the ziggurat algorithm it
        -- its native form only samples from one-sided distributions.
        -- By mirroring, we can extend it to symmetric distributions
        -- such as the normal distribution)
        zMirror           :: Bool
    }

-- |Sample from the distribution encoded in a 'Ziggurat' data structure.
{-# INLINE runZiggurat #-}
runZiggurat :: (Num a, Ord a, Storable a) =>
               Ziggurat a -> RVar a
runZiggurat Ziggurat{..} = go
    where
        go = do
            -- select a bin and a uniform value from 0 to 1.
            -- let X be that value scaled to the size of the selected bin.
            (i,u) <- zGetIU
            let x = u * zTable_xs ! i
            
            -- if the uniform value U falls in the area "clearly inside" the
            -- bin, accept X immediately.
            -- Otherwise, depending on the bin selected, use either the
            -- tail distribution or an accept/reject test.
            if abs u < zTable_x_ratios ! i
                then return $! x
                else if i == 0
                    then sampleTail x
                    else sampleGreyArea i x
        
        -- when the sample falls in the "grey area" (the area between
        -- the Y value of the selected bin and the bin after that one),
        -- use an accept/reject method based on the target PDF.
        sampleGreyArea i x = do
            v <- zUniform (zTable_ys ! (i+1)) (zTable_ys ! i)
            if v < zFunc (abs x)
                then return $! x
                else go
        
        -- if the selected bin is the "infinite" one, call it quits and
        -- defer to the tail distribution (mirroring if needed)
        sampleTail x
            | x < 0     = fmap negate zTailDist
            | otherwise = zTailDist


-- |Build the tables to implement the \"ziggurat algorithm\" devised by 
-- Marsaglia & Tang, attempting to automatically compute the R and V
-- values.
-- 
-- Arguments:
-- 
--  * flag indicating whether to mirror the distribution
-- 
--  * the (one-sided antitone) PDF, not necessarily normalized
-- 
--  * the inverse of the PDF
-- 
--  * the number of bins
-- 
--  * R, the x value of the first bin
-- 
--  * V, the volume of each bin
-- 
--  * an RVar providing the 'zGetIU' random tuple
-- 
--  * an RVar sampling from the tail (the region where x > R)
-- 
mkZiggurat_ :: (RealFloat t, Storable t,
               Distribution Uniform t) =>
              Bool
              -> (t -> t)
              -> (t -> t)
              -> Int
              -> t
              -> t
              -> RVar (Int, t)
              -> RVar t
              -> Ziggurat t
mkZiggurat_ m f fInv c r v getIU tailDist = z
    where z = Ziggurat
            { zTable_xs         = zigguratTable f fInv c r v
            , zTable_x_ratios   = precomputeRatios (zTable_xs z)
            , zTable_ys         = Vec.map f (zTable_xs z)
            , zGetIU            = getIU
            , zUniform          = uniform
            , zFunc             = f
            , zTailDist         = tailDist
            , zMirror           = m
            }

-- |Build the tables to implement the \"ziggurat algorithm\" devised by 
-- Marsaglia & Tang, attempting to automatically compute the R and V
-- values.
-- 
-- Arguments are the same as for |mkZigguratRec|, with an additional
-- argument for the tail distribution as a function of the selected
-- R value.
mkZiggurat :: (RealFloat t, Storable t,
               Distribution Uniform t) =>
              Bool
              -> (t -> t)
              -> (t -> t)
              -> (t -> t)
              -> t
              -> Int
              -> RVar (Int, t)
              -> (t -> RVar t)
              -> Ziggurat t
mkZiggurat m f fInv fInt fVol c getIU tailDist =
    mkZiggurat_ m f fInv c r v getIU (tailDist r) 
        where
            (r,v) = findBin0 c f fInv fInt fVol

-- |Build a lazy recursive ziggurat.  Uses a lazily-constructed ziggurat
-- as its tail distribution (with another as its tail, ad nauseum).
-- 
-- Arguments:
-- 
--  * flag indicating whether to mirror the distribution
--
--  * the (one-sided antitone) PDF, not necessarily normalized
--
--  * the inverse of the PDF
--
--  * the integral of the PDF (definite, from 0)
--
--  * the estimated volume under the PDF (from 0 to +infinity)
--
--  * the chunk size (number of bins in each layer).  64 seems to
--    perform well in practice.
--
--  * an RVar providing the 'zGetIU' random tuple
--
mkZigguratRec ::
  (RealFloat t, Storable t,
   Distribution Uniform t) =>
  Bool
  -> (t -> t)
  -> (t -> t)
  -> (t -> t)
  -> t
  -> Int
  -> RVar (Int, t)
  -> Ziggurat t
mkZigguratRec m f fInv fInt fVol c getIU = 
    mkZiggurat m f fInv fInt fVol c getIU (fix (mkTail m f fInv fInt fVol c getIU))
        where
            fix f = f (fix f)

mkTail m f fInv fInt fVol c getIU nextTail r = do
     x <- rvar (mkZiggurat m f' fInv' fInt' fVol' c getIU nextTail)
     return (x + r * signum x)
        where
            fIntR = fInt r
            
            f' x    | x < 0     = f r
                    | otherwise = f (x+r)
            fInv' = subtract r . fInv
            fInt' x | x < 0     = 0
                    | otherwise = fInt (x+r) - fIntR
            
            fVol' = fVol - fIntR
        

zigguratTable :: (Fractional a, Storable a, Ord a) =>
                 (a -> a) -> (a -> a) -> Int -> a -> a -> Vector a
zigguratTable f fInv c r v = case zigguratXs f fInv c r v of
    (xs, excess) -> pack xs
    where epsilon = 1e-3*v

zigguratExcess f fInv c r v = snd (zigguratXs f fInv c r v)

zigguratXs f fInv c r v = (xs, excess)
    where
        xs = Prelude.map x [0..c] -- sample c x
        ys = Prelude.map f xs
        
        x 0 = v / f r
        x 1 = r
        x i | i == c = 0
        x (i+1) = next i
        
        next i = let x_i = xs!!i
                  in if x_i <= 0 then -1 else fInv (ys!!i + (v / x_i))
        
        excess = xs!!(c-1) * (f 0 - ys !! (c-1)) - v 


precomputeRatios zTable_xs = sample (c-1) $ \i -> zTable_xs!(i+1) / zTable_xs!i
    where
        c = Vec.length zTable_xs

-- |I suspect this isn't completely right, but it works well so far.
-- Search the distribution for an appropriate R and V.
--
-- Arguments:
-- 
--  * Number of bins
--
--  * function (one-sided antitone PDF, not necessarily normalized
--
--  * function inverse
--
--  * function definite integral (from 0 to _)
--
--  * estimate of total volume under function (integral from 0 to infinity)
--
-- Result: (R,V)
findBin0 :: (RealFloat b) => 
    Int -> (b -> b) -> (b -> b) -> (b -> b) -> b -> (b, b)
findBin0 cInt f fInv fInt fVol = (r,v r)
    where
        c = fromIntegral cInt
        v r = r * f r + fVol - fInt r
        
        -- initial R guess:
        r0 = findMin (\r -> v r <= fVol / c)
        -- find a better R:
        r = findMinFrom r0 1 $ \r -> 
            let e = exc r 
             in e >= 0 && not (isNaN e)
        
        exc x = zigguratExcess f fInv cInt x (v x)

instance (Num t, Ord t, Storable t) => Distribution Ziggurat t where
    rvar = runZiggurat
