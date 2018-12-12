{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE TypeOperators     #-}
module Lib where

import qualified Control.Foldl         as L
import qualified Data.Foldable         as F
import qualified Data.List             as DL
import           Data.Vinyl
import           Data.Vinyl.Functor
import           Frames
import           Frames.ExtraInstances
import           Lens.Micro.Extras
import           Pipes                 hiding (Proxy)
import qualified Pipes.Prelude         as P

tableTypes "Prices" "data/prices.csv"
tableTypes "Purchases" "data/purchases.csv"

pricesStream :: MonadSafe m => Producer Prices m ()
pricesStream = readTableOpt pricesParser "data/prices.csv"

loadPrices :: IO (Frame Prices)
loadPrices = inCoreAoS pricesStream

purchasesStream :: MonadSafe m => Producer Purchases m ()
purchasesStream = readTableOpt purchasesParser "data/purchases.csv"

loadPurchases :: IO (Frame Purchases)
loadPurchases = inCoreAoS purchasesStream

someFunc :: IO ()
someFunc = putStrLn "someFunc"

loadFilteredPurchase :: IO (Frame Purchases)
loadFilteredPurchase =
  inCoreAoS $ purchasesStream >-> P.filter (\p -> rget @Item p /= Field "legal fees (1 hour)")

joinPricePurchase = do
  price <- loadPrices
  fpurchase <- loadFilteredPurchase
  return $ innerJoin @'[Item] price fpurchase

type MoneySpent = "money-spent" :-> Int

emptyColumn :: Int -> [Record '[MoneySpent]]
emptyColumn nrows =
  replicate nrows (0 &: RNil)

addNewColumn = do
  joined <- joinPricePurchase
  let nrows = F.length joined
  let zipped = zipFrames joined (toFrame $ emptyColumn nrows)
  return $ fmap (\r -> rput (Field @"money-spent" $ mult (rget @UnitsBought r) (rget @Price r)) r) zipped

mult :: Num t => ElField '(s1, t) -> ElField '(s2, t) -> t
mult (Field x) (Field y) = (x*y)

grouped = do
  a <- addNewColumn
  let persons = F.toList $ view person <$> a
  let uniquePersons = DL.nub persons
  return $ map (\up -> (up, filterFrame (\r -> (rget @Person r) == Field @"person" up) a)) uniquePersons

printGroup = do
  g <- grouped
  mapM_ (\(a, r) -> do print a;  (mapM_ print  r) ) g

sortedGroups = do
  gs <- grouped
  let gs' = map (\(a, rs) -> (a, DL.sortOn (\r -> unField $ rget @Date r) (F.toList rs))) gs
  return gs'

unField :: ElField '(s, t) -> t
unField (Field x) = x

type AccumulatedSpending = "accumulated-spending" :-> Int

extractMoneySpent rs = map (\r -> unField (rget @MoneySpent r)) rs

createColumnAccumulated rs =
  toFrame (
              map (\r ->
                      Field @"accumulated-spending" r :& RNil)
                  (
                    DL.scanl1
                      (+)
                      (extractMoneySpent rs)
                  )
          )

addNewColumnInGroups = do
  sorteds <- sortedGroups
  let zipped' = map (\(a, rs) ->
                        (
                          a
                        , zipFrames (toFrame rs) (createColumnAccumulated rs)
                        )
                    ) sorteds
  return $ zipped'

dropAccordingToDate = do
  ns <- addNewColumnInGroups
  return $
    map (\(a, fr) ->
            (
              a
            , last . F.toList $
                filterFrame (\r ->
                              unField (rget @Date r) <= 6)
                            fr
            )
        )
      ns

meanAcrossGroups = do
  dropped <- dropAccordingToDate
  let temp = map (\(_, r) -> (fromIntegral . unField) $ rget @AccumulatedSpending r) dropped
  let average = (/) <$> L.sum <*> L.genericLength
  return $ L.fold average temp
