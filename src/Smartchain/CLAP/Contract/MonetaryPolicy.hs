{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE MonoLocalBinds     #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE ViewPatterns       #-}

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NumericUnderscores #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}

module Smartchain.CLAP.Contract.MonetaryPolicy(
    MonetaryPolicySchema
    , CLAPMonetaryPolicyError(..)
    , AsCLAPMonetaryPolicyError(..)
    , Params (..)
    , mkMonetaryPolicyScript
    , mintContract
    , burnContract
    ) where


import Control.Lens ( makeClassyPrisms, review )
import PlutusTx.Prelude
    ( (>>),
      (>>=),
      (<),
      Bool(..),
      (.),
      Eq((==)),
      Applicative(pure),
      (&&),
      (||),
      ($),
      traceIfFalse )

import Plutus.Contract as Contract
    ( awaitTxConfirmed,
      submitTxConstraintsWith,
      mapError,
      utxosAt,
      Endpoint,
      type (.\/),
      Contract,
      AsContractError(_ContractError),
      ContractError )
import           Plutus.Contract.Wallet (getUnspentOutput)

import Ledger
    ( TxOutRef(..),
      scriptCurrencySymbol,
      txId,
      pubKeyHashAddress,
      mkMintingPolicyScript,
      PubKeyHash,
      MintingPolicy,
      AssetClass,
      CurrencySymbol,
      Value )                 
import qualified Ledger.Constraints     as Constraints
import qualified Ledger.Contexts        as V
import PlutusTx ( BuiltinData, applyCode, liftCode, compile )

import qualified Ledger.Typed.Scripts   as Scripts
import           Ledger.Value           (singleton,TokenName (..),assetClass,assetClassValue, valueOf)

import           Data.Aeson             (FromJSON, ToJSON)
import           GHC.Generics           (Generic)
import           Prelude                (Semigroup (..),Integer)
import qualified Prelude                as Haskell
import qualified PlutusTx
import PlutusTx.Builtins.Internal ()



data Params = Params
  { txOutRef     :: TxOutRef
  , amount    :: Integer
  , tokenName :: TokenName }
  deriving stock (Generic, Haskell.Show, Haskell.Eq)
  deriving anyclass (ToJSON, FromJSON)

PlutusTx.makeLift ''Params

{-# INLINABLE clapAssetClass #-}
clapAssetClass :: CurrencySymbol  -> AssetClass
clapAssetClass clapPolicyHash = assetClass clapPolicyHash (TokenName "CLAP")

{-# INLINABLE clapTotalSupply #-}
clapTotalSupply :: CurrencySymbol -> Value
clapTotalSupply clapPolicyHash
    = assetClassValue
        (clapAssetClass clapPolicyHash )
        1_000_000_000_000

-- /////////////////
-- // On-Chain Part
-- /////////////////


mkMonetaryPolicyScript :: Params -> MintingPolicy
mkMonetaryPolicyScript param = mkMintingPolicyScript $
    $$(PlutusTx.compile [|| \c -> Scripts.wrapMintingPolicy (monetaryPolicy c) ||])
        `PlutusTx.applyCode`
            PlutusTx.liftCode param
    
{-# INLINABLE monetaryPolicy #-}
monetaryPolicy :: Params -> BuiltinData -> V.ScriptContext -> Bool
monetaryPolicy a b c =  burningPolicy a b c || mintingPolicy a b c

{-# INLINABLE mintingPolicy #-}
mintingPolicy :: Params -> BuiltinData -> V.ScriptContext -> Bool
mintingPolicy Params{ txOutRef = (TxOutRef refHash refIdx),..} _ ctx@V.ScriptContext{V.scriptContextTxInfo=txinfo}
    =  traceIfFalse "E1" {- Value minted different from expected (10^9 CLAPs)" -}
        (singleton (V.ownCurrencySymbol ctx) tokenName  amount == V.txInfoMint txinfo)
    && traceIfFalse "E2" {- Pending transaction does not spend the designated transaction output (necessary for one-time minting Policy) -}
        (V.spendsOutput txinfo refHash refIdx)

{-# INLINABLE burningPolicy #-}
burningPolicy :: Params -> BuiltinData -> V.ScriptContext -> Bool
burningPolicy Params {tokenName} _ context@V.ScriptContext{V.scriptContextTxInfo=txinfo}
    = valueOf (V.txInfoMint txinfo) (V.ownCurrencySymbol context) tokenName < 0



-- /////////////////
-- // Off-Chain Part
-- /////////////////

type Amount = Integer
type MonetaryPolicySchema
    = Endpoint   "Mint" ()
    .\/ Endpoint "Burn" (CurrencySymbol,Amount)

newtype CLAPMonetaryPolicyError =
    CLAPMonetaryPolicyError ContractError
    deriving stock (Haskell.Eq, Haskell.Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

makeClassyPrisms ''CLAPMonetaryPolicyError

instance AsContractError CLAPMonetaryPolicyError where
    _ContractError = _CLAPMonetaryPolicyError


burnContract
    :: forall w s e.
    ( AsCLAPMonetaryPolicyError e
    )
    => PubKeyHash
    -> TxOutRef
    -> TokenName
    -> Integer
    -> Contract w s e ()
burnContract burnerPK txOutRef tokenName amount =
    mapError (review _CLAPMonetaryPolicyError) $ do
    let monetaryPolicyParams = Params {..}
        policyHash = (scriptCurrencySymbol . mkMonetaryPolicyScript) monetaryPolicyParams
        monetaryPolicyScript = mkMonetaryPolicyScript monetaryPolicyParams
    utxosInBurnerWallet <- Contract.utxosAt (pubKeyHashAddress burnerPK)
    submitTxConstraintsWith
            @Scripts.Any
            (Constraints.mintingPolicy monetaryPolicyScript <> Constraints.unspentOutputs utxosInBurnerWallet)
            (Constraints.mustMintValue $ assetClassValue (clapAssetClass policyHash) amount)
     >>= awaitTxConfirmed . txId



mintContract
    :: forall w s e.
    ( AsCLAPMonetaryPolicyError e
    )
    => PubKeyHash
    -> TokenName
    -> Integer
    -> Contract w s e (CurrencySymbol,Ledger.TxOutRef)
mintContract pk tokenName amount =
    mapError (review _CLAPMonetaryPolicyError) $ do
    txOutRef <- getUnspentOutput    
    let monetaryPolicyParams = Params {..}
        policyHash = (scriptCurrencySymbol . mkMonetaryPolicyScript) monetaryPolicyParams
        monetaryPolicyScript = mkMonetaryPolicyScript monetaryPolicyParams
        valueToMint = singleton policyHash tokenName amount
    utxosInWallet <- utxosAt (pubKeyHashAddress pk)
    submitTxConstraintsWith
            @Scripts.Any
            (Constraints.mintingPolicy monetaryPolicyScript <> Constraints.unspentOutputs utxosInWallet)
            (Constraints.mustSpendPubKeyOutput txOutRef     <> Constraints.mustMintValue valueToMint)
     >>= awaitTxConfirmed . txId
     >>  pure (policyHash,txOutRef)


