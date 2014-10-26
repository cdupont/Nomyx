{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DoAndIfThenElse #-}

-- | Evaluation of a Nomyx expression
module Nomyx.Core.Engine.Evaluation where

import Prelude hiding ((.), log)
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Data.List
import Data.Typeable
import Data.Time
import Data.Lens
import Data.Maybe
import Data.Todo
import Data.Either
import Data.Function (on)
import Control.Category hiding (id)
import Control.Applicative
import Control.Monad.Error.Class (MonadError(..))
import Language.Nomyx.Expression
import Nomyx.Core.Engine.Types hiding (_vRuleNumber)
import Nomyx.Core.Engine.EvalUtils
import Nomyx.Core.Engine.Utils
import Safe
import System.Random


-- * Evaluation

-- | evaluate an effecful expression.
evalNomex :: Nomex a -> Evaluate a
evalNomex (NewVar v a)            = evNewVar v a
evalNomex (DelVar v)              = evDelVar v
evalNomex (WriteVar v val)        = evWriteVar v val
evalNomex (OnEvent ev h)          = evOnEvent ev h
evalNomex (DelEvent en)           = evDelEvent en
evalNomex (SendMessage m d)       = evSendMessage m d
evalNomex (NewOutput pn s)        = evNewOutput pn s
evalNomex (UpdateOutput on s)     = evUpdateOutput on s
evalNomex (DelOutput on)          = evDelOutput on
evalNomex (ProposeRule rule)      = evProposeRule rule
evalNomex (ActivateRule rule)     = evActivateRule rule
evalNomex (RejectRule rule)       = evRejectRule rule
evalNomex (AddRule rule)          = evAddRule rule
evalNomex (ModifyRule mod rule)   = evModifyRule mod rule
evalNomex (SetPlayerName pn n)    = evChangeName pn n
evalNomex (DelPlayer pn)          = evDelPlayer pn
evalNomex (SetVictory ps)         = evSetVictory ps
evalNomex (LiftEffect e)          = liftEval $ evalNomexNE e
evalNomex (ThrowError s)          = throwError s
evalNomex (CatchError n h)        = catchError (evalNomex n) (\a -> evalNomex (h a))
evalNomex (Return a)              = return a
evalNomex (Bind exp f)            = evalNomex exp >>= \e -> evalNomex (f e)
evalNomex (GetRandomNumber r)     = evGetRandomNumber r

-- | evaluate an effectless expression.
evalNomexNE :: NomexNE a -> EvaluateNE a
evalNomexNE (ReadVar v)     = evReadVar v
evalNomexNE (GetOutput on)  = evGetOutput on
evalNomexNE  GetRules       = _rules <$> asks _eGame
evalNomexNE  GetPlayers     = _players <$> asks _eGame
evalNomexNE  GetEvents      = _events <$> asks _eGame
evalNomexNE  SelfRuleNumber = asks _eRuleNumber
evalNomexNE (CurrentTime)   = _currentTime <$> asks _eGame
evalNomexNE (Return a)      = return a
evalNomexNE (Bind exp f)    = evalNomexNE exp >>= \e -> evalNomexNE (f e)
evalNomexNE (Simu sim ev)   = evSimu sim ev


evNewVar :: (Typeable a, Show a) => VarName -> a -> Evaluate (Maybe (V a))
evNewVar name def = do
   (vars, rn) <- accessGame variables
   case find ((== name) . getL vName) vars of
      Nothing -> do
         modifyGame variables (Var rn name def : )
         return $ Just (V name)
      Just _ -> return Nothing

evDelVar :: (V a) -> Evaluate Bool
evDelVar (V name) = do
   (vars, _) <- accessGame variables
   case find ((== name) . getL vName) vars of
      Nothing -> return False
      Just _ -> do
         modifyGame variables $ filter ((/= name) . getL vName)
         return True

evWriteVar :: (Typeable a, Show a) => V a -> a -> Evaluate Bool
evWriteVar (V name) val = do
   (vars, _) <- accessGame variables
   case find (\(Var _ myName _) -> myName == name) vars of
      Nothing -> return False
      Just (Var rn myName _) -> do
         modifyGame variables $ replaceWith ((== name) . getL vName) (Var rn myName val)
         return True

evOnEvent :: (Typeable e, Show e) => Event e -> ((EventNumber, e) -> Nomex ()) -> Evaluate EventNumber
evOnEvent event handler = do
   (evs, rn) <- accessGame events
   let en = getFreeNumber (map _eventNumber evs)
   modifyGame events (EventInfo en rn event handler SActive [] : )
   return en

evSendMessage :: (Typeable a, Show a) => Msg a -> a -> Evaluate ()
evSendMessage (Msg id) d = triggerEvent (Message (Msg id)) d

evProposeRule :: RuleInfo -> Evaluate Bool
evProposeRule rule = do
   (rs, _) <- accessGame rules
   case find ((== (rNumber ^$ rule)) . getL rNumber) rs of
      Nothing -> do
         modifyGame rules (rule:)
         triggerEvent (RuleEv Proposed) rule
         return True
      Just _ -> return False

--Sets the rule status to Active and execute it if possible
evActivateRule :: RuleNumber -> Evaluate Bool
evActivateRule rn = do
   (rs, by) <- accessGame rules
   case find (\r -> _rNumber r == rn && _rStatus r /= Active) rs of
      Nothing -> return False
      Just r -> do
         putGame rules $ replaceWith ((== rn) . getL rNumber) r{_rStatus = Active, _rAssessedBy = Just by} rs
         --execute the rule
         withRN (_rNumber r) $ evalNomex (_rRule r)
         triggerEvent (RuleEv Activated) r
         return True

evRejectRule :: RuleNumber -> Evaluate Bool
evRejectRule rn = do
   (rs, by) <- accessGame rules
   case find (\r -> _rNumber r == rn && _rStatus r /= Reject) rs of
      Nothing -> return False
      Just r -> do
         delVarsRule rn
         delEventsRule rn
         delOutputsRule rn
         delVictoryRule rn
         putGame rules $ replaceWith ((== rn) . getL rNumber) r{_rStatus = Reject, _rAssessedBy = Just by} rs
         triggerEvent (RuleEv Rejected) r
         return True

evAddRule :: RuleInfo -> Evaluate Bool
evAddRule rule = do
   (rs, _) <- accessGame rules
   case find ((== (rNumber ^$ rule)) . getL rNumber) rs of
      Nothing -> do
         modifyGame rules (rule:)
         triggerEvent (RuleEv Added) rule
         return True
      Just _ -> return False


evModifyRule :: RuleNumber -> RuleInfo -> Evaluate Bool
evModifyRule rn rule = do
   (rs, _) <- accessGame rules
   let newRules = replaceWith ((== rn) . getL rNumber) rule rs
   case find ((== rn) . getL rNumber) rs of
      Nothing -> return False
      Just r ->  do
         putGame rules newRules
         triggerEvent (RuleEv Modified) r
         return True

evDelPlayer :: PlayerNumber -> Evaluate Bool
evDelPlayer pn = do
   g <- access eGame
   case find ((== pn) . getL playerNumber) (_players g) of
      Nothing -> do
         tracePN pn "not in game!"
         return False
      Just pi -> do
         modifyGame players $ filter ((/= pn) . getL playerNumber)
         triggerEvent (Player Leave) pi
         tracePN pn $ "leaving the game: " ++ _gameName g
         return True

evChangeName :: PlayerNumber -> PlayerName -> Evaluate Bool
evChangeName pn name = do
   pls <- access (eGame >>> players)
   case find ((== pn) . getL playerNumber) pls of
      Nothing -> return False
      Just pi -> do
         putGame players $ replaceWith ((== pn) . getL playerNumber) (pi {_playerName = name}) pls
         return True

evDelEvent :: EventNumber -> Evaluate Bool
evDelEvent en = do
   evs <- access (eGame >>> events)
   case find ((== en) . getL eventNumber) evs of
      Nothing -> return False
      Just eh -> case _evStatus eh of
         SActive -> do
            putGame events $ replaceWith ((== en) . getL eventNumber) eh{_evStatus = SDeleted} evs
            return True
         SDeleted -> return False

evTriggerTime :: UTCTime -> Evaluate ()
evTriggerTime t = triggerEvent (Time t) t

evNewOutput :: Maybe PlayerNumber -> NomexNE String -> Evaluate OutputNumber
evNewOutput pn s = do
   (ops, rn) <- accessGame outputs
   let on = getFreeNumber (map _outputNumber ops)
   modifyGame outputs (Output on rn pn s SActive : )
   return on

evGetOutput :: OutputNumber -> EvaluateNE (Maybe String)
evGetOutput on = do
   ops <- _outputs <$> asks _eGame
   case find (\(Output myOn _ _ _ s) -> myOn == on && s == SActive) ops of
      Nothing -> return Nothing
      Just (Output _ _ _ o _) -> do
         out <- evalNomexNE o
         return $ Just out

evUpdateOutput :: OutputNumber -> NomexNE String -> Evaluate Bool
evUpdateOutput on s = do
   (ops, _) <- accessGame outputs
   case find (\(Output myOn _ _ _ s) -> myOn == on && s == SActive) ops of
      Nothing -> return False
      Just (Output _ rn pn _ _) -> do
         modifyGame outputs $ replaceWith ((== on) . getL outputNumber) (Output on rn pn s SActive)
         return True

evDelOutput :: OutputNumber -> Evaluate Bool
evDelOutput on = do
   ops <- access (eGame >>> outputs)
   case find ((== on) . getL outputNumber) ops of
      Nothing -> return False
      Just o -> case _oStatus o of
         SActive -> do
            putGame outputs $ replaceWith ((== on) . getL outputNumber) o{_oStatus = SDeleted} ops
            return True
         SDeleted -> return False

evSetVictory :: NomexNE [PlayerNumber] -> Evaluate ()
evSetVictory ps = do
   rn <- access eRuleNumber
   putGame victory (Just $ VictoryInfo rn ps)
   triggerEvent Victory (VictoryInfo rn ps)

evReadVar :: (Typeable a, Show a) => V a -> EvaluateNE (Maybe a)
evReadVar (V name) = do
   vars <- _variables <$> asks _eGame
   let var = find ((== name) . getL vName) vars
   case var of
      Nothing -> return Nothing
      Just (Var _ _ val) -> case cast val of
          Just v -> return $ Just v
          Nothing -> return Nothing

evGetRandomNumber :: Random a => (a, a) -> Evaluate a
evGetRandomNumber r = do
   g <- access (eGame >>> randomGen)
   let (a, g') = randomR r g
   putGame randomGen g'
   return a

--TODO should we also give a rule number to simulate the Nomex with?
-- currently we use the simulating rule number
evSimu :: Nomex a -> NomexNE Bool -> EvaluateNE Bool
evSimu sim ev = do
   rn <- asks _eRuleNumber
   let s = runEvalError rn Nothing (evalNomex sim)
   g <- asks _eGame
   let g' = execState s g
   return $ runEvaluateNE g' rn (evalNomexNE ev)



-- * Events



-- trigger an event
triggerEvent :: (Typeable e, Show e) => Signal e -> e -> Evaluate ()
triggerEvent e dat = access (eGame >>> events) >>= triggerEvent' (SignalOccurence e dat Nothing)

-- trigger some specific signal
triggerEvent' :: SignalOccurence -> [EventInfo] -> Evaluate ()
triggerEvent' res evs = do
   evs' <- mapM (liftEval . (updateEventInfo res)) (sortBy (compare `on` _ruleNumber) evs)  -- get all the EventInfos updated with the field
   (eGame >>> events) %= union (map fst evs')                                               -- store them
   void $ mapM triggerIfComplete evs'                                                       -- trigger the handlers for completed events

-- if the event is complete, trigger its handler
triggerIfComplete :: (EventInfo, Maybe SomeData) -> Evaluate ()
triggerIfComplete (EventInfo en rn _ h SActive _, Just (SomeData val)) = case (cast val) of
   Just a ->  void $ withRN rn $ (evalNomex $ h (en, a)) `catchError` (errorHandler en)
   Nothing -> error "Bad trigger data type"
triggerIfComplete _ = return ()

-- update the EventInfo with the signal data.
-- get the event result if all signals are completed
updateEventInfo :: SignalOccurence -> EventInfo -> EvaluateNE (EventInfo, Maybe SomeData)
updateEventInfo (SignalOccurence signal dat addr) ei@(EventInfo _ _ ev _ _ envi) = do
   g <- asks _eGame
   let eventRes = SignalOccurence signal dat addr
   er <- getEventResult ev (eventRes : envi)
   return $ case er of                                                      -- check if the event will be complete
      Todo _ ->
         if (SomeSignal signal) `elem` (map snd $ getRemainingSignals ei g) -- is yes, check if our signal is really a missing signal of the event
            then (env ^=  (eventRes : envi) $ ei, Nothing)                  -- some signals are left to complete: add ours in the environment
            else (ei, Nothing)                                              -- signal not found: do nothing
      Done a -> (env ^=  [] $ ei, Just $ SomeData a)                        -- the event is complete: empty the environment and output the result


--get the signals left to be completed in an event
getRemainingSignals :: EventInfo -> Game -> [(SignalAddress, SomeSignal)]
getRemainingSignals (EventInfo _ rn e _ _ env) g = case runEvaluateNE g rn $ getEventResult e env of
   Done _ -> []
   Todo a -> a

-- compute the result of an event given an environment.
-- in the case the event cannot be computed because some signals results are pending, return that list instead.
getEventResult :: Event a -> [SignalOccurence] -> EvaluateNE (Todo (SignalAddress, SomeSignal) a)
getEventResult e frs = getEventResult' e frs []

getEventResult' :: Event a -> [SignalOccurence] -> SignalAddress -> EvaluateNE (Todo (SignalAddress, SomeSignal) a)
getEventResult' (PureEvent a)   _   _  = return $ Done a
getEventResult'  EmptyEvent     _   _  = return $ Todo []
getEventResult' (SumEvent a b)  ers fa = liftM2 (<|>) (getEventResult' a ers (fa ++ [SumL])) (getEventResult' b ers (fa ++ [SumR]))
getEventResult' (AppEvent f b)  ers fa = liftM2 (<*>) (getEventResult' f ers (fa ++ [AppL])) (getEventResult' b ers (fa ++ [AppR]))
getEventResult' (LiftEvent a)   _   _  = evalNomexNE a >>= return . Done
getEventResult' (BindEvent a f) ers fa = do
   er <- getEventResult' a ers (fa ++ [BindL])
   case er of
      Done a' -> getEventResult' (f a') ers (fa ++ [BindR])
      Todo bs -> return $ Todo bs

getEventResult' (SignalEvent a)  ers fa = return $ case lookupSignal a fa ers of
   Just r  -> Done r
   Nothing -> Todo [(fa, SomeSignal a)]

getEventResult' (ShortcutEvents es f) ers fa = do
  (ers :: [Todo (SignalAddress, SomeSignal) a]) <- mapM (\e -> getEventResult' e ers (fa ++ [Shortcut])) es -- get the result for each event in the list
  return $ case f (toMaybe <$> ers) of                                                                      -- apply f to the event results that we already have
     True  -> Done $ toMaybe <$> ers                                                                        -- if the result is true, we are done. Return the list of maybe results
     False -> Todo $ join $ lefts $ toEither <$> ers                                                        -- otherwise, return the list of remaining fields to complete from each event



-- * Input triggers


-- trigger the input signal with the input data
triggerInput :: EventNumber -> SignalAddress -> FormField -> InputData -> Evaluate ()
triggerInput en fa ft ir = do
   evs <- access (eGame >>> events)
   let mei = find ((== en) . getL eventNumber) evs
   when (isJust mei) $ execInputHandler ir fa ft (fromJust mei)

-- execute the corresponding handler
triggerInputSignal :: InputData -> SignalAddress -> FormField -> EventInfo -> Evaluate ()
triggerInputSignal ir fa ft ei@(EventInfo _ _ _ _ SActive _) = do
   i <- liftEval $ findField ft fa ei
   case i of
      Just sf -> triggerInputSignal' ir sf fa ei
      Nothing -> logAll $ "Input not found, InputData=" ++ (show ir) ++ " SignalAddress=" ++ (show fa) ++ " FormField=" ++ (show ft)
triggerInputSignal _ _ _ _ = return ()

-- execute the event handler using the data received from user
triggerInputSignal' :: InputData -> SomeSignal -> SignalAddress -> EventInfo -> Evaluate ()
triggerInputSignal' (TextData s)      (SomeSignal e@(Input _ _ (Text)))        fa ei = triggerEvent' (SignalOccurence e s                     (Just fa)) [ei]
triggerInputSignal' (TextAreaData s)  (SomeSignal e@(Input _ _ (TextArea)))    fa ei = triggerEvent' (SignalOccurence e s                     (Just fa)) [ei]
triggerInputSignal' (ButtonData)      (SomeSignal e@(Input _ _ (Button)))      fa ei = triggerEvent' (SignalOccurence e ()                    (Just fa)) [ei]
triggerInputSignal' (RadioData i)     (SomeSignal e@(Input _ _ (Radio cs)))    fa ei = triggerEvent' (SignalOccurence e (fst $ cs!!i)         (Just fa)) [ei]
triggerInputSignal' (CheckboxData is) (SomeSignal e@(Input _ _ (Checkbox cs))) fa ei = triggerEvent' (SignalOccurence e (fst <$> cs `sel` is) (Just fa)) [ei]
triggerInputSignal' _ _ _ _ = return ()


-- | Get the form field at a certain address
findField :: FormField -> SignalAddress -> EventInfo -> EvaluateNE (Maybe SomeSignal)
findField ft addr (EventInfo _ _ e _ _ er) = findField' addr e er ft

findField' :: SignalAddress -> Event e -> [SignalOccurence] -> FormField -> EvaluateNE (Maybe SomeSignal)
findField' []         (SignalEvent f)    _   ft = return $ do
   ft' <- getFormField (SomeSignal f)
   guard (ft' == ft)
   return $ SomeSignal f
findField' (SumL:as)  (SumEvent e1 _)  frs ft = findField' as e1 (filterPath SumL frs) ft
findField' (SumR:as)  (SumEvent _ e2)  frs ft = findField' as e2 (filterPath SumR frs) ft
findField' (AppL:as)  (AppEvent e1 _)  frs ft = findField' as e1 (filterPath AppL frs) ft
findField' (AppR:as)  (AppEvent _ e2)  frs ft = findField' as e2 (filterPath AppR frs) ft
findField' (BindL:as) (BindEvent e1 _) frs ft = findField' as e1 (filterPath BindL frs) ft
findField' (BindR:as) (BindEvent e1 f) frs ft = do
   ter <- getEventResult e1 (filterPath BindL frs) --
   case ter of
      Done e2 -> findField' as (f e2) (filterPath BindR frs) ft
      Todo _  -> return $ Nothing
findField' (Shortcut:as) (ShortcutEvents es _) frs ft = do
   msfs <- mapM (\e-> findField' as e frs ft) es
   return $ headMay $ catMaybes msfs  -- returning the first field that matches

findField' fa _ _ _ = error $ "findField: wrong field address: " ++ (show fa)

-- | removes one element of signal path
filterPath :: SignalAddressElem -> [SignalOccurence] -> [SignalOccurence]
filterPath fa frs = mapMaybe f frs where
   f (SignalOccurence fe fr (Just (fa':fas))) | fa == fa' = Just $ SignalOccurence fe fr (Just fas)
   f fr = Just fr

getFormField :: SomeSignal -> Maybe FormField
getFormField (SomeSignal (Input pn s (Radio choices)))    = Just $ RadioField pn s (zip [0..] (snd <$> choices))
getFormField (SomeSignal (Input pn s Text))               = Just $ TextField pn s
getFormField (SomeSignal (Input pn s TextArea))           = Just $ TextAreaField pn s
getFormField (SomeSignal (Input pn s Button))             = Just $ ButtonField pn s
getFormField (SomeSignal (Input pn s (Checkbox choices))) = Just $ CheckboxField pn s (zip [0..] (snd <$> choices))
getFormField _ = Nothing

-- * misc

getVictorious :: Game -> [PlayerNumber]
getVictorious g = case _victory g of
   Nothing -> []
   Just (VictoryInfo rn v) -> runEvaluateNE g rn (evalNomexNE v)

evalOutput :: Game -> Output -> String
evalOutput g (Output _ rn _ o _) = runEvaluateNE g rn (evalNomexNE o)

allOutputs :: Game -> [String]
allOutputs g = map (evalOutput g) (_outputs g)

--delete all variables of a rule
delVarsRule :: RuleNumber -> Evaluate ()
delVarsRule rn = void $ (eGame >>> variables) %= filter ((/= rn) . getL vRuleNumber)

--delete all events of a rule
delEventsRule :: RuleNumber -> Evaluate ()
delEventsRule rn = do
   evs <- access (eGame >>> events)
   let toDelete = filter ((== rn) . getL ruleNumber) evs
   mapM_ (evDelEvent . _eventNumber) toDelete

--delete all outputs of a rule
delOutputsRule :: RuleNumber -> Evaluate ()
delOutputsRule rn = do
   os <- access (eGame >>> outputs)
   let toDelete = filter ((== rn) . getL oRuleNumber) os
   mapM_ (evDelOutput . _outputNumber) toDelete

--delete victory of a rule
delVictoryRule :: RuleNumber -> Evaluate ()
delVictoryRule rn = do
   vic <- access (eGame >>> victory)
   when (isJust vic && _vRuleNumber (fromJust vic) == rn) $ void $ (eGame >>> victory) ~= Nothing


-- | Show instance for Game
-- showing a game involves evaluating some parts (such as victory and outputs)
instance Show Game where
   show g@(Game gn _ rs ps vs es os _ l t _) =
      "Game Name = "      ++ show gn ++
      "\n\n Rules = "       ++ (intercalate "\n " $ map show rs) ++
      "\n\n Players = "     ++ show ps ++
      "\n\n Variables = "   ++ show vs ++
      "\n\n Events = "      ++ (intercalate "\n " $ map (displayEvent g) es) ++ "\n" ++
      "\n\n Outputs = "     ++ (intercalate "\n " $ map (displayOutput g) os) ++ "\n" ++
      "\n\n Victory = "     ++ show (getVictorious g) ++
      "\n\n currentTime = " ++ show t ++ "\n" ++
      "\n\n logs = " ++ show l ++ "\n"


displayEvent :: Game -> EventInfo -> String
displayEvent g ei@(EventInfo en rn _ _ s env) =
   "event num: " ++ (show en) ++
   ", rule num: " ++ (show rn) ++
   ", remaining signals: " ++ (show $ getRemainingSignals ei g) ++ --TODO: display also event result?
   ", envs: " ++ (show env) ++
   ", status: " ++ (show s)

displayOutput :: Game -> Output -> String
displayOutput g o@(Output on rn mpn _ s) =
   "output num: " ++ (show on) ++
   ", rule num: " ++ (show rn) ++
   ", by pn: " ++ (show mpn) ++
   ", output: " ++ (show $ evalOutput g o) ++
   ", status: " ++ (show s)

displayEvent' :: EventInfo -> EvaluateNE String
displayEvent' ei = do
   (EvalEnv _ g) <- ask
   return $ displayEvent g ei
