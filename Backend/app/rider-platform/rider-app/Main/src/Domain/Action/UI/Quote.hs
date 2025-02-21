{-# OPTIONS_GHC -Wno-orphans #-}
{-
 Copyright 2022-23, Juspay India Pvt Ltd

 This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License

 as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program

 is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY

 or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details. You should have received a copy of

 the GNU Affero General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
-}
{-# OPTIONS_GHC -Wwarn=incomplete-uni-patterns #-}

module Domain.Action.UI.Quote
  ( GetQuotesRes (..),
    OfferRes (..),
    getQuotes,
    estimateBuildLockKey,
    processActiveBooking,
    mkQAPIEntityList,
    mkQuoteBreakupAPIEntity,
    QuoteAPIEntity (..),
    QuoteBreakupAPIEntity (..),
  )
where

import API.Types.UI.FRFSTicketService
import qualified API.Types.UI.FRFSTicketService as FRFSTicketService
import qualified Beckn.ACL.Cancel as CancelACL
import BecknV2.FRFS.Enums as BecknSpec
import Data.Char (toLower)
import qualified Data.HashMap.Strict as HM
import Data.OpenApi (ToSchema (..), genericDeclareNamedSchema)
import qualified Domain.Action.UI.Cancel as DCancel
import qualified Domain.Action.UI.DriverOffer as UDriverOffer
import qualified Domain.Action.UI.Estimate as UEstimate
import qualified Domain.Action.UI.InterCityDetails as DInterCityDetails
import qualified Domain.Action.UI.Location as DL
import qualified Domain.Action.UI.MerchantPaymentMethod as DMPM
import qualified Domain.Action.UI.RentalDetails as DRentalDetails
import qualified Domain.Action.UI.SpecialZoneQuote as USpecialZoneQuote
import Domain.Types.Booking
import Domain.Types.Booking as DBooking
import qualified Domain.Types.BookingCancellationReason as SBCR
import qualified Domain.Types.BppDetails as DBppDetails
import Domain.Types.CancellationReason
import qualified Domain.Types.DriverOffer as DDriverOffer
import qualified Domain.Types.Location as DL
import Domain.Types.Quote as DQuote
import qualified Domain.Types.Quote as SQuote
import Domain.Types.QuoteBreakup
import qualified Domain.Types.Ride as DRide
import qualified Domain.Types.SearchRequest as SSR
import Domain.Types.ServiceTierType as DVST
import qualified Domain.Types.SpecialZoneQuote as DSpecialZoneQuote
import qualified Domain.Types.Trip as DTrip
import EulerHS.Prelude hiding (id, map, sum)
import Kernel.Beam.Functions
import Kernel.Prelude hiding (whenJust)
import Kernel.Storage.Esqueleto (EsqDBReplicaFlow)
import Kernel.Storage.Hedis as Hedis
import qualified Kernel.Storage.Hedis as Redis
import Kernel.Streaming.Kafka.Producer.Types (KafkaProducerTools)
import Kernel.Streaming.Kafka.Topic.PublicTransportQuoteList
import qualified Kernel.Types.Beckn.Context as Context
import Kernel.Types.Error
import Kernel.Types.Id
import Kernel.Utils.Common
import Kernel.Utils.JSON (objectWithSingleFieldParsing)
import qualified Kernel.Utils.Schema as S
import qualified SharedLogic.CallBPP as CallBPP
import SharedLogic.MetroOffer (MetroOffer)
import qualified SharedLogic.MetroOffer as Metro
import qualified Storage.CachedQueries.BppDetails as CQBPP
import qualified Storage.CachedQueries.ValueAddNP as CQVAN
import qualified Storage.Queries.Booking as QBooking
import qualified Storage.Queries.Estimate as QEstimate
import qualified Storage.Queries.FRFSQuote as QFRFSQuote
import Storage.Queries.FRFSSearch as QFRFSSearch
import qualified Storage.Queries.Journey as QJourney
import qualified Storage.Queries.Quote as QQuote
import qualified Storage.Queries.Ride as QRide
import qualified Storage.Queries.SearchRequest as QSR
import qualified Tools.JSON as J
import qualified Tools.Schema as S
import TransactionLogs.Types

data QuoteAPIEntity = QuoteAPIEntity
  { id :: Id Quote,
    vehicleVariant :: DVST.ServiceTierType,
    serviceTierName :: Maybe Text,
    serviceTierShortDesc :: Maybe Text,
    estimatedFare :: Money,
    estimatedTotalFare :: Money,
    estimatedPickupDuration :: Maybe Seconds,
    discount :: Maybe Money,
    estimatedFareWithCurrency :: PriceAPIEntity,
    estimatedTotalFareWithCurrency :: PriceAPIEntity,
    discountWithCurrency :: Maybe PriceAPIEntity,
    agencyName :: Text,
    agencyNumber :: Maybe Text,
    tripTerms :: [Text],
    quoteDetails :: QuoteAPIDetails,
    specialLocationTag :: Maybe Text,
    quoteFareBreakup :: [QuoteBreakupAPIEntity],
    agencyCompletedRidesCount :: Maybe Int,
    vehicleServiceTierAirConditioned :: Maybe Double,
    isAirConditioned :: Maybe Bool,
    vehicleServiceTierSeatingCapacity :: Maybe Int,
    createdAt :: UTCTime,
    isValueAddNP :: Bool,
    validTill :: UTCTime,
    vehicleIconUrl :: Maybe Text
  }
  deriving (Generic, Show, ToJSON, FromJSON, ToSchema)

data QuoteBreakupAPIEntity = QuoteBreakupAPIEntity
  { title :: Text,
    priceWithCurrency :: PriceAPIEntity
  }
  deriving (Generic, Show, ToJSON, FromJSON, ToSchema)

makeQuoteAPIEntity :: Quote -> DBppDetails.BppDetails -> Bool -> QuoteAPIEntity
makeQuoteAPIEntity (Quote {..}) bppDetails isValueAddNP =
  let agencyCompletedRidesCount = Just 0
      providerNum = fromMaybe "+91" bppDetails.supportNumber
   in QuoteAPIEntity
        { agencyName = bppDetails.name,
          agencyNumber = Just providerNum,
          tripTerms = maybe [] (.descriptions) tripTerms,
          quoteDetails = mkQuoteAPIDetails (tollChargesInfo <&> (mkPriceAPIEntity . (.tollCharges))) quoteDetails,
          estimatedFare = estimatedFare.amountInt,
          estimatedTotalFare = estimatedTotalFare.amountInt,
          discount = discount <&> (.amountInt),
          estimatedFareWithCurrency = mkPriceAPIEntity estimatedFare,
          estimatedTotalFareWithCurrency = mkPriceAPIEntity estimatedTotalFare,
          discountWithCurrency = mkPriceAPIEntity <$> discount,
          vehicleVariant = vehicleServiceTierType,
          quoteFareBreakup = mkQuoteBreakupAPIEntity <$> quoteBreakupList,
          vehicleIconUrl = showBaseUrl <$> vehicleIconUrl,
          ..
        }

mkQuoteBreakupAPIEntity :: QuoteBreakup -> QuoteBreakupAPIEntity
mkQuoteBreakupAPIEntity QuoteBreakup {..} = do
  QuoteBreakupAPIEntity
    { title = title,
      priceWithCurrency = mkPriceAPIEntity price
    }

instance ToJSON QuoteAPIDetails where
  toJSON = genericToJSON J.fareProductOptions

instance FromJSON QuoteAPIDetails where
  parseJSON = genericParseJSON J.fareProductOptions

instance ToSchema QuoteAPIDetails where
  declareNamedSchema = genericDeclareNamedSchema S.fareProductSchemaOptions

mkQuoteAPIDetails :: Maybe PriceAPIEntity -> QuoteDetails -> QuoteAPIDetails
mkQuoteAPIDetails tollCharges = \case
  DQuote.RentalDetails details -> DQuote.RentalAPIDetails $ DRentalDetails.mkRentalDetailsAPIEntity details tollCharges
  DQuote.OneWayDetails OneWayQuoteDetails {..} ->
    DQuote.OneWayAPIDetails
      OneWayQuoteAPIDetails
        { distanceToNearestDriver = distanceToHighPrecMeters distanceToNearestDriver,
          distanceToNearestDriverWithUnit = distanceToNearestDriver,
          ..
        }
  DQuote.AmbulanceDetails DDriverOffer.DriverOffer {..} ->
    let distanceToPickup' = distanceToHighPrecMeters <$> distanceToPickup
     in DQuote.DriverOfferAPIDetails UDriverOffer.DriverOfferAPIEntity {distanceToPickup = distanceToPickup', distanceToPickupWithUnit = distanceToPickup, durationToPickup = durationToPickup, rating = rating, isUpgradedToCab = fromMaybe False isUpgradedToCab, ..}
  DQuote.DeliveryDetails DDriverOffer.DriverOffer {..} ->
    -- TODO::is delivery entity required
    let distanceToPickup' = distanceToHighPrecMeters <$> distanceToPickup
     in DQuote.DriverOfferAPIDetails UDriverOffer.DriverOfferAPIEntity {distanceToPickup = distanceToPickup', distanceToPickupWithUnit = distanceToPickup, durationToPickup = durationToPickup, rating = rating, isUpgradedToCab = fromMaybe False isUpgradedToCab, ..}
  DQuote.DriverOfferDetails DDriverOffer.DriverOffer {..} ->
    let distanceToPickup' = (distanceToHighPrecMeters <$> distanceToPickup) <|> (Just . HighPrecMeters $ toCentesimal 0) -- TODO::remove this default value
        distanceToPickupWithUnit' = distanceToPickup <|> Just (Distance 0 Meter) -- TODO::remove this default value
        durationToPickup' = durationToPickup <|> Just 0 -- TODO::remove this default value
        rating' = rating <|> Just (toCentesimal 500) -- TODO::remove this default value
     in DQuote.DriverOfferAPIDetails UDriverOffer.DriverOfferAPIEntity {distanceToPickup = distanceToPickup', distanceToPickupWithUnit = distanceToPickupWithUnit', durationToPickup = durationToPickup', rating = rating', isUpgradedToCab = fromMaybe False isUpgradedToCab, ..}
  DQuote.OneWaySpecialZoneDetails DSpecialZoneQuote.SpecialZoneQuote {..} -> DQuote.OneWaySpecialZoneAPIDetails USpecialZoneQuote.SpecialZoneQuoteAPIEntity {..}
  DQuote.InterCityDetails details -> DQuote.InterCityAPIDetails $ DInterCityDetails.mkInterCityDetailsAPIEntity details tollCharges

mkQAPIEntityList :: [Quote] -> [DBppDetails.BppDetails] -> [Bool] -> [QuoteAPIEntity]
mkQAPIEntityList (q : qRemaining) (bpp : bppRemaining) (isValueAddNP : remVNP) =
  makeQuoteAPIEntity q bpp isValueAddNP : mkQAPIEntityList qRemaining bppRemaining remVNP
mkQAPIEntityList [] [] [] = []
mkQAPIEntityList _ _ _ = [] -- This should never happen as all the list are of same length

data GetQuotesRes = GetQuotesRes
  { fromLocation :: DL.LocationAPIEntity,
    toLocation :: Maybe DL.LocationAPIEntity,
    stops :: [DL.LocationAPIEntity],
    quotes :: [OfferRes],
    estimates :: [UEstimate.EstimateAPIEntity],
    paymentMethods :: [DMPM.PaymentMethodAPIEntity],
    journey :: Maybe [JourneyData]
  }
  deriving (Generic, FromJSON, ToJSON, Show, ToSchema)

data JourneyData = JourneyData
  { totalPrice :: HighPrecMoney,
    modes :: [DTrip.TravelMode],
    journeyLegs :: [JourneyLeg]
  }
  deriving (Generic, FromJSON, ToJSON, Show, ToSchema)

data JourneyLeg = JourneyLeg
  { journeyLegOrder :: Int,
    journeyMode :: DTrip.TravelMode,
    estimate :: Maybe UEstimate.EstimateAPIEntity,
    quote :: Maybe FRFSTicketService.FRFSQuoteAPIRes
  }
  deriving (Generic, FromJSON, ToJSON, Show, ToSchema)

-- TODO: Needs to be fixed as quotes could be of both rentals and one way
data OfferRes
  = OnDemandCab QuoteAPIEntity
  | OnRentalCab QuoteAPIEntity
  | Metro MetroOffer
  | PublicTransport PublicTransportQuote
  deriving (Show, Generic)

instance ToJSON OfferRes where
  toJSON = genericToJSON $ objectWithSingleFieldParsing \(f : rest) -> toLower f : rest

instance FromJSON OfferRes where
  parseJSON = genericParseJSON $ objectWithSingleFieldParsing \(f : rest) -> toLower f : rest

instance ToSchema OfferRes where
  declareNamedSchema = genericDeclareNamedSchema $ S.objectWithSingleFieldParsing \(f : rest) -> toLower f : rest

estimateBuildLockKey :: Text -> Text
estimateBuildLockKey searchReqid = "Customer:Estimate:Build:" <> searchReqid

getQuotes :: (CacheFlow m r, HasField "shortDurationRetryCfg" r RetryCfg, HasFlowEnv m r '["internalEndPointHashMap" ::: HM.HashMap BaseUrl BaseUrl], HasFlowEnv m r '["nwAddress" ::: BaseUrl], EsqDBReplicaFlow m r, EncFlow m r, EsqDBFlow m r, HasFlowEnv m r '["kafkaProducerTools" ::: KafkaProducerTools], HasFlowEnv m r '["ondcTokenHashMap" ::: HM.HashMap KeyConfig TokenConfig]) => Id SSR.SearchRequest -> Maybe Bool -> m GetQuotesRes
getQuotes searchRequestId mbAllowMultiple = do
  searchRequest <- runInReplica $ QSR.findById searchRequestId >>= fromMaybeM (SearchRequestDoesNotExist searchRequestId.getId)
  unless (mbAllowMultiple == Just True) $ do
    activeBooking <- runInReplica $ QBooking.findLatestSelfAndPartyBookingByRiderId searchRequest.riderId
    whenJust activeBooking $ \booking -> processActiveBooking booking OnSearch
  logDebug $ "search Request is : " <> show searchRequest
  journeyData <- getJourneyData searchRequestId
  let lockKey = estimateBuildLockKey searchRequestId.getId
  Redis.withLockRedisAndReturnValue lockKey 5 $ do
    offers <- getOffers searchRequest
    estimates <- getEstimates searchRequestId (isJust searchRequest.driverIdentifier) -- TODO(MultiModal): only check for estimates which are done
    return $
      GetQuotesRes
        { fromLocation = DL.makeLocationAPIEntity searchRequest.fromLocation,
          toLocation = DL.makeLocationAPIEntity <$> searchRequest.toLocation,
          stops = DL.makeLocationAPIEntity <$> searchRequest.stops,
          quotes = offers,
          estimates,
          paymentMethods = [],
          journey = journeyData
        }

processActiveBooking :: (CacheFlow m r, HasField "shortDurationRetryCfg" r RetryCfg, HasFlowEnv m r '["internalEndPointHashMap" ::: HM.HashMap BaseUrl BaseUrl], HasFlowEnv m r '["nwAddress" ::: BaseUrl], EsqDBReplicaFlow m r, EncFlow m r, EsqDBFlow m r, HasFlowEnv m r '["kafkaProducerTools" ::: KafkaProducerTools], HasFlowEnv m r '["ondcTokenHashMap" ::: HM.HashMap KeyConfig TokenConfig]) => Booking -> CancellationStage -> m ()
processActiveBooking booking cancellationStage = do
  mbRide <- QRide.findActiveByRBId booking.id
  case mbRide of
    Just ride -> do
      unless (ride.status == DRide.UPCOMING) $ throwError (InvalidRequest "ACTIVE_BOOKING_ALREADY_PRESENT")
    Nothing -> do
      now <- getCurrentTime
      if addUTCTime 900 booking.startTime < now || not (isRentalOrInterCity booking.bookingDetails) || (addUTCTime 120 booking.startTime < now && isHighPriorityBooking booking.bookingDetails)
        then do
          let cancelReq =
                DCancel.CancelReq
                  { reasonCode = CancellationReasonCode "Active booking",
                    reasonStage = cancellationStage,
                    additionalInfo = Nothing,
                    reallocate = Nothing
                  }
          fork "active booking processing" $ do
            dCancelRes <- DCancel.cancel booking Nothing cancelReq SBCR.ByApplication
            void . withShortRetry $ CallBPP.cancelV2 booking.merchantId dCancelRes.bppUrl =<< CancelACL.buildCancelReqV2 dCancelRes Nothing
        else throwError (InvalidRequest "ACTIVE_BOOKING_ALREADY_PRESENT")

isRentalOrInterCity :: DBooking.BookingDetails -> Bool
isRentalOrInterCity bookingDetails = case bookingDetails of
  DBooking.RentalDetails _ -> True
  DBooking.InterCityDetails _ -> True
  _ -> False

isHighPriorityBooking :: DBooking.BookingDetails -> Bool
isHighPriorityBooking bookingDetails = case bookingDetails of
  DBooking.AmbulanceDetails _ -> True
  _ -> False

getOffers :: (HedisFlow m r, CacheFlow m r, EsqDBFlow m r, EsqDBReplicaFlow m r) => SSR.SearchRequest -> m [OfferRes]
getOffers searchRequest = do
  logDebug $ "search Request is : " <> show searchRequest
  case searchRequest.toLocation of
    Just _ -> do
      quoteList <- sortByNearestDriverDistance <$> runInReplica (QQuote.findAllBySRId searchRequest.id)
      logDebug $ "quotes are :-" <> show quoteList
      bppDetailList <- forM ((.providerId) <$> quoteList) (\bppId -> CQBPP.findBySubscriberIdAndDomain bppId Context.MOBILITY >>= fromMaybeM (InternalError $ "BPP details not found for providerId:-" <> bppId <> "and domain:-" <> show Context.MOBILITY))
      isValueAddNPList <- forM bppDetailList $ \bpp -> CQVAN.isValueAddNP bpp.subscriberId
      let quotes = case searchRequest.riderPreferredOption of
            SSR.Rental -> OnRentalCab <$> mkQAPIEntityList quoteList bppDetailList isValueAddNPList
            _ -> OnDemandCab <$> mkQAPIEntityList quoteList bppDetailList isValueAddNPList
      return . sortBy (compare `on` creationTime) $ quotes
    Nothing -> do
      quoteList <- sortByEstimatedFare <$> runInReplica (QQuote.findAllBySRId searchRequest.id)
      logDebug $ "quotes are :-" <> show quoteList
      bppDetailList <- forM ((.providerId) <$> quoteList) (\bppId -> CQBPP.findBySubscriberIdAndDomain bppId Context.MOBILITY >>= fromMaybeM (InternalError $ "BPP details not found for providerId:-" <> bppId <> "and domain:-" <> show Context.MOBILITY))
      isValueAddNPList <- forM bppDetailList $ \bpp -> CQVAN.isValueAddNP bpp.subscriberId
      let quotes = OnRentalCab <$> mkQAPIEntityList quoteList bppDetailList isValueAddNPList
      return . sortBy (compare `on` creationTime) $ quotes
  where
    sortByNearestDriverDistance quoteList = do
      let sortFunc = compare `on` getMbDistanceToNearestDriver
      sortBy sortFunc quoteList
    getMbDistanceToNearestDriver quote =
      case quote.quoteDetails of
        SQuote.OneWayDetails details -> Just details.distanceToNearestDriver
        SQuote.AmbulanceDetails details -> details.distanceToPickup
        SQuote.DeliveryDetails details -> details.distanceToPickup
        SQuote.RentalDetails _ -> Nothing
        SQuote.DriverOfferDetails details -> details.distanceToPickup
        SQuote.OneWaySpecialZoneDetails _ -> Just $ Distance 0 Meter
        SQuote.InterCityDetails _ -> Just $ Distance 0 Meter
    creationTime :: OfferRes -> UTCTime
    creationTime (OnDemandCab QuoteAPIEntity {createdAt}) = createdAt
    creationTime (Metro Metro.MetroOffer {createdAt}) = createdAt
    creationTime (OnRentalCab QuoteAPIEntity {createdAt}) = createdAt
    creationTime (PublicTransport PublicTransportQuote {createdAt}) = createdAt

getEstimates :: (CacheFlow m r, EsqDBFlow m r, EsqDBReplicaFlow m r) => Id SSR.SearchRequest -> Bool -> m [UEstimate.EstimateAPIEntity]
getEstimates searchRequestId isReferredRide = do
  estimateList <- runInReplica $ QEstimate.findAllBySRId searchRequestId
  estimates <- mapM (UEstimate.mkEstimateAPIEntity isReferredRide) (sortByEstimatedFare estimateList)
  return . sortBy (compare `on` (.createdAt)) $ estimates

sortByEstimatedFare :: (HasField "estimatedFare" r Price) => [r] -> [r]
sortByEstimatedFare resultList = do
  let sortFunc = compare `on` (.estimatedFare.amount)
  sortBy sortFunc resultList

getJourneyData :: (HedisFlow m r, CacheFlow m r, EsqDBFlow m r, EsqDBReplicaFlow m r) => Id SSR.SearchRequest -> m (Maybe [JourneyData])
getJourneyData searchRequestId = do
  allJourneys <- QJourney.findBySearchId searchRequestId
  journeyNeeded <- pure $ listToMaybe allJourneys
  journeyData <- try @_ @SomeException $
    case journeyNeeded of
      Just journey -> do
        searchReqs <- QSR.findAllByJourneyId journey.id
        searchReqJourneyData <- do
          forM searchReqs \searchReq -> do
            journeyLegInfo <- searchReq.journeyLegInfo & fromMaybeM (InvalidRequest "journeyLegInfo not found")
            estimateId <- journeyLegInfo.pricingId & fromMaybeM (InvalidRequest "estimateId not found")
            estimate <- QEstimate.findById (Id estimateId) >>= fromMaybeM (InvalidRequest "estimate not found")
            estimateApiEntity <- UEstimate.mkEstimateAPIEntity False estimate
            return $
              JourneyLeg
                { journeyLegOrder = journeyLegInfo.journeyLegOrder,
                  journeyMode = DTrip.Taxi,
                  estimate = Just estimateApiEntity,
                  quote = Nothing
                }
        frfsSearchReqs <- QFRFSSearch.findAllByJourneyId journey.id
        frfsSearchReqJourneyData <-
          forM frfsSearchReqs \frfsSearchReq -> do
            journeyLegInfo <- frfsSearchReq.journeyLegInfo & fromMaybeM (InvalidRequest "journeyLegInfo not found")
            quoteId <- journeyLegInfo.pricingId & fromMaybeM (InvalidRequest "quoteId not found")
            quote <- QFRFSQuote.findById (Id quoteId) >>= fromMaybeM (InvalidRequest "quote not found")
            (stations :: [FRFSStationAPI]) <- decodeFromText quote.stationsJson & fromMaybeM (InternalError "Invalid stations jsons from db")
            let routeStations :: Maybe [FRFSRouteStationsAPI] = decodeFromText =<< quote.routeStationsJson
                discounts :: Maybe [FRFSDiscountRes] = decodeFromText =<< quote.discountsJson
            let quoteRes =
                  FRFSTicketService.FRFSQuoteAPIRes
                    { quoteId = quote.id,
                      _type = quote._type,
                      price = quote.price.amount,
                      priceWithCurrency = mkPriceAPIEntity quote.price,
                      quantity = quote.quantity,
                      validTill = quote.validTill,
                      vehicleType = quote.vehicleType,
                      discountedTickets = quote.discountedTickets,
                      eventDiscountAmount = quote.eventDiscountAmount,
                      ..
                    }
            let journeyMode = case quote.vehicleType of
                  BecknSpec.BUS -> DTrip.Bus
                  BecknSpec.METRO -> DTrip.Metro
            return $
              JourneyLeg
                { journeyLegOrder = journeyLegInfo.journeyLegOrder,
                  journeyMode,
                  estimate = Nothing,
                  quote = Just quoteRes
                }
        logDebug $ "journey data for search request: " <> show searchReqJourneyData <> show frfsSearchReqJourneyData
        let journeyLegs = sortOn (.journeyLegOrder) $ (concat [searchReqJourneyData, frfsSearchReqJourneyData])
        let sumPrice =
              sum $
                map
                  ( \leg -> do
                      case (leg.estimate, leg.quote) of
                        (Just estimate, _) -> estimate.estimatedTotalFareWithCurrency.amount.getHighPrecMoney
                        (_, Just quote) -> quote.priceWithCurrency.amount.getHighPrecMoney
                        (_, _) -> 0.0
                  )
                  journeyLegs
        return $
          Just $
            [ JourneyData
                { totalPrice = HighPrecMoney {getHighPrecMoney = sumPrice},
                  modes = journey.modes,
                  journeyLegs
                }
            ]
      Nothing ->
        pure Nothing
  case journeyData of
    Left err -> do
      logDebug $ "journey unavailable for searchId: " <> searchRequestId.getId <> show err
      return Nothing
    Right journey -> return journey
