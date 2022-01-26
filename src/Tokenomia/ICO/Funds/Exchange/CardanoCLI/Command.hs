{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE NamedFieldPuns #-}
module Tokenomia.ICO.Funds.Exchange.CardanoCLI.Command
    ( Command (..)) where
import           Plutus.V1.Ledger.Ada
import           Ledger ( Slot(..) )

import           Tokenomia.Wallet.UTxO

import           Tokenomia.Common.Address
import           Tokenomia.ICO.Balanceable
import           Tokenomia.Common.Token
import           Prelude hiding (round,print)





data Command
    = RefundBecauseTokensSoldOut
        { paybackAddress :: Address
        , source :: WalletUTxO
        , refundAmount :: Ada
        , receivedAt :: Slot}
    | MoveToNextRoundBecauseTokensSoldOut
        { source :: WalletUTxO
        , nextRoundExchangeAddress :: Address
        , datumFile :: FilePath
        , moveAmount :: Ada
        , receivedAt :: Slot}
    | ExchangeAndPartiallyRefund
        { paybackAddress :: Address
        , source :: WalletUTxO
        , collectedAmount :: Ada
        , refundAmount :: Ada
        , tokens :: Token
        , receivedAt :: Slot}
    | ExchangeAndPartiallyMoveToNextRound
        { source :: WalletUTxO
        , nextRoundExchangeAddress :: Address
        , paybackAddress :: Address
        , collectedAmount :: Ada
        , moveAmount :: Ada
        , tokens :: Token
        , datumFile :: FilePath
        , receivedAt :: Slot}
    | Exchange
        { paybackAddress :: Address
        , source :: WalletUTxO
        , collectedAmount :: Ada
        , tokens :: Token
        , receivedAt :: Slot} deriving (Eq)

instance Ord Command where
    compare x y = case compare (receivedAt x) (receivedAt y) of
      LT -> LT
      EQ -> compare (source x) (source y)
      GT -> GT

instance Show Command where
    show RefundBecauseTokensSoldOut { ..}
        =  "\n Command : RefundBecauseTokensSoldOut "
        <> "\n   | received at : " <> show (getSlot receivedAt)
        <> "\n   | source  : " <> show (getAdas source)
        <> "\n   | refund  : " <> show refundAmount
    show MoveToNextRoundBecauseTokensSoldOut { ..}
        =  "\n Command : MoveToNextRoundBecauseTokensSoldOut "
        <> "\n   | received at : " <> show (getSlot receivedAt)
        <> "\n   | source      : " <> show (getAdas source)
        <> "\n   | move        : " <> show moveAmount
    show ExchangeAndPartiallyRefund { ..}
        =  "\n Command : ExchangeAndPartiallyRefund "
        <> "\n   | received at : " <> show (getSlot receivedAt)
        <> "\n   | source      : " <> show (getAdas source)
        <> "\n   | refund      : " <> show refundAmount
        <> "\n   | collected   : " <> show collectedAmount
        <> "\n   | token       : " <> show tokens
    show ExchangeAndPartiallyMoveToNextRound { ..}
        =  "\n Command : ExchangeAndPartiallyMoveToNextRound "
        <> "\n   | received at : " <> show (getSlot receivedAt)
        <> "\n   | source      : " <> show (getAdas source)
        <> "\n   | move        : " <> show moveAmount
        <> "\n   | collected   : " <> show collectedAmount
        <> "\n   | token       : " <> show tokens
    show Exchange {..}
        =  "\n Command : Exchange "
        <> "\n   | received at : " <> show (getSlot receivedAt)
        <> "\n   | source      : " <> show (getAdas source)
        <> "\n   | collected   : " <> show collectedAmount
        <> "\n   | token       : " <> show tokens

instance AdaBalanceable Command where 
    adaBalance RefundBecauseTokensSoldOut {..} = getAdas source - refundAmount
    adaBalance MoveToNextRoundBecauseTokensSoldOut {..} = getAdas source - moveAmount
    adaBalance Exchange {tokens = Token {minimumAdaRequired},..}                    = getAdas source - collectedAmount - minimumAdaRequired
    adaBalance ExchangeAndPartiallyRefund {tokens = Token {minimumAdaRequired},..}  = getAdas source - collectedAmount - minimumAdaRequired - refundAmount
    adaBalance ExchangeAndPartiallyMoveToNextRound {tokens = Token {minimumAdaRequired},..}  = getAdas source - collectedAmount - minimumAdaRequired - moveAmount

instance TokenBalanceable Command where 
    tokenBalance = getTokenAmount


getTokenAmount :: Command -> Integer    
getTokenAmount RefundBecauseTokensSoldOut {} = 0
getTokenAmount MoveToNextRoundBecauseTokensSoldOut {} = 0
getTokenAmount Exchange  {tokens = Token {..}} = amount
getTokenAmount ExchangeAndPartiallyRefund  {tokens = Token {..}} = amount
getTokenAmount ExchangeAndPartiallyMoveToNextRound  {tokens = Token {..}} = amount