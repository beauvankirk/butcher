{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MonadComprehensions #-}
{-# LANGUAGE MultiWayIf #-}

module UI.Butcher.Monadic.Pretty
  ( ppUsage
  , ppUsageAt
  , ppHelpShallow
  , ppPartDescUsage
  , ppPartDescHeader
  )
where



#include "prelude.inc"
import           Control.Monad.Free
import qualified Control.Monad.Trans.MultiRWS.Strict as MultiRWSS
import qualified Control.Monad.Trans.MultiState.Strict as MultiStateS
import           Data.Unique (Unique)
import qualified System.Unsafe as Unsafe

import qualified Control.Lens.TH as LensTH
import qualified Control.Lens as Lens
import           Control.Lens ( (.=), (%=), (%~), (.~) )

import qualified Text.PrettyPrint as PP
import           Text.PrettyPrint ( (<+>), ($$), ($+$) )

import           Data.HList.ContainsType

import           Data.Dynamic

import           UI.Butcher.Monadic.Types
import           UI.Butcher.Monadic.Core



ppUsage :: CommandDesc a
        -> PP.Doc
ppUsage (CommandDesc mParent _help _syn parts out children) =
    pparents mParent <+> PP.fsep (partDocs ++ [subsDoc])
  where
    pparents :: Maybe (String, CommandDesc out) -> PP.Doc
    pparents Nothing = PP.empty
    pparents (Just (n, cd)) = pparents (_cmd_mParent cd) <+> PP.text n
    partDocs = parts <&> ppPartDescUsage
    subsDoc = case out of
      _ | null children -> PP.empty -- TODO: remove debug
      Nothing           -> PP.parens   $ subDoc
      Just{}            -> PP.brackets $ subDoc
    subDoc = PP.fcat $ PP.punctuate (PP.text " | ") $ children <&> \(n, _) ->
      PP.text n

ppUsageAt :: [String] -- (sub)command sequence
          -> CommandDesc a
          -> Maybe PP.Doc
ppUsageAt strings desc =
  case strings of
    [] -> Just $ ppUsage desc
    (s:sr) -> find ((s==) . fst) (_cmd_children desc) >>= ppUsageAt sr . snd

ppHelpShallow :: CommandDesc a
              -> PP.Doc
ppHelpShallow desc@(CommandDesc mParent syn help parts _out _children) =
        nameSection
    $+$ usageSection
    $+$ descriptionSection
    $+$ partsSection
    $+$ PP.text ""
  where
    nameSection = case mParent of
      Nothing -> PP.empty
      Just{} ->
            PP.text "NAME"
        $+$ PP.text ""
        $+$ PP.nest 2 (case syn of
                        Nothing -> pparents mParent
                        Just s ->  pparents mParent <+> PP.text "-" <+> s)
        $+$ PP.text ""
    pparents :: Maybe (String, CommandDesc out) -> PP.Doc
    pparents Nothing = PP.empty
    pparents (Just (n, cd)) = pparents (_cmd_mParent cd) PP.<+> PP.text n
    usageSection =
            PP.text "USAGE"
        $+$ PP.text ""
        $+$ PP.nest 2 (ppUsage desc)
    descriptionSection = case help of
      Nothing -> PP.empty
      Just h ->
            PP.text ""
        $+$ PP.text "DESCRIPTION"
        $+$ PP.text ""
        $+$ PP.nest 2 h
    partsSection = if null partsTuples then PP.empty else
            PP.text ""
        $+$ PP.text "ARGUMENTS"
        $+$ PP.text ""
        $+$ PP.nest 2 (PP.vcat partsTuples)
    partsTuples :: [PP.Doc]
    partsTuples = parts >>= go
      where
        go = \case
          PartLiteral{} -> []
          PartVariable{} -> []
          PartOptional p -> go p
          PartAlts ps -> ps >>= go
          PartSeq  ps -> ps >>= go
          PartDefault _ p -> go p
          PartRedirect s p -> [PP.text s $$ PP.nest 20 (ppPartDescUsage p)]
                           ++ (PP.nest 2 <$> go p)
          PartReorder ps -> ps >>= go
          PartMany p -> go p
          PartWithHelp doc p -> [ppPartDescHeader p $$ PP.nest 20 doc]
                             ++ go p

ppPartDescUsage :: PartDesc -> PP.Doc
ppPartDescUsage = \case
    PartLiteral s    -> PP.text s
    PartVariable s   -> PP.text s
    PartOptional p   -> PP.brackets $ rec p
    PartAlts ps      -> PP.fcat $ PP.punctuate (PP.text ",") $ rec <$> ps
    PartSeq ps       -> PP.fsep $ rec <$> ps
    PartDefault _ p  -> PP.brackets $ rec p
    PartRedirect s _ -> PP.text s
    PartMany p       -> rec p <> PP.text "+"
    PartWithHelp _ p -> rec p
    PartReorder ps   ->
      let flags = [d | PartMany d <- ps]
          params = filter (\case PartMany{} -> False; _ -> True) ps
      in     PP.brackets (PP.fsep $ rec <$> flags)
         <+> PP.fsep (rec <$> params)
  where
    rec = ppPartDescUsage

ppPartDescHeader :: PartDesc -> PP.Doc
ppPartDescHeader = \case
    PartLiteral    s -> PP.text s
    PartVariable   s -> PP.text s
    PartOptional ds' -> rec ds'
    PartAlts alts    -> PP.hcat $ List.intersperse (PP.text ",") $ rec <$> alts
    PartDefault  _ d -> rec d
    PartRedirect s _ -> PP.text s
    PartMany      ds -> rec ds
    PartWithHelp _ d -> rec d
    PartSeq       ds -> PP.hsep $ rec <$> ds
    PartReorder   ds -> PP.vcat $ rec <$> ds
  where
    rec = ppPartDescHeader