{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TemplateHaskell #-}

module UI.Butcher.Monadic.Internal.Core
  ( addCmdSynopsis
  , addCmdHelp
  , addCmdHelpStr
  , peekCmdDesc
  , addCmdPart
  , addCmdPartA
  , addCmdPartMany
  , addCmdPartManyA
  , addCmdPartInp
  , addCmdPartInpA
  , addCmdPartManyInp
  , addCmdPartManyInpA
  , addCmd
  , addCmdImpl
  , reorderStart
  , reorderStop
  , checkCmdParser
  , runCmdParser
  , runCmdParserExt
  , runCmdParserA
  , runCmdParserAExt
  )
where



#include "prelude.inc"
import           Control.Monad.Free
import qualified Control.Monad.Trans.MultiRWS.Strict as MultiRWSS
import qualified Control.Monad.Trans.MultiState.Strict as MultiStateS

import qualified Lens.Micro as Lens
import           Lens.Micro ( (%~), (.~) )

import qualified Text.PrettyPrint as PP
import           Text.PrettyPrint ( (<+>), ($$), ($+$) )

import           Data.HList.ContainsType

import           Data.Dynamic

import           UI.Butcher.Monadic.Internal.Types



-- general-purpose helpers
----------------------------

mModify :: MonadMultiState s m => (s -> s) -> m ()
mModify f = mGet >>= mSet . f

-- sadly, you need a degree in type inference to know when we can use
-- these operators and when it must be avoided due to type ambiguities
-- arising around s in the signatures below. That's the price of not having
-- the functional dependency in MonadMulti*T.

(.=+) :: MonadMultiState s m
      => Lens.ASetter s s a b -> b -> m ()
l .=+ b = mModify $ l .~ b

(%=+) :: MonadMultiState s m
      => Lens.ASetter s s a b -> (a -> b) -> m ()
l %=+ f = mModify (l %~ f)

-- inflateStateProxy :: (Monad m, ContainsType s ss)
--                   => p s -> StateS.StateT s m a -> MultiRWSS.MultiRWST r w ss m a
-- inflateStateProxy _ = MultiRWSS.inflateState

-- more on-topic stuff
----------------------------

-- instance IsHelpBuilder (CmdBuilder out) where
--   help s = liftF $ CmdBuilderHelp s ()
-- 
-- instance IsHelpBuilder (ParamBuilder p) where
--   help s = liftF $ ParamBuilderHelp s ()
-- 
-- instance IsHelpBuilder FlagBuilder where
--   help s = liftF $ FlagBuilderHelp s ()

-- | Add a synopsis to the command currently in scope; at top level this will
-- be the implicit top-level command.
--
-- Adding a second synopsis will overwrite a previous synopsis;
-- 'checkCmdParser' will check that you don't (accidentally) do this however.
addCmdSynopsis :: String -> CmdParser f out ()
addCmdSynopsis s = liftF $ CmdParserSynopsis s ()

-- | Add a help document to the command currently in scope; at top level this
-- will be the implicit top-level command.
--
-- Adding a second document will overwrite a previous document;
-- 'checkCmdParser' will check that you don't (accidentally) do this however.
addCmdHelp :: PP.Doc -> CmdParser f out ()
addCmdHelp s = liftF $ CmdParserHelp s ()

-- | Like @'addCmdHelp' . PP.text@
addCmdHelpStr :: String -> CmdParser f out ()
addCmdHelpStr s = liftF $ CmdParserHelp (PP.text s) ()

-- | Semi-hacky way of accessing the output CommandDesc from inside of a
-- 'CmdParser'. This is not implemented via knot-tying, i.e. the CommandDesc
-- you get is _not_ equivalent to the CommandDesc returned by 'runCmdParser'.
--
-- For best results, use this "below"
-- any 'addCmd' invocations in the current context, e.g. directly before
-- the 'addCmdImpl' invocation.
peekCmdDesc :: CmdParser f out (CommandDesc out)
peekCmdDesc = liftF $ CmdParserPeekDesc id

addCmdPart
  :: (Applicative f, Typeable p)
  => PartDesc
  -> (String -> Maybe (p, String))
  -> CmdParser f out p
addCmdPart p f = liftF $ CmdParserPart p f (\_ -> pure ()) id

addCmdPartA
  :: (Typeable p)
  => PartDesc
  -> (String -> Maybe (p, String))
  -> (p -> f ())
  -> CmdParser f out p
addCmdPartA p f a = liftF $ CmdParserPart p f a id

addCmdPartMany
  :: (Applicative f, Typeable p)
  => ManyUpperBound
  -> PartDesc
  -> (String -> Maybe (p, String))
  -> CmdParser f out [p]
addCmdPartMany b p f = liftF $ CmdParserPartMany b p f (\_ -> pure ()) id

addCmdPartManyA
  :: (Typeable p)
  => ManyUpperBound
  -> PartDesc
  -> (String -> Maybe (p, String))
  -> (p -> f ())
  -> CmdParser f out [p]
addCmdPartManyA b p f a = liftF $ CmdParserPartMany b p f a id

addCmdPartInp
  :: (Applicative f, Typeable p)
  => PartDesc
  -> (Input -> Maybe (p, Input))
  -> CmdParser f out p
addCmdPartInp p f = liftF $ CmdParserPartInp p f (\_ -> pure ()) id

addCmdPartInpA
  :: (Typeable p)
  => PartDesc
  -> (Input -> Maybe (p, Input))
  -> (p -> f ())
  -> CmdParser f out p
addCmdPartInpA p f a = liftF $ CmdParserPartInp p f a id

addCmdPartManyInp
  :: (Applicative f, Typeable p)
  => ManyUpperBound
  -> PartDesc
  -> (Input -> Maybe (p, Input))
  -> CmdParser f out [p]
addCmdPartManyInp b p f = liftF $ CmdParserPartManyInp b p f (\_ -> pure ()) id

addCmdPartManyInpA
  :: (Typeable p)
  => ManyUpperBound
  -> PartDesc
  -> (Input -> Maybe (p, Input))
  -> (p -> f ())
  -> CmdParser f out [p]
addCmdPartManyInpA b p f a = liftF $ CmdParserPartManyInp b p f a id

-- | Add a new child command in the current context.
addCmd
  :: Applicative f
  => String -- ^ command name
  -> CmdParser f out () -- ^ subcommand
  -> CmdParser f out ()
addCmd str sub = liftF $ CmdParserChild str sub (pure ()) ()

-- | Add an implementation to the current command.
addCmdImpl :: out -> CmdParser f out ()
addCmdImpl o = liftF $ CmdParserImpl o ()

-- | Best explained via example:
--
-- > do
-- >   reorderStart
-- >   bright <- addSimpleBoolFlag "" ["bright"] mempty
-- >   yellow <- addSimpleBoolFlag "" ["yellow"] mempty
-- >   reorderStop
-- >   ..
--
-- will accept any inputs "" "--bright" "--yellow" "--bright --yellow" "--yellow --bright".
--
-- This works for any flags/params, but bear in mind that the results might
-- be unexpected because params may match on any input.
--
-- Note that start/stop must occur in pairs, and it will be a runtime error
-- if you mess this up. Use 'checkCmdParser' if you want to check all parts
-- of your 'CmdParser' without providing inputs that provide 100% coverage.
reorderStart :: CmdParser f out ()
reorderStart = liftF $ CmdParserReorderStart ()

-- | See 'reorderStart'
reorderStop :: CmdParser f out ()
reorderStop = liftF $ CmdParserReorderStop ()

-- addPartHelp :: String -> CmdPartParser ()
-- addPartHelp s = liftF $ CmdPartParserHelp s ()
-- 
-- addPartParserBasic :: (String -> Maybe (p, String)) -> Maybe p -> CmdPartParser p
-- addPartParserBasic f def = liftF $ CmdPartParserCore f def id
-- 
-- addPartParserOptionalBasic :: CmdPartParser p -> CmdPartParser (Maybe p)
-- addPartParserOptionalBasic p = liftF $ CmdPartParserOptional p id

data PartGatherData f
  = forall p . Typeable p => PartGatherData
    { _pgd_id     :: Int
    , _pgd_desc   :: PartDesc
    , _pgd_parseF :: Either (String -> Maybe (p, String))
                            (Input  -> Maybe (p, Input))
    , _pgd_act    :: p -> f ()
    , _pgd_many   :: Bool
    }

type PartParsedData = Map Int [Dynamic]

data CmdDescStack = StackBottom [PartDesc]
                  | StackLayer  [PartDesc] String CmdDescStack

descStackAdd :: PartDesc -> CmdDescStack -> CmdDescStack
descStackAdd d = \case
  StackBottom l    -> StackBottom $ d:l
  StackLayer l s u -> StackLayer (d:l) s u


-- | Because butcher is evil (i.e. has constraints not encoded in the types;
-- see the README), this method can be used as a rough check that you did not
-- mess up. It traverses all possible parts of the 'CmdParser' thereby
-- ensuring that the 'CmdParser' has a valid structure.
--
-- This method also yields a _complete_ @CommandDesc@ output, where the other
-- runCmdParser* functions all traverse only a shallow structure around the
-- parts of the 'CmdParser' touched while parsing the current input.
checkCmdParser :: forall f out
                . Maybe String -- ^ top-level command name
               -> CmdParser f out () -- ^ parser to check
               -> Either String (CommandDesc ())
checkCmdParser mTopLevel cmdParser
    = (>>= final)
    $ MultiRWSS.runMultiRWSTNil
    $ MultiRWSS.withMultiStateAS (StackBottom [])
    $ MultiRWSS.withMultiStateS emptyCommandDesc
    $ processMain cmdParser
  where
    final :: (CommandDesc out, CmdDescStack)
          -> Either String (CommandDesc ())
    final (desc, stack)
      = case stack of
        StackBottom descs -> Right
                           $ descFixParentsWithTopM (mTopLevel <&> \n -> (n, emptyCommandDesc))
                           $ () <$ desc
          { _cmd_parts = reverse descs
          , _cmd_children = reverse $ _cmd_children desc
          }
        StackLayer _ _ _ -> Left "unclosed ReorderStart or GroupStart"
    processMain :: CmdParser f out ()
                -> MultiRWSS.MultiRWST '[] '[] '[CommandDesc out, CmdDescStack] (Either String) ()
    processMain = \case
      Pure x -> return x
      Free (CmdParserHelp h next) -> do
        cmd :: CommandDesc out <- mGet
        mSet $ cmd { _cmd_help = Just h }
        processMain next
      Free (CmdParserSynopsis s next) -> do
        cmd :: CommandDesc out <- mGet
        mSet $ cmd { _cmd_synopsis = Just $ PP.text s }
        processMain next
      Free (CmdParserPeekDesc nextF) -> do
        processMain $ nextF monadMisuseError
      Free (CmdParserPart desc _parseF _act nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd desc descStack
        processMain $ nextF monadMisuseError
      Free (CmdParserPartInp desc _parseF _act nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd desc descStack
        processMain $ nextF monadMisuseError
      Free (CmdParserPartMany bound desc _parseF _act nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd (wrapBoundDesc bound desc) descStack
        processMain $ nextF monadMisuseError
      Free (CmdParserPartManyInp bound desc _parseF _act nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd (wrapBoundDesc bound desc) descStack
        processMain $ nextF monadMisuseError
      Free (CmdParserChild cmdStr sub _act next) -> do
        cmd :: CommandDesc out <- mGet
        subCmd <- do
          stackCur :: CmdDescStack <- mGet
          mSet (emptyCommandDesc :: CommandDesc out)
          mSet $ StackBottom []
          processMain sub
          c <- mGet
          stackBelow <- mGet
          mSet cmd
          mSet stackCur
          subParts <- case stackBelow of
            StackBottom descs -> return $ reverse descs
            StackLayer _ _ _ -> lift $ Left "unclosed ReorderStart or GroupStart"
          return c
            { _cmd_children = reverse $ _cmd_children c
            , _cmd_parts = subParts
            }
        mSet $ cmd
          { _cmd_children = (cmdStr, subCmd) : _cmd_children cmd
          }
        processMain next
      Free (CmdParserImpl out next) -> do
        cmd_out .=+ Just out
        processMain $ next
      Free (CmdParserGrouped groupName next) -> do
        stackCur <- mGet
        mSet $ StackLayer [] groupName stackCur
        processMain $ next
      Free (CmdParserGroupEnd next) -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> do
            lift $ Left $ "butcher interface error: group end without group start"
          StackLayer _descs "" _up -> do
            lift $ Left $ "GroupEnd found, but expected ReorderStop first"
          StackLayer descs groupName up -> do
            mSet $ descStackAdd (PartRedirect groupName (PartSeq (reverse descs))) up
            processMain $ next
      Free (CmdParserReorderStop next) -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> lift $ Left $ "ReorderStop without reorderStart"
          StackLayer descs "" up -> do
            mSet $ descStackAdd (PartReorder (reverse descs)) up
          StackLayer{} -> lift $ Left $ "Found ReorderStop, but need GroupEnd first"
        processMain next
      Free (CmdParserReorderStart next) -> do
        stackCur <- mGet
        mSet $ StackLayer [] "" stackCur
        processMain next

    monadMisuseError :: a
    monadMisuseError = error "CmdParser definition error - used Monad powers where only Applicative/Arrow is allowed"

newtype PastCommandInput = PastCommandInput Input


-- | Run a @CmdParser@ on the given input, returning:
--
-- a) A @CommandDesc ()@ that accurately represents the subcommand that was
--    reached, even if parsing failed. Because this is returned always, the
--    argument is @()@ because "out" requires a successful parse.
--
-- b) Either an error or the result of a successful parse, including a proper
--    "CommandDesc out" from which an "out" can be extracted (presuming that
--    the command has an implementation).
runCmdParser
  :: Maybe String -- ^ program name to be used for the top-level @CommandDesc@
  -> Input -- ^ input to be processed
  -> CmdParser Identity out () -- ^ parser to use
  -> (CommandDesc (), Either ParsingError (CommandDesc out))
runCmdParser mTopLevel inputInitial cmdParser
  = runIdentity
  $ runCmdParserA mTopLevel inputInitial cmdParser

-- | Like 'runCmdParser', but also returning all input after the last
-- successfully parsed subcommand. E.g. for some input
-- "myprog foo bar -v --wrong" where parsing fails at "--wrong", this will
-- contain the full "-v --wrong". Useful for interactive feedback stuff.
runCmdParserExt
  :: Maybe String -- ^ program name to be used for the top-level @CommandDesc@
  -> Input -- ^ input to be processed
  -> CmdParser Identity out () -- ^ parser to use
  -> (CommandDesc (), Input, Either ParsingError (CommandDesc out))
runCmdParserExt mTopLevel inputInitial cmdParser
  = runIdentity
  $ runCmdParserAExt mTopLevel inputInitial cmdParser

-- | The Applicative-enabled version of 'runCmdParser'.
runCmdParserA :: forall f out
               . Applicative f
              => Maybe String -- ^ program name to be used for the top-level @CommandDesc@
              -> Input -- ^ input to be processed
              -> CmdParser f out () -- ^ parser to use
              -> f ( CommandDesc ()
                   , Either ParsingError (CommandDesc out)
                   )
runCmdParserA mTopLevel inputInitial cmdParser =
  (\(x, _, z) -> (x, z)) <$> runCmdParserAExt mTopLevel inputInitial cmdParser

-- | The Applicative-enabled version of 'runCmdParserExt'.
runCmdParserAExt
  :: forall f out . Applicative f
  => Maybe String -- ^ program name to be used for the top-level @CommandDesc@
  -> Input -- ^ input to be processed
  -> CmdParser f out () -- ^ parser to use
  -> f (CommandDesc (), Input, Either ParsingError (CommandDesc out))
runCmdParserAExt mTopLevel inputInitial cmdParser
    = runIdentity
    $ MultiRWSS.runMultiRWSTNil
    $ (<&> captureFinal)
    $ MultiRWSS.withMultiWriterWA
    $ MultiRWSS.withMultiStateA cmdParser
    $ MultiRWSS.withMultiStateSA (StackBottom [])
    $ MultiRWSS.withMultiStateSA inputInitial
    $ MultiRWSS.withMultiStateSA (PastCommandInput inputInitial)
    $ MultiRWSS.withMultiStateSA initialCommandDesc
    $ processMain cmdParser
  where
    initialCommandDesc = emptyCommandDesc
      { _cmd_mParent = mTopLevel <&> \n -> (n, emptyCommandDesc) }
    captureFinal
      :: ([String], (CmdDescStack, (Input, (PastCommandInput, (CommandDesc out, f())))))
      -> f (CommandDesc (), Input, Either ParsingError (CommandDesc out))
    captureFinal (errs, (descStack, (inputRest, (PastCommandInput pastCmdInput, (cmd, act))))) =
        act $> (() <$ cmd', pastCmdInput, res)
      where
        errs' = errs ++ inputErrs ++ stackErrs
        inputErrs = case inputRest of
          InputString s | all Char.isSpace s -> []
          InputString{} -> ["could not parse input/unprocessed input"]
          InputArgs [] -> []
          InputArgs{} -> ["could not parse input/unprocessed input"]
        stackErrs = case descStack of
          StackBottom{} -> []
          _ -> ["butcher interface error: unclosed group"]
        cmd' = postProcessCmd descStack cmd
        res = if null errs'
          then Right cmd'
          else Left $ ParsingError errs' inputRest
    processMain :: CmdParser f out ()
                -> MultiRWSS.MultiRWS
                     '[]
                     '[[String]]
                     '[CommandDesc out, PastCommandInput, Input, CmdDescStack, CmdParser f out ()]
                     (f ())
    processMain = \case
      Pure () -> return $ pure $ ()
      Free (CmdParserHelp h next) -> do
        cmd :: CommandDesc out <- mGet
        mSet $ cmd { _cmd_help = Just h }
        processMain next
      Free (CmdParserSynopsis s next) -> do
        cmd :: CommandDesc out <- mGet
        mSet $ cmd { _cmd_synopsis = Just $ PP.text s }
        processMain next
      Free (CmdParserPeekDesc nextF) -> do
        parser <- mGet
        -- partialDesc :: CommandDesc out <- mGet
        -- partialStack :: CmdDescStack <- mGet
        -- run the rest without affecting the actual stack
        -- to retrieve the complete cmddesc.
        cmdCur :: CommandDesc out <- mGet
        let (cmd :: CommandDesc out, stack)
              = runIdentity
              $ MultiRWSS.runMultiRWSTNil
              $ MultiRWSS.withMultiStateSA emptyCommandDesc
                  { _cmd_mParent = _cmd_mParent cmdCur } -- partialDesc
              $ MultiRWSS.withMultiStateS (StackBottom []) -- partialStack
              $ iterM processCmdShallow $ parser
        processMain $ nextF $ postProcessCmd stack cmd
      Free (CmdParserPart desc parseF actF nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd desc descStack
        input <- mGet
        case input of
          InputString str -> case parseF str of
            Just (x, rest) -> do
              mSet $ InputString rest
              actRest <- processMain $ nextF x
              return $ actF x *> actRest
            Nothing -> do
              mTell ["could not parse " ++ getPartSeqDescPositionName desc]
              processMain $ nextF monadMisuseError
          InputArgs (str:strr) -> case parseF str of
            Just (x, "") -> do
              mSet $ InputArgs strr
              actRest <- processMain $ nextF x
              return $ actF x *> actRest
            _ -> do
              mTell ["could not parse " ++ getPartSeqDescPositionName desc]
              processMain $ nextF monadMisuseError
          InputArgs [] -> do
            mTell ["could not parse " ++ getPartSeqDescPositionName desc]
            processMain $ nextF monadMisuseError
      Free (CmdParserPartInp desc parseF actF nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd desc descStack
        input <- mGet
        case parseF input of
          Just (x, rest) -> do
            mSet $ rest
            actRest <- processMain $ nextF x
            return $ actF x *> actRest
          Nothing -> do
            mTell ["could not parse " ++ getPartSeqDescPositionName desc]
            processMain $ nextF monadMisuseError
      Free (CmdParserPartMany bound desc parseF actF nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd (wrapBoundDesc bound desc) descStack
        let proc = do
              dropSpaces
              input <- mGet
              case input of
                InputString str -> case parseF str of
                  Just (x, r) -> do
                    mSet $ InputString r
                    xr <- proc
                    return $ x:xr
                  Nothing -> return []
                InputArgs (str:strr) -> case parseF str of
                  Just (x, "") -> do
                    mSet $ InputArgs strr
                    xr <- proc
                    return $ x:xr
                  _ -> return []
                InputArgs [] -> return []
        r <- proc
        let act = traverse actF r
        (act *>) <$> processMain (nextF $ r)
      Free (CmdParserPartManyInp bound desc parseF actF nextF) -> do
        do
          descStack <- mGet
          mSet $ descStackAdd (wrapBoundDesc bound desc) descStack
        let proc = do
              dropSpaces
              input <- mGet
              case parseF input of
                Just (x, r) -> do
                  mSet $ r
                  xr <- proc
                  return $ x:xr
                Nothing -> return []
        r <- proc
        let act = traverse actF r
        (act *>) <$> processMain (nextF $ r)
      f@(Free (CmdParserChild cmdStr sub act next)) -> do
        dropSpaces
        input <- mGet
        let
          mRest = case input of
            InputString str | cmdStr == str ->
              Just $ InputString ""
            InputString str | (cmdStr++" ") `isPrefixOf` str ->
              Just $ InputString $ drop (length cmdStr + 1) str
            InputArgs (str:strr) | cmdStr == str ->
              Just $ InputArgs strr
            _ -> Nothing
        case mRest of
          Nothing -> do
            cmd :: CommandDesc out <- mGet
            let (subCmd, subStack)
                  = runIdentity
                  $ MultiRWSS.runMultiRWSTNil
                  $ MultiRWSS.withMultiStateSA (emptyCommandDesc :: CommandDesc out)
                  $ MultiRWSS.withMultiStateS (StackBottom [])
                  $ iterM processCmdShallow sub
            mSet $ cmd
              { _cmd_children = (cmdStr, postProcessCmd subStack subCmd)
                              : _cmd_children cmd
              }
            processMain next
          Just rest -> do
            iterM processCmdShallow f
            cmd <- do
              c :: CommandDesc out <- mGet
              prevStack :: CmdDescStack <- mGet
              return $ postProcessCmd prevStack c
            mSet $ rest
            mSet $ PastCommandInput rest
            mSet $ (emptyCommandDesc :: CommandDesc out)
              { _cmd_mParent = Just (cmdStr, cmd)
              }
            mSet $ sub
            mSet $ StackBottom []
            subAct <- processMain sub
            return $ act *> subAct
      Free (CmdParserImpl out next) -> do
        cmd_out .=+ Just out
        processMain $ next
      Free (CmdParserGrouped groupName next) -> do
        stackCur <- mGet
        mSet $ StackLayer [] groupName stackCur
        processMain $ next
      Free (CmdParserGroupEnd next) -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> do
            mTell $ ["butcher interface error: group end without group start"]
            return $ pure () -- hard abort should be fine for this case.
          StackLayer descs groupName up -> do
            mSet $ descStackAdd (PartRedirect groupName (PartSeq (reverse descs))) up
            processMain $ next
      Free (CmdParserReorderStop next) -> do
        mTell $ ["butcher interface error: reorder stop without reorder start"]
        processMain next
      Free (CmdParserReorderStart next) -> do
        reorderData <- MultiRWSS.withMultiStateA (1::Int)
                  $ MultiRWSS.withMultiWriterW
                  $ iterM reorderPartGather $ next
        let
          reorderMapInit :: Map Int (PartGatherData f)
          reorderMapInit = Map.fromList $ reorderData <&> \d -> (_pgd_id d, d)
          tryParsePartData :: Input -> PartGatherData f -> First (Int, Dynamic, Input, Bool, f ())
          tryParsePartData input (PartGatherData pid _ pfe act allowMany) =
            First [ (pid, toDyn r, rest, allowMany, act r)
                  | (r, rest) <- case pfe of
                      Left pfStr -> case input of
                        InputString str -> case pfStr str of
                          Just (x, r) | r/=str -> Just (x, InputString r)
                          _ -> Nothing
                        InputArgs (str:strr) -> case pfStr str of
                          Just (x, "") -> Just (x, InputArgs strr)
                          _ -> Nothing
                        InputArgs [] -> Nothing
                      Right pfInp -> case pfInp input of
                        Just (x, r) | r/=input -> Just (x, r)
                        _ -> Nothing
                  ]
          parseLoop = do
            input <- mGet
            m :: Map Int (PartGatherData f) <- mGet
            case getFirst $ Data.Foldable.foldMap (tryParsePartData input) m of
                       -- i will be angry if foldMap ever decides to not fold
                       -- in order of keys.
              Nothing -> return $ pure ()
              Just (pid, x, rest, more, act) -> do
                mSet rest
                mModify $ Map.insertWith (++) pid [x]
                when (not more) $ do
                  mSet $ Map.delete pid m
                actRest <- parseLoop
                return $ act *> actRest
        (finalMap, (fr, acts)) <- MultiRWSS.withMultiStateSA (Map.empty :: PartParsedData)
                                $ MultiRWSS.withMultiStateA reorderMapInit
                                $ do
          acts <- parseLoop -- filling the map
          stackCur <- mGet
          mSet $ StackLayer [] "" stackCur
          fr <- MultiRWSS.withMultiStateA (1::Int) $ processParsedParts next
          return (fr, acts)
        -- we check that all data placed in the map has been consumed while
        -- running the parts for which we collected the parseresults.
        -- there can only be any rest if the collection of parts changed
        -- between the reorderPartGather traversal and the processParsedParts
        -- consumption.
        if Map.null finalMap
          then do
            actRest <- processMain fr
            return $ acts *> actRest
          else monadMisuseError

    reorderPartGather
      :: ( MonadMultiState Int m
         , MonadMultiWriter [PartGatherData f] m
         , MonadMultiWriter [String] m
         )
      => CmdParserF f out (m ())
      -> m ()
    reorderPartGather = \case
      -- TODO: why do PartGatherData contain desc?
      CmdParserPart desc parseF actF nextF -> do
        pid <- mGet
        mSet $ pid + 1
        mTell [PartGatherData pid desc (Left parseF) actF False]
        nextF $ monadMisuseError
      CmdParserPartInp desc parseF actF nextF -> do
        pid <- mGet
        mSet $ pid + 1
        mTell [PartGatherData pid desc (Right parseF) actF False]
        nextF $ monadMisuseError
      CmdParserPartMany _ desc parseF actF nextF -> do
        pid <- mGet
        mSet $ pid + 1
        mTell [PartGatherData pid desc (Left parseF) actF True]
        nextF $ monadMisuseError
      CmdParserPartManyInp _ desc parseF actF nextF -> do
        pid <- mGet
        mSet $ pid + 1
        mTell [PartGatherData pid desc (Right parseF) actF True]
        nextF $ monadMisuseError
      CmdParserReorderStop _next -> do
        return ()
      CmdParserHelp{}         -> restCase
      CmdParserSynopsis{}     -> restCase
      CmdParserPeekDesc{}     -> restCase
      CmdParserChild{}        -> restCase
      CmdParserImpl{}         -> restCase
      CmdParserReorderStart{} -> restCase
      CmdParserGrouped{}      -> restCase
      CmdParserGroupEnd{}     -> restCase
      where
        restCase = do
          mTell ["Did not find expected ReorderStop after the reordered parts"]
          return ()

    processParsedParts
      :: forall m r w s m0 a
       . ( MonadMultiState Int m
         , MonadMultiState PartParsedData m
         , MonadMultiState (Map Int (PartGatherData f)) m
         , MonadMultiState Input m
         , MonadMultiState (CommandDesc out) m
         , MonadMultiWriter [[Char]] m
         , m ~ MultiRWSS.MultiRWST r w s m0
         , ContainsType (CmdParser f out ()) s
         , ContainsType CmdDescStack s
         , Monad m0
         )
      => CmdParser f out a
      -> m (CmdParser f out a)
    processParsedParts = \case
      Free (CmdParserPart    desc _ _ (nextF :: p -> CmdParser f out a)) -> part desc nextF
      Free (CmdParserPartInp desc _ _ (nextF :: p -> CmdParser f out a)) -> part desc nextF
      Free (CmdParserPartMany bound desc _ _ nextF) -> partMany bound desc nextF
      Free (CmdParserPartManyInp bound desc _ _ nextF) -> partMany bound desc nextF
      Free (CmdParserReorderStop next) -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> do
            mTell ["unexpected stackBottom"]
          StackLayer descs _ up -> do
            mSet $ descStackAdd (PartReorder (reverse descs)) up
        return next
      Free (CmdParserGrouped groupName next) -> do
        stackCur <- mGet
        mSet $ StackLayer [] groupName stackCur
        processParsedParts $ next
      Free (CmdParserGroupEnd next) -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> do
            mTell $ ["butcher interface error: group end without group start"]
            return $ next -- hard abort should be fine for this case.
          StackLayer descs groupName up -> do
            mSet $ descStackAdd (PartRedirect groupName (PartSeq (reverse descs))) up
            processParsedParts $ next        
      Pure x -> return $ return $ x
      f -> do
        mTell ["Did not find expected ReorderStop after the reordered parts"]
        return f
      where
        part
          :: forall p
           . Typeable p
          => PartDesc
          -> (p -> CmdParser f out a)
          -> m (CmdParser f out a)
        part desc nextF = do
          do
            stackCur <- mGet
            mSet $ descStackAdd desc stackCur
          pid <- mGet
          mSet $ pid + 1
          parsedMap :: PartParsedData <- mGet
          mSet $ Map.delete pid parsedMap
          partMap :: Map Int (PartGatherData f) <- mGet
          input :: Input <- mGet
          let errorResult = do
                mTell ["could not parse expected input "
                    ++ getPartSeqDescPositionName desc
                    ++ " with remaining input: "
                    ++ show input
                    ]
                failureCurrentShallowRerun
                return $ return $ monadMisuseError -- so ugly.
                     -- should be correct nonetheless.
              continueOrMisuse :: Maybe p -> m (CmdParser f out a)
              continueOrMisuse = maybe monadMisuseError
                                       (processParsedParts . nextF)
          case Map.lookup pid parsedMap of
            Nothing -> case Map.lookup pid partMap of
              Nothing -> monadMisuseError -- it would still be in the map
                                          -- if it never had been successfully
                                          -- parsed, as indicicated by the
                                          -- previous parsedMap Nothing lookup.
              Just (PartGatherData _ _ pfe _ _) -> case pfe of
                Left pf -> case pf "" of
                  Nothing -> errorResult
                  Just (dx, _) -> continueOrMisuse $ cast dx
                Right pf -> case pf (InputArgs []) of
                  Nothing -> errorResult
                  Just (dx, _) -> continueOrMisuse $ cast dx
            Just [dx] -> continueOrMisuse $ fromDynamic dx
            Just _ -> monadMisuseError
        partMany
          :: Typeable p
          => ManyUpperBound
          -> PartDesc
          -> ([p] -> CmdParser f out a)
          -> m (CmdParser f out a)
        partMany bound desc nextF = do
          do
            stackCur <- mGet
            mSet $ descStackAdd (wrapBoundDesc bound desc) stackCur
          pid <- mGet
          mSet $ pid + 1
          m :: PartParsedData <- mGet
          mSet $ Map.delete pid m
          let partDyns = case Map.lookup pid m of
                Nothing -> []
                Just r -> r
          case mapM fromDynamic partDyns of
            Nothing -> monadMisuseError
            Just xs -> processParsedParts $ nextF xs

    -- this does no error reporting at all.
    -- user needs to use check for that purpose instead.
    processCmdShallow :: ( MonadMultiState (CommandDesc out) m
                         , MonadMultiState CmdDescStack m
                         )
                      => CmdParserF f out (m ())
                      -> m ()
    processCmdShallow = \case
      CmdParserHelp h next -> do
        cmd :: CommandDesc out <- mGet
        mSet $ cmd { _cmd_help = Just h }
        next
      CmdParserSynopsis s next -> do
        cmd :: CommandDesc out <- mGet
        mSet $ cmd { _cmd_synopsis = Just $ PP.text s }
        next
      CmdParserPeekDesc nextF -> do
        mGet >>= nextF
      CmdParserPart desc _parseF _act nextF -> do
        do
          stackCur <- mGet
          mSet $ descStackAdd desc stackCur
        nextF monadMisuseError
      CmdParserPartInp desc _parseF _act nextF -> do
        do
          stackCur <- mGet
          mSet $ descStackAdd desc stackCur
        nextF monadMisuseError
      CmdParserPartMany bound desc _parseF _act nextF -> do
        do
          stackCur <- mGet
          mSet $ descStackAdd (wrapBoundDesc bound desc) stackCur
        nextF monadMisuseError
      CmdParserPartManyInp bound desc _parseF _act nextF -> do
        do
          stackCur <- mGet
          mSet $ descStackAdd (wrapBoundDesc bound desc) stackCur
        nextF monadMisuseError
      CmdParserChild cmdStr _sub _act next -> do
        cmd_children %=+ ((cmdStr, emptyCommandDesc :: CommandDesc out):)
        next
      CmdParserImpl out     next -> do
        cmd_out .=+ Just out
        next
      CmdParserGrouped groupName next -> do
        stackCur <- mGet
        mSet $ StackLayer [] groupName stackCur
        next
      CmdParserGroupEnd next -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> do
            return ()
          StackLayer _descs "" _up -> do
            return ()
          StackLayer descs groupName up -> do
            mSet $ descStackAdd (PartRedirect groupName (PartSeq (reverse descs))) up
            next
      CmdParserReorderStop next -> do
        stackCur <- mGet
        case stackCur of
          StackBottom{} -> return ()
          StackLayer descs "" up -> do
            mSet $ descStackAdd (PartReorder (reverse descs)) up
          StackLayer{} -> return ()
        next
      CmdParserReorderStart next -> do
        stackCur <- mGet
        mSet $ StackLayer [] "" stackCur
        next

    failureCurrentShallowRerun
      :: ( m ~ MultiRWSS.MultiRWST r w s m0
         , MonadMultiState (CmdParser f out ()) m
         , MonadMultiState (CommandDesc out) m
         , ContainsType CmdDescStack s
         , Monad m0
         )
      => m ()
    failureCurrentShallowRerun = do
      parser <- mGet
      cmd :: CommandDesc out 
        <- MultiRWSS.withMultiStateS emptyCommandDesc
         $ iterM processCmdShallow parser
      mSet cmd

    postProcessCmd :: CmdDescStack -> CommandDesc out -> CommandDesc out
    postProcessCmd descStack cmd
      = descFixParents
      $ cmd { _cmd_parts    = case descStack of
                StackBottom l -> reverse l
                StackLayer{} -> []
            , _cmd_children = reverse $ _cmd_children cmd
            }

    monadMisuseError :: a
    monadMisuseError = error "CmdParser definition error - used Monad powers where only Applicative/Arrow is allowed"

    
    getPartSeqDescPositionName :: PartDesc -> String
    getPartSeqDescPositionName = \case
      PartLiteral    s -> s
      PartVariable   s -> s
      PartOptional ds' -> f ds'
      PartAlts alts    -> f $ head alts -- this is not optimal, but probably
                                     -- does not matter.
      PartDefault  _ d -> f d
      PartSuggestion _ d -> f d
      PartRedirect s _ -> s
      PartMany      ds -> f ds
      PartWithHelp _ d -> f d
      PartSeq       ds -> List.unwords $ f <$> ds
      PartReorder   ds -> List.unwords $ f <$> ds

      where
        f = getPartSeqDescPositionName

    dropSpaces :: MonadMultiState Input m => m ()
    dropSpaces = do
      inp <- mGet
      case inp of
        InputString s -> mSet $ InputString $ dropWhile Char.isSpace s
        InputArgs{}   -> return ()


-- cmdActionPartial :: CommandDesc out -> Either String out
-- cmdActionPartial = maybe (Left err) Right . _cmd_out
--   where
--     err = "command is missing implementation!"
--  
-- cmdAction :: CmdParser out () -> String -> Either String out
-- cmdAction b s = case runCmdParser Nothing s b of
--   (_, Right cmd)                     -> cmdActionPartial cmd
--   (_, Left (ParsingError (out:_) _)) -> Left $ out
--   _ -> error "whoops"
-- 
-- cmdActionRun :: (CommandDesc () -> ParsingError -> out)
--              -> CmdParser out ()
--              -> String
--              -> out
-- cmdActionRun f p s = case runCmdParser Nothing s p of
--   (cmd, Right out) -> case _cmd_out out of
--     Just o -> o
--     Nothing -> f cmd (ParsingError ["command is missing implementation!"] "")
--   (cmd, Left err) -> f cmd err

wrapBoundDesc :: ManyUpperBound -> PartDesc -> PartDesc
wrapBoundDesc ManyUpperBound1 = PartOptional
wrapBoundDesc ManyUpperBoundN = PartMany


descFixParents :: CommandDesc a -> CommandDesc a
descFixParents = descFixParentsWithTopM Nothing

-- descFixParentsWithTop :: String -> CommandDesc a -> CommandDesc a
-- descFixParentsWithTop s = descFixParentsWithTopM (Just (s, emptyCommandDesc))

descFixParentsWithTopM :: Maybe (String, CommandDesc a) -> CommandDesc a -> CommandDesc a
descFixParentsWithTopM mTop topDesc = Data.Function.fix $ \fixed -> topDesc
        { _cmd_mParent  = goUp fixed <$> (mTop <|> _cmd_mParent topDesc)
        , _cmd_children = _cmd_children topDesc <&> goDown fixed
        }
  where
    goUp :: CommandDesc a -> (String, CommandDesc a) -> (String, CommandDesc a)
    goUp child (childName, parent) = (,) childName $ Data.Function.fix $ \fixed -> parent
      { _cmd_mParent = goUp fixed <$> _cmd_mParent parent
      , _cmd_children = _cmd_children parent <&> \(n, c) -> if n==childName
          then (n, child)
          else (n, c)
      }
    goDown :: CommandDesc a -> (String, CommandDesc a) -> (String, CommandDesc a)
    goDown parent (childName, child) = (,) childName $ Data.Function.fix $ \fixed -> child
      { _cmd_mParent = Just (childName, parent)
      , _cmd_children = _cmd_children child <&> goDown fixed
      }


_tooLongText :: Int -- max length
            -> String -- alternative if actual length is bigger than max.
            -> String -- text to print, if length is fine.
            -> PP.Doc
_tooLongText i alt s = PP.text $ Bool.bool alt s $ null $ drop i s