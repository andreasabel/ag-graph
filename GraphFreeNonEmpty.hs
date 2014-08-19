{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecursiveDo #-}


-- This is a variant of the alternative implementation from the module
-- "GraphFree". This representation does not allow empty edges.

module GraphFreeNonEmpty where

import Graph (Node)

import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap


import Data.Traversable (Traversable)
import qualified Data.Traversable as Traversable

import Control.Monad.State

import Control.Monad.ST
import Data.STRef
import qualified Data.Vector as Vec
import qualified Data.Vector.Generic.Mutable as MVec
import Data.Maybe

import AG

data Graph f = Graph { _root :: Node
                     , _eqs :: IntMap (f (Free f Node))
                     , _next :: Node }

-- | Construct a graph
mkGraph :: Node -> [(Node, f (Free f Node))] -> Graph f
mkGraph r es = Graph r (IntMap.fromList es) (maximum (map fst es) + 1)


-- | This function runs an AG on a graph.
runAGGraph :: forall f d u .Traversable f
    => (d -> d -> d)         -- ^ Resolution of top-down state
    -> Syn' f (u,d) u  -- ^ Bottom-up state propagation
    -> Inh' f (u,d) d  -- ^ Top-down state propagation
    -> d                     -- ^ Initial top-down state
    -> Graph f
    -> u
runAGGraph res syn inh d g = umap IntMap.! _root g
    where syn' :: SynExpl f (u,d) u
          syn' = explicit syn
          inh' :: InhExpl f (u,d) d
          inh' = explicit inh
          run = free res  syn' inh'
          dmap = IntMap.foldr (\ (_,m1) m2 -> IntMap.unionWith res m1 m2) 
                 (IntMap.singleton (_root g) d) result
          umap = IntMap.map fst result
          result = IntMap.mapWithKey (\ n t -> run (dmap IntMap.! n) umap t) (_eqs g)


-- | Auxiliary function for 'runAGGraph'.

free :: forall f u d . Traversable f => (d -> d -> d) -> SynExpl f (u,d) u -> InhExpl f (u,d) d
     -> d -> IntMap u -> f (Free f Node) -> (u, IntMap d)
free res syn inh d umap s = run d s where
    run :: d -> f (Free f Node) -> (u, IntMap d)
    run d t = (u, dmap)
        where u = syn (u,d) unNumbered result
              m = inh (u,d) unNumbered result
              (result, (dmap,_)) = runState (Traversable.mapM run' t) (IntMap.empty,0)
              run' :: Free f Node -> State (IntMap d, Int) (Numbered ((u,d)))
              run' s = do
                  (oldDmap,i) <- get
                  let d' = lookupNumMap d i m
                      (u',dmap') = runF d' s
                  put (IntMap.unionWith res dmap' oldDmap, (i+1))
                  return (Numbered i (u',d'))
    runF :: d -> Free f Node -> (u, IntMap d)
    runF d (Ret x) = (umap IntMap.! x, IntMap.singleton x d)
    runF d (In t)  = run d t

-- | Alternative implementation of 'runAGGraph' that uses mutable
-- vectors for caching intermediate values.

runAGGraphST :: forall f d u .Traversable f
    => (d -> d -> d)         -- ^ Resolution of top-down state
    -> Syn' f (u,d) u  -- ^ Bottom-up state propagation
    -> Inh' f (u,d) d  -- ^ Top-down state propagation
    -> d                     -- ^ Initial top-down state
    -> Graph f
    -> u
runAGGraphST res syn inh d g = runST runM 
    where syn' :: SynExpl f (u,d) u
          syn' = explicit syn
          inh' :: InhExpl f (u,d) d
          inh' = explicit inh
          runM :: ST s u
          runM = mdo dmap <- MVec.new (_next g)
                     MVec.set dmap Nothing
                     MVec.unsafeWrite dmap (_root g) (Just d)
                     umap <- MVec.new (_next g)
                     count <- newSTRef 0
                     let iter (n, t) = do 
                           u <- freeST res  syn' inh' dmap (fromJust $ dmapFin Vec.! n) umapFin count t   
                           MVec.unsafeWrite umap n u
                     mapM_ iter (IntMap.toList $ _eqs g)
                     dmapFin <- Vec.unsafeFreeze dmap
                     umapFin <- Vec.unsafeFreeze umap
                     return (umapFin Vec.! _root g)



-- | Auxiliary function for 'runAGGraphST'.

freeST :: forall f u d s . Traversable f => (d -> d -> d) -> SynExpl f (u,d) u -> InhExpl f (u,d) d
       -> Vec.MVector s (Maybe d)
     -> d -> Vec.Vector u -> STRef s Int -> f (Free f Node) -> ST s u
freeST res syn inh ref d umap count s = run d s where
    run :: d -> f (Free f Node) -> ST s u
    run d t = mdo let u = syn (u,d) unNumbered result
                  let m = inh (u,d) unNumbered result
                  writeSTRef count 0
                  let run' :: Free f Node -> ST s (Numbered (u,d))
                      run' s = do i <- readSTRef count
                                  let j = i+1
                                  j `seq` writeSTRef count j
                                  let d' = lookupNumMap d i m
                                  u' <- runF d' s
                                  return (Numbered i (u',d'))
                  result <- Traversable.mapM run' t
                  return u
    runF :: d -> Free f Node -> ST s u
    runF d (Ret x) = do old <- MVec.unsafeRead ref x
                        let new = case old of
                                    Just o -> res o d
                                    _      -> d
                        MVec.unsafeWrite ref x (Just new)
                        return (umap Vec.! x)
    runF d (In t)  = run d t


termTree :: Functor f => Tree f -> Graph f
termTree (In t) = Graph 0 (IntMap.singleton 0 (fmap freeTree t)) 1
