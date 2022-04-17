{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TupleSections #-}

module Main where

import qualified Canonical.TestMinting as TestMinting
import Cardano.Api (displayError, writeFileTextEnvelope)
import Cardano.Transaction hiding (Value)
import qualified Cardano.Transaction as TxBuilder
import Control.Exception
import Control.Monad.IO.Class
import Control.Monad.Identity
import Control.Monad.Managed
import Control.Monad.State
import Data.Aeson as Aeson
import Data.Aeson.Types as Aeson
import Data.Bifunctor
import Data.List.Extra
import qualified Data.Map as Map
import Data.String
import qualified Data.Text as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Traversable
import Env
import Ledger (POSIXTime, PubKeyHash)
import Plutus.V1.Ledger.Ada
import Plutus.V1.Ledger.Time (fromMilliSeconds)
import qualified Plutus.V1.Ledger.Value as Value
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.IO.Temp
import System.Process
import Test.Hspec

import Canonical.JpgStore.BulkPurchase

data Opts = Opts
  { optsSourceWalletAddressPath :: FilePath
  , optsSourceWalletSkeyPath :: FilePath
  , optsTestnetMagic :: Maybe Integer
  , optsWalletDir :: Maybe FilePath
  }

data Config = Config
  { cSourceWalletAddressPath :: FilePath
  , cSourceWalletSkeyPath :: FilePath
  , cTestnetMagic :: Maybe Integer
  , cWalletDir :: FilePath
  , cProtocolParams :: Maybe FilePath
  , cPlutusScript :: FilePath
  , cScriptAddr :: Address
  }

data SwapAndDatum = SwapAndDatum
  { sadSwap :: Swap
  , sadDatumHash :: String
  }

type Swaps = [SwapAndDatum]

data Wallet = Wallet
  { walletSkeyPath :: FilePath
  , walletAddr :: String
  , walletPkh :: String
  }
  deriving Show

data Wallets = Wallets
  { sellers :: [Wallet]
  , buyer :: Wallet
  , marketplace :: Wallet
  , royalties :: Wallet
  }
  deriving Show

data Policy = Policy
  { policyId :: String
  , policyFile :: FilePath
  }
  deriving Show

data Resources = Resources
  { rWallets :: Wallets
  , rPolicies :: [Policy]
  }
  deriving Show

data TestException = SetupException | TxException IOException
  deriving (Show, Eq)

instance Exception TestException

isTxException :: TestException -> Bool
isTxException = \case
  TxException _ -> True
  _ -> False

type SelectWallet = Wallets -> Wallet
type SelectPolicy = [Policy] -> Policy

seller1 :: SelectWallet
seller1 = (!! 0) . sellers

seller2 :: SelectWallet
seller2 = (!! 1) . sellers

policy1 :: SelectPolicy
policy1 = (!! 0)

policy2 :: SelectPolicy
policy2 = (!! 1)

policy3 :: SelectPolicy
policy3 = (!! 2)

policy4 :: SelectPolicy
policy4 = (!! 3)

runTests :: Config -> IO ()
runTests config = do
  expiredDeadline <- liftIO $ (5000 -) . fromMilliSeconds . round . (* 1000) <$> getPOSIXTime
  hspec $ aroundAllWith (createResources config) $ do
    describe "single offer" $ do
      aroundWith (createSwaps config [swapSpec seller1 policy1]) $ do

        it "can be purchased" $ \(resources, swaps) -> evalBuys config resources swaps buyer

        it "can be cancelled by owner" $ \(resources, swaps) -> evalCancelSwaps config resources swaps seller1

        context "without expiration" $ do
          it "cannot be closed"
            $ \(resources, swaps) -> evalCloseSwaps config resources swaps marketplace `shouldThrow` isTxException

      context "that has expired" $ do
        aroundWith (createSwaps config [(swapSpec seller1 policy1) { specDeadline = Just expiredDeadline }]) $ do

          it "cannot be purchased"
            $ \(resources, swaps) -> evalBuys config resources swaps buyer `shouldThrow` isTxException

          it "can be cancelled by owner" $ \(resources, swaps) -> evalCancelSwaps config resources swaps seller1

          it "can be closed by anyone" $ \(resources, swaps) -> evalCloseSwaps config resources swaps marketplace

    describe "multiple offers" $ do
      context "from same seller" $ do
        aroundWith (createSwaps config [swapSpec seller1 policy1, swapSpec seller1 policy2]) $ do
          it "can be cancelled in bulk" $ \(resources, swaps) -> do
            evalCancelSwaps config resources swaps seller1

    describe "multiple offers" $ do
      context "from multiple sellers" $ do
        context "that have no expiration" $ do
          aroundWith (createSwaps config [swapSpec seller1 policy1, swapSpec seller2 policy3]) $ do
            it "cannot be cancelled in bulk" $ \(resources, swaps) -> do
              evalCancelSwaps config resources swaps seller1 `shouldThrow` isTxException

            -- xit "cannot mix buys and cancels" $ \_ -> do
            --   error "not implemented" :: IO ()

            -- xit "cannot mix buys and emergency cancels" $ \_ -> do
            --   error "not implemented" :: IO ()

            -- xit "cannot mix buys and closes" $ \_ -> do
            --   error "not implemented" :: IO ()


            it "can be purchased in bulk" $ \(resources, swaps) -> do
              evalBuys config resources swaps buyer

        context "that have expired" $ do
          aroundWith
              (createSwaps
                config
                [ (swapSpec seller1 policy1) { specDeadline = Just expiredDeadline }
                , (swapSpec seller2 policy3) { specDeadline = Just expiredDeadline }
                ]
              )
            $ do

                it "cannot be purchased"
                  $ \(resources, swaps) -> evalBuys config resources swaps buyer `shouldThrow` isTxException

                it "can be closed by anyone" $ \(resources, swaps) -> evalCloseSwaps config resources swaps marketplace

main :: IO ()
main = do
  opts <-
    Env.parse (header "integration-tests")
    $ Opts
    <$> var
          (str <=< nonempty)
          "SOURCE_WALLET_ADDRESS_PATH"
          (help "Path the address of the wallet to use for populating test wallets")
    <*> var
          (str <=< nonempty)
          "SOURCE_WALLET_SKEY_PATH"
          (help "Path the signing key of the wallet to use for populating test wallets")
    <*> optional (var auto "TESTNET_MAGIC" (help "Testnet magic"))
    <*> optional (var str "WALLET_DIR" (help "Directory for wallet files"))

  (callProcess "cardano-cli" . mappend ["query", "tip"] . toTestnetFlags . optsTestnetMagic $ opts) `catch` \e -> do
    let _e = e :: SomeException
    hPutStrLn stderr
      . mconcat
      $ [ "\n"
        , "Failed to query the network, check that:\n"
        , "* cardano-cli is on the PATH\n"
        , "* CARDANO_NODE_SOCKET_PATH is set correctly\n"
        , "* the cardano-node process is listening on the socket\n"
        ]
    exitFailure

  let
    withTempDir :: (FilePath -> IO a) -> IO a
    withTempDir = case optsWalletDir opts of
      Nothing -> withSystemTempDirectory "wallets"
      Just dir -> \run -> do
        createDirectoryIfMissing True dir
        run dir

    withConfig run =
      withPlutusFile (optsTestnetMagic opts)
        $ \plutusScript scriptAddr -> withProtocolParams (optsTestnetMagic opts) $ \pp -> withTempDir $ \dir ->
            run $ Config
              { cSourceWalletSkeyPath = optsSourceWalletSkeyPath opts
              , cSourceWalletAddressPath = optsSourceWalletAddressPath opts
              , cWalletDir = dir
              , cProtocolParams = Just pp
              , cPlutusScript = plutusScript
              , cScriptAddr = scriptAddr
              , cTestnetMagic = optsTestnetMagic opts
              }

  withConfig runTests

toTxValue :: Value.Value -> TxBuilder.Value
toTxValue =
  mconcat
    . fmap
        (\(cs, tn, n) ->
          TxBuilder.Value . Map.singleton (show cs) . Map.singleton (encodedTokenName . Value.toString $ tn) $ n
        )
    . Value.flattenValue

allWallets :: Wallets -> [Wallet]
allWallets Wallets {..} = buyer : royalties : marketplace : sellers

lookupWalletAddr :: PubKeyHash -> Wallets -> String
lookupWalletAddr pkh =
  maybe (error $ "couldn't find wallet for pkh " <> show pkh) walletAddr . find ((show pkh ==) . walletPkh) . allWallets


evalBuys :: Config -> Resources -> [SwapAndDatum] -> SelectWallet -> IO ()
evalBuys config@Config {..} Resources {..} swaps buyerW = do
  let
    buyerAddr = walletAddr . buyerW $ rWallets
    mergePayouts = fmap (uncurry Payout) . Map.toList . foldr (Map.unionWith mappend) mempty . fmap
      (\Payout {..} -> Map.singleton pAddress pValue)
  handle (throwIO . TxException) . eval cTestnetMagic cProtocolParams $ do
    (payouts, assets) <-
      fmap (bimap (mergePayouts . mconcat) (toTxValue . mconcat) . unzip) . forScriptInputs config swaps $ \s utxo -> do
        scriptInput utxo cPlutusScript s Buy
        pure (sSwapPayouts s, sSwapValue s)

    void $ output buyerAddr (assets <> "1758582 lovelace")

    payoutTotal <- fmap mconcat . for payouts $ \Payout {..} ->
      let txValue = toTxValue pValue in txValue <$ output (lookupWalletAddr pAddress rWallets) txValue

    void $ selectInputs payoutTotal buyerAddr

    void $ selectCollateralInput buyerAddr
    void $ balanceNonAdaAssets buyerAddr
    changeAddress buyerAddr
    sign . walletSkeyPath . buyerW $ rWallets

  waitForNextBlock cTestnetMagic

evalCancelSwaps :: Config -> Resources -> [SwapAndDatum] -> SelectWallet -> IO ()
evalCancelSwaps config@Config {..} Resources {..} swaps canceller = do
  let Wallet {..} = canceller rWallets

  handle (throwIO . TxException) . eval cTestnetMagic cProtocolParams $ do
    void $ forScriptInputs config swaps $ \s utxo -> scriptInput utxo cPlutusScript s Cancel
    (cin, _) <- selectCollateralInput walletAddr
    input . iUtxo $ cin
    void $ balanceNonAdaAssets walletAddr
    changeAddress walletAddr
    sign walletSkeyPath

  waitForNextBlock cTestnetMagic

evalCloseSwaps :: Config -> Resources -> [SwapAndDatum] -> SelectWallet -> IO ()
evalCloseSwaps config@Config {..} Resources {..} swaps closer = do
  let Wallet {..} = closer rWallets

  handle (throwIO . TxException) . eval cTestnetMagic cProtocolParams $ do
    void $ forScriptInputs config swaps $ \s@Swap {..} utxo -> do
      scriptInput utxo cPlutusScript s Close
      void $ output (lookupWalletAddr sOwner rWallets) ("1758582 lovelace" <> toTxValue sSwapValue)

    (cin, _) <- selectCollateralInput walletAddr
    input . iUtxo $ cin
    void $ balanceNonAdaAssets walletAddr
    changeAddress walletAddr
    void startNow
    sign walletSkeyPath

  waitForNextBlock cTestnetMagic


forScriptInputs :: Config -> [SwapAndDatum] -> (Swap -> UTxO -> Tx a) -> Tx [a]
forScriptInputs Config {..} swaps f = for swaps $ \SwapAndDatum {..} -> do
  utxos <- findScriptInputs cScriptAddr sadDatumHash
  -- we only take the first one in case there are multiple with the same datum from previous runs
  case utxos of
    [] ->
      liftIO
        . fail
        . mconcat
        $ ["no script inputs found for script address '", cScriptAddr, "' and datum hash '", sadDatumHash, "'"]
    x : _ -> f sadSwap x

data SwapSpec = SwapSpec
  { specSeller :: SelectWallet
  , specPolicy :: SelectPolicy
  , specPayouts :: Wallets -> [Payout]
  , specDeadline :: Maybe POSIXTime
  }

stdPayouts :: SelectWallet -> Wallets -> [Payout]
stdPayouts seller wallets =
  [ Payout (fromString . walletPkh . seller $ wallets) (lovelaceValueOf 8000000)
  , Payout (fromString . walletPkh . marketplace $ wallets) (lovelaceValueOf 1000000)
  , Payout (fromString . walletPkh . royalties $ wallets) (lovelaceValueOf 1000000)
  ]

swapSpec :: SelectWallet -> SelectPolicy -> SwapSpec
swapSpec seller policy = SwapSpec seller policy (stdPayouts seller) Nothing

createSwaps :: Config -> [SwapSpec] -> ActionWith (Resources, Swaps) -> ActionWith Resources
createSwaps config specs runTest rs@Resources { rWallets, rPolicies } =
  let
    createSwap' SwapSpec {..} =
      createSwap config (specSeller rWallets) (specPolicy rPolicies) (specPayouts rWallets) specDeadline
  in bracket (traverse createSwap' specs)
   -- (cleanup . (wallets, ))
                                          (\_ -> pure ()) (runTest . (rs, ))

createSwap :: Config -> Wallet -> Policy -> [Payout] -> Maybe POSIXTime -> IO SwapAndDatum
createSwap config@Config {..} wallet@Wallet {..} policy payouts deadline = do
  let
    pValue = Value.singleton (fromString . policyId $ policy) "123456" 1
    swapDatum = Swap (fromString walletPkh) pValue payouts deadline

  datumHash <- hashDatum . toCliJson $ swapDatum

  -- if there is an existing swap that is the same, reuse it
  existingScriptInput <- filter ((== Just datumHash) . utxoDatumHash) <$> queryUtxos walletAddr cTestnetMagic

  when (null existingScriptInput) $ do
    txValue <- evalMint config wallet policy "123456" 1
    waitForNextBlock cTestnetMagic

    handle @SomeException (\_ -> throwIO SetupException) . eval cTestnetMagic cProtocolParams $ do
      outputWithHash cScriptAddr ("5000000 lovelace" <> txValue) swapDatum
      void $ selectInputs "7000000 lovelace" walletAddr
      changeAddress walletAddr
      void . balanceNonAdaAssets $ walletAddr
      sign walletSkeyPath

    waitForNextBlock cTestnetMagic

  pure $ SwapAndDatum swapDatum datumHash

encodedTokenName :: String -> String
encodedTokenName =
  Text.unpack
    . maybe (error "unexpected tokenname serialization") id
    . Aeson.parseMaybe (Aeson.withObject "TokenName" (.: "bytes"))
    . toCliJson
    . fromString @Value.TokenName

evalMint :: Config -> Wallet -> Policy -> String -> Integer -> IO TxBuilder.Value
evalMint Config { cTestnetMagic, cProtocolParams } Wallet { walletAddr, walletSkeyPath } policy token n = do
  let txValue = TxBuilder.Value . Map.singleton (policyId policy) . Map.singleton (encodedTokenName token) $ n
  handle @SomeException (\_ -> throwIO SetupException) . eval cTestnetMagic cProtocolParams $ do
    mint txValue (policyFile policy) ([] @Int)

    void $ output walletAddr ("1758582 lovelace" <> txValue)
    (cInput, _) <- selectCollateralInput walletAddr
    input . iUtxo $ cInput

    changeAddress walletAddr
    void . balanceNonAdaAssets $ walletAddr

    sign walletSkeyPath

  pure txValue

createResources :: Config -> ActionWith Resources -> ActionWith ()
createResources config runTest _ =
  withWallets config $ \wallets -> withPolicies $ \policies -> runTest . Resources wallets $ policies

withProtocolParams :: Maybe Integer -> (FilePath -> IO a) -> IO a
withProtocolParams testnetMagic runTest = withSystemTempFile "protocol-params.json" $ \fp fh -> do
  hClose fh
  callProcess "cardano-cli" (["query", "protocol-parameters", "--out-file", fp] <> toTestnetFlags testnetMagic)
  runTest fp

withPlutusFile :: Maybe Integer -> (FilePath -> Address -> IO a) -> IO a
withPlutusFile testnetMagic runTest = withSystemTempFile "swap.plutus" $ \fp fh -> do
  hClose fh
  writePlutusFile fp
  scriptAddr <- readProcess
    "cardano-cli"
    (["address", "build", "--payment-script-file", fp] <> toTestnetFlags testnetMagic)
    mempty
  runTest fp scriptAddr


withPolicies :: ([Policy] -> IO a) -> IO a
withPolicies = with (mapM (\n -> managed (withPolicy n)) [0 .. 3])

withPolicy :: Integer -> (Policy -> IO a) -> IO a
withPolicy n f = withSystemTempFile ("policy-" <> show n <> ".plutus") $ \fp fh -> do
  hClose fh
  r <- writeFileTextEnvelope fp Nothing $ TestMinting.mintingAsCbor n
  case r of
    Left err -> error $ displayError err
    Right () -> pure ()
  policyId <- trim <$> readProcess "cardano-cli" ["transaction", "policyid", "--script-file", fp] mempty
  f $ Policy policyId fp

withWallets :: Config -> (Wallets -> IO c) -> IO c
withWallets config@Config {..} runTest =
  let createWallet' = createWallet config
  in
    bracket
      (do
        (wallets, newAddrs) <-
          flip runStateT []
          $ Wallets
          <$> traverse createWallet' ["seller1", "seller2"]
          <*> createWallet' "buyer"
          <*> createWallet' "marketplace"
          <*> createWallet' "royalties"

        unless (null newAddrs) $ do
          handle @SomeException (\_ -> throwIO SetupException) . eval cTestnetMagic cProtocolParams $ do
            values <- traverse (\addr -> fmap oValue . output addr $ "100000000 lovelace") newAddrs

            srcAddr <- liftIO . fmap trim . readFile $ cSourceWalletAddressPath
            void $ selectInputs (mconcat values) srcAddr

            changeAddress srcAddr
            void $ balanceNonAdaAssets srcAddr

            sign cSourceWalletSkeyPath

          waitForNextBlock cTestnetMagic

        pure wallets
      )
      (\_ -> pure ())
      runTest

createWallet :: Config -> String -> StateT [Address] IO Wallet
createWallet Config {..} name = do
  let
    vkeyFile = cWalletDir </> name <.> "vkey"
    skeyFile = cWalletDir </> name <.> "skey"
  exists <- liftIO $ doesFileExist vkeyFile
  liftIO $ unless exists $ do
    callProcess
      "cardano-cli"
      ["address", "key-gen", "--verification-key-file", vkeyFile, "--signing-key-file", skeyFile]
  addr <-
    let
      args = mconcat [["address", "build", "--payment-verification-key-file", vkeyFile], toTestnetFlags cTestnetMagic]
    in liftIO $ trim <$> readProcess "cardano-cli" args mempty

  unless exists $ modify (addr :)

  liftIO $ writeFile (cWalletDir </> name <.> "addr") addr
  pkh <-
    liftIO
    $ trim
    <$> readProcess "cardano-cli" ["address", "key-hash", "--payment-verification-key-file", vkeyFile] mempty

  pure $ Wallet skeyFile addr pkh

