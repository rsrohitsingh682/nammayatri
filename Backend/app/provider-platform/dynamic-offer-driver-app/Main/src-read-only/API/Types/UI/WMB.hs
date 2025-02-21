{-# OPTIONS_GHC -Wno-unused-imports #-}

module API.Types.UI.WMB where

import Data.OpenApi (ToSchema)
import qualified Data.Text
import qualified Domain.Types.Common
import EulerHS.Prelude hiding (id)
import qualified Kernel.External.Maps.Types
import qualified Kernel.Prelude
import Servant
import Tools.Auth

data AvailableRoutesList = AvailableRoutesList {destination :: StopInfo, routeInfo :: RouteInfo, source :: StopInfo, vehicleDetails :: VehicleDetails}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data EndTripStatus
  = SUCCESS
  | WAITING_FOR_ADMIN_APPROVAL
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data RouteInfo = RouteInfo {code :: Data.Text.Text, endPoint :: Kernel.External.Maps.Types.LatLong, longName :: Data.Text.Text, shortName :: Data.Text.Text, startPoint :: Kernel.External.Maps.Types.LatLong}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data StopInfo = StopInfo {code :: Data.Text.Text, lat :: Kernel.Prelude.Maybe Kernel.Prelude.Double, long :: Kernel.Prelude.Maybe Kernel.Prelude.Double, name :: Data.Text.Text}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data TripEndReq = TripEndReq {location :: Kernel.External.Maps.Types.LatLong}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data TripEndResp = TripEndResp {result :: EndTripStatus}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data TripLinkReq = TripLinkReq {routeCode :: Data.Text.Text, vehicleNumber :: Data.Text.Text}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data TripLinkResp = TripLinkResp {destination :: StopInfo, source :: StopInfo, tripTransactionId :: Data.Text.Text, vehicleNum :: Data.Text.Text, vehicleType :: Domain.Types.Common.ServiceTierType}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data TripStartReq = TripStartReq {location :: Kernel.External.Maps.Types.LatLong}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

data VehicleDetails = VehicleDetails {_type :: Domain.Types.Common.ServiceTierType, number :: Data.Text.Text}
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)
