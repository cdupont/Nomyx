{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | additional tools for evaluation
module Nomyx.Core.Engine.EvalUtils where

import           Control.Applicative
import           Control.Category
import           Control.Lens
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.List
import           Data.Maybe
import           Data.Typeable
import           Language.Nomyx.Expression
import           Nomyx.Core.Engine.Types
import           Nomyx.Core.Engine.Utils
import           Prelude                   hiding (log, (.))
import           Safe

-- find a signal occurence in an environment
lookupSignal :: Typeable a => Signal a -> SignalAddress -> [SignalOccurence] -> Maybe a
lookupSignal s sa envi = headMay $ mapMaybe (getSignalData s sa) envi

--get the signal data from the signal occurence
getSignalData :: Typeable a => Signal a -> SignalAddress -> SignalOccurence -> Maybe a
getSignalData s sa (SignalOccurence (SignalData s' res) sa') = do
   ((s'', res') :: (Signal a, a)) <- cast (s', res)
   if (s'' == s) && (sa' == sa) then Just res' else Nothing


errorHandler :: EventNumber -> String -> Evaluate ()
errorHandler en s = do
   rn <- use eRuleNumber
   logAll $ "Error in rule " ++ show rn ++ " (triggered by event " ++ show en ++ "): " ++ s

logPlayer :: PlayerNumber -> String -> Evaluate ()
logPlayer pn = log (Just pn)

logAll :: String -> Evaluate ()
logAll = log Nothing

log :: Maybe PlayerNumber -> String -> Evaluate ()
log mpn s = focusGame $ do
   time <- use currentTime
   void $ logs %= (Log mpn time s : )

--liftEval :: EvaluateNE a -> Evaluate a
--liftEval r = runReader r <$> get



focusGame :: State Game a -> Evaluate a
focusGame = lift . zoom eGame

accessGame :: Lens' Game a -> Evaluate (a, RuleNumber)
accessGame l = do
   a <- use (eGame . l)
   rn <- use eRuleNumber
   return (a, rn)

putGame :: Lens' Game a -> a -> Evaluate ()
putGame l a = do
   ruleActive <- evalRuleActive
   when ruleActive $ void $ (eGame . l) .= a

modifyGame :: Lens' Game a -> (a -> a) -> Evaluate ()
modifyGame l f = do
   ruleActive <- evalRuleActive
   when ruleActive $ void $ (eGame . l) %= f

evalRuleActive :: Evaluate Bool
evalRuleActive = do
   rn <- use eRuleNumber
   rs <- use (eGame . rules)
   return $ (rn == 0) ||
      case find (\r -> _rNumber r == rn) rs of
         Just r -> _rStatus r == Active
         Nothing -> True --TODO why should there be an evaluating rule not in the list?


--replace temporarily the rule number used for evaluation
withRN :: RuleNumber -> Evaluate a -> Evaluate a
withRN rn eval = do
   oldRn <- gets _eRuleNumber
   eRuleNumber .= rn
   a <- eval
   eRuleNumber .= oldRn
   return a

instance Eq SomeSignal where
  (SomeSignal e1) == (SomeSignal e2) = e1 === e2

instance Show EventInfo where
   show (EventInfo en rn _ _ s envi) =
      "event num: " ++ (show en) ++
      ", rule num: " ++ (show rn) ++
      ", envs: " ++ (show envi) ++
      ", status: " ++ (show s)
