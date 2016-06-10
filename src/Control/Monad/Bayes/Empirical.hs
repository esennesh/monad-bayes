{-# LANGUAGE
  TupleSections,
  GeneralizedNewtypeDeriving,
  FlexibleInstances,
  FlexibleContexts,
  Rank2Types
 #-}

module Control.Monad.Bayes.Empirical (
    Empirical,
    fromList,
    runEmpirical,
    population,
    spawn,
    all,
    resample,
    resampleN,
    resampleList,
    evidence,
    collapse,
    proper,
    transform
                 ) where

import Prelude hiding (all)

import Control.Monad.Trans.Class
import Control.Monad.State.Lazy
import Control.Monad.Trans.List
import Data.Number.LogFloat as LogFloat
import Data.Monoid
import qualified Data.Foldable as Fold

import Control.Monad.Bayes.Class
import Control.Monad.Bayes.Weighted

-- | Empirical distribution represented as a set of weighted samples.
-- Forward probabilistic computation is handled by the transformed monad,
-- while conditioning is done by updating empirical weights.
-- There is no automatic normalization or aggregation of weights.
newtype Empirical m a = Empirical {unEmpirical :: Weighted (ListT m) a}
    deriving (Functor, Applicative, Monad, MonadDist, MonadBayes)

runEmpirical :: Functor m => Empirical m a -> m [(a, LogFloat)]
runEmpirical = runListT . runWeighted . unEmpirical

fromList :: Monad m => m [(a, LogFloat)] -> Empirical m a
fromList = Empirical . withWeight . ListT

instance MonadTrans Empirical where
    lift = Empirical . lift . lift

-- | The number of samples used for approximation.
population :: Monad m => Empirical m a -> m Int
population e = do
  zs <- runEmpirical e
  return (length zs)

-- | Set the number of samples for the empirical distribution.
-- Bear in mind that invoking `spawn` twice in the same computation
-- leads to multiplying the number of samples.
spawn :: MonadDist m => Int -> Empirical m ()
spawn n = (Empirical $ lift $ ListT $ sequence $ replicate n $ return ()) >>
               factor (1 / fromIntegral n)

-- | A special version of fold that returns the result in the transformed monad.
fold :: (Monoid a, Monad m) => Empirical m a -> m a
fold = fmap (Fold.fold . map fst) . runEmpirical

-- | Checks if all samples of the empirical distribution satisfy a condition, using `fold`.
all :: Monad m => (a -> Bool) -> Empirical m a -> m Bool
all cond = fmap getAll . fold . fmap (All . cond)

-- | Model evidence estimator, also known as pseudo-marginal likelihood.
evidence :: MonadDist m => Empirical m a -> m LogFloat
evidence = fmap snd . proper

-- | Pick a sample at random from the empirical distribution,
-- according to the weights.
collapse :: MonadDist m => Empirical m a -> m a
collapse = fmap fst . proper

-- | Resample the particles inside the underlying monad.
resampleList :: MonadDist m => [(a, LogFloat)] -> m [(a, LogFloat)]
resampleList ys = do
  let (xs,ws) = unzip ys
  let z = LogFloat.sum ws
  let n = length ys
  offsprings <- multinomial ys n
  let new_samples = concat [replicate k x | (x,k) <- offsprings]
  return $ map (,z / fromIntegral n) new_samples

-- | Resample the particles using the underlying monad.
-- Model evidence estimate is preserved in total weight.
resample :: MonadDist m => Empirical m a -> Empirical m a
resample d = fromList (runEmpirical d >>= resampleList)

-- | As 'resample', but with set new population size.
resampleN :: MonadDist m => Int -> Empirical m a -> Empirical m a
resampleN n d = do
  ys <- lift $ runEmpirical d
  let (xs,ws) = unzip ys
  let z = LogFloat.sum ws
  factor z
  spawn n
  ancestor <- discrete ws
  let x = xs !! ancestor
  return x

-- | Properly weighted version of 'collapse', that is returned with
-- model evidence estimator from the same run.
proper :: MonadDist m => Empirical m a -> m (a,LogFloat)
proper = fmap head . runEmpirical . resampleN 1


-- | Pick one sample from the empirical distribution and use model evidence as a 'factor'.
transform :: (MonadDist m, MonadTrans t, MonadBayes (t m)) => Empirical m a -> t m a
transform e = do
  (x,p) <- lift $ proper e
  factor p
  return x
