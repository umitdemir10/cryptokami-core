{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE ExistentialQuantification #-}

module Pos.Network.Types
       ( -- * Network configuration
         NetworkConfig (..)
       , NodeName (..)
       -- * Topology
       , StaticPeers(..)
       , Topology(..)
       -- ** Derived information
       , SubscriptionWorker(..)
       , topologyNodeType
       , topologySubscribers
       , topologyUnknownNodeType
       , topologySubscriptionWorker
       , topologyRunKademlia
       , topologyEnqueuePolicy
       , topologyDequeuePolicy
       , topologyFailurePolicy
       , topologyMaxBucketSize
       , topologyRoute53HealthCheckEnabled
       -- * Queue initialization
       , Bucket(..)
       , initQueue
       -- * Constructing peers
       , Valency
       , Fallbacks
       , choosePeers
       -- * DNS support
       , Resolver
       , resolveDnsDomains
       , initDnsOnUse
       -- * Helpers
       , HasNodeType (..)
       , getNodeTypeDefault
       -- * Re-exports
       -- ** from .DnsDomains
       , DnsDomains(..)
       -- ** from time-warp
       , NodeType (..)
       , MsgType (..)
       , Origin (..)
       -- ** other
       , NodeId (..)
       ) where

import           Universum hiding (show)

import           Data.IP (IPv4)
import           GHC.Show (Show (..))
import           Network.Broadcast.OutboundQueue (OutboundQ)
import qualified Network.Broadcast.OutboundQueue as OQ
import           Network.Broadcast.OutboundQueue.Types
import           Network.DNS (DNSError)
import qualified Network.DNS as DNS
import qualified Network.Transport.TCP as TCP
import           Node.Internal (NodeId (..))
import qualified System.Metrics as Monitoring
import           System.Wlog.CanLog (WithLogger)

import           Pos.Network.DnsDomains (DnsDomains (..), NodeAddr)
import qualified Pos.Network.DnsDomains as DnsDomains
import qualified Pos.Network.Policy as Policy
import           Pos.System.Metrics.Constants (cryptokamiNamespace)
import           Pos.Util.TimeWarp (addressToNodeId)
import           Pos.Util.Util (HasLens', lensOf)

{-------------------------------------------------------------------------------
  Network configuration
-------------------------------------------------------------------------------}

newtype NodeName = NodeName Text
    deriving (Show, Ord, Eq, IsString)

instance ToString NodeName where
    toString (NodeName txt) = toString txt

-- | Information about the network in which a node participates.
data NetworkConfig kademlia = NetworkConfig
    { ncTopology      :: !(Topology kademlia)
      -- ^ Network topology from the point of view of the current node
    , ncDefaultPort   :: !Word16
      -- ^ Port number to use when translating IP addresses to NodeIds
    , ncSelfName      :: !(Maybe NodeName)
      -- ^ Our node name (if known)
    , ncEnqueuePolicy :: !(OQ.EnqueuePolicy NodeId)
    , ncDequeuePolicy :: !OQ.DequeuePolicy
    , ncFailurePolicy :: !(OQ.FailurePolicy NodeId)
    , ncTcpAddr       :: !TCP.TCPAddr
      -- ^ External TCP address of the node.
      -- It encapsulates both bind address and address visible to other nodes.
    }

instance Show kademlia => Show (NetworkConfig kademlia) where
    show = show . showableNetworkConfig

data ShowableNetworkConfig kademlia = ShowableNetworkConfig
    { sncTopology    :: !(Topology kademlia)
    , sncDefaultPort :: !Word16
    , sncSelfName    :: !(Maybe NodeName)
    } deriving (Show)

showableNetworkConfig :: NetworkConfig kademlia -> ShowableNetworkConfig kademlia
showableNetworkConfig NetworkConfig {..} =
    let sncTopology    = ncTopology
        sncDefaultPort = ncDefaultPort
        sncSelfName    = ncSelfName
    in  ShowableNetworkConfig {..}

----------------------------------------------------------------------------
-- Topology
----------------------------------------------------------------------------

-- | Statically configured peers
--
-- Although the peers are statically configured, this is nonetheless stateful
-- because we re-read the file on SIGHUP.
data StaticPeers = forall m. (MonadIO m, WithLogger m) => StaticPeers {
      -- | Register a handler to be invoked whenever the static peers change
      --
      -- The handler will also be called on registration
      -- (with the current value).
      staticPeersOnChange :: (Peers NodeId -> m ()) -> IO ()
    }

instance Show StaticPeers where
    show _ = "<<StaticPeers>>"

-- | Topology of the network, from the point of view of the current node
data Topology kademlia =
    -- | All peers of the node have been statically configured
    --
    -- This is used for core and relay nodes
    TopologyCore {
        topologyStaticPeers :: !StaticPeers
      , topologyOptKademlia :: !(Maybe kademlia)
      }

  | TopologyRelay {
        -- We can use static peers or dynamic subscriptions.
        -- We typically use on or the other but not both.
        topologyStaticPeers :: !StaticPeers
      , topologyDnsDomains  :: !(DnsDomains DNS.Domain)
      , topologyValency     :: !Valency
      , topologyFallbacks   :: !Fallbacks
      , topologyOptKademlia :: !(Maybe kademlia)
      , topologyMaxSubscrs  :: !OQ.MaxBucketSize
      }

    -- | We discover our peers through DNS
    --
    -- This is used for behind-NAT nodes.
  | TopologyBehindNAT {
        topologyValency    :: !Valency
      , topologyFallbacks  :: !Fallbacks
      , topologyDnsDomains :: !(DnsDomains DNS.Domain)
      }

    -- | We discover our peers through Kademlia
  | TopologyP2P {
        topologyValency    :: !Valency
      , topologyFallbacks  :: !Fallbacks
      , topologyKademlia   :: !kademlia
      , topologyMaxSubscrs :: !OQ.MaxBucketSize
      }

    -- | We discover our peers through Kademlia, and every node in the network
    -- is a core node.
  | TopologyTraditional {
        topologyValency    :: !Valency
      , topologyFallbacks  :: !Fallbacks
      , topologyKademlia   :: !kademlia
      , topologyMaxSubscrs :: !OQ.MaxBucketSize
      }

    -- | Auxx simulates "real" edge nodes, but is configured with
    -- a static set of relays.
  | TopologyAuxx {
        topologyRelays :: ![NodeId]
      }
  deriving (Show)

----------------------------------------------------------------------------
-- Information derived from the topology
----------------------------------------------------------------------------

-- See the networking policy document for background to understand this
-- docs/network/policy.md

-- | Derive node type from its topology
topologyNodeType :: Topology kademlia -> NodeType
topologyNodeType TopologyCore{}        = NodeCore
topologyNodeType TopologyRelay{}       = NodeRelay
topologyNodeType TopologyBehindNAT{}   = NodeEdge
topologyNodeType TopologyP2P{}         = NodeEdge
topologyNodeType TopologyTraditional{} = NodeCore
topologyNodeType TopologyAuxx{}        = NodeEdge

-- | Type class which encapsulates something that has 'NodeType'.
class HasNodeType ctx where
    -- | Extract 'NodeType' from a context. It's not a 'Lens', because
    -- the intended usage is that context has topology and it's not
    -- possible to 'set' node type in topology.
    getNodeType :: ctx -> NodeType

-- | Implementation of 'getNodeType' for something that has
-- 'NetworkConfig' inside.
getNodeTypeDefault ::
       forall kademlia ctx. HasLens' ctx (NetworkConfig kademlia)
    => ctx
    -> NodeType
getNodeTypeDefault =
    topologyNodeType . ncTopology <$> view (lensOf @(NetworkConfig kademlia))

-- | Assumed type and maximum number of subscribers (if subscription is allowed)
--
-- Note that the 'TopologyRelay' case covers /both/ priviledged and
-- unpriviledged relays. See the networking policy document for full details of
-- why this makes sense or works.
topologySubscribers :: Topology kademlia -> Maybe (NodeType, OQ.MaxBucketSize)
topologySubscribers TopologyCore{}          = Nothing
topologySubscribers TopologyRelay{..}       = Just (NodeEdge, topologyMaxSubscrs)
topologySubscribers TopologyBehindNAT{}     = Nothing
topologySubscribers TopologyP2P{..}         = Just (NodeRelay, topologyMaxSubscrs)
topologySubscribers TopologyTraditional{..} = Just (NodeCore, topologyMaxSubscrs)
topologySubscribers TopologyAuxx{}          = Nothing

-- | Assumed type for unknown nodes
topologyUnknownNodeType :: Topology kademlia -> OQ.UnknownNodeType NodeId
topologyUnknownNodeType topology = OQ.UnknownNodeType $ go topology
  where
    go :: Topology kademlia -> NodeId -> NodeType
    go TopologyCore{..}      = const NodeRelay  -- to allow dynamic reconfig
    go TopologyRelay{..}     = const NodeEdge   -- since we don't trust anyone
    go TopologyTraditional{} = const NodeCore
    go TopologyP2P{}         = const NodeRelay  -- a fairly normal expected case
    go TopologyBehindNAT{}   = const NodeEdge   -- should never happen
    go TopologyAuxx{}        = const NodeEdge   -- should never happen

data SubscriptionWorker kademlia =
    SubscriptionWorkerBehindNAT (DnsDomains DNS.Domain)
  | SubscriptionWorkerKademlia kademlia NodeType Valency Fallbacks

-- | What kind of subscription worker do we run?
topologySubscriptionWorker :: Topology kademlia -> Maybe (SubscriptionWorker kademlia)
topologySubscriptionWorker = go
  where
    go TopologyCore{}          = Nothing
    go TopologyRelay{topologyDnsDomains = DnsDomains []}
                               = Nothing
    go TopologyRelay{..}       = Just $ SubscriptionWorkerBehindNAT
                                          topologyDnsDomains
    go TopologyBehindNAT{..}   = Just $ SubscriptionWorkerBehindNAT
                                          topologyDnsDomains
    go TopologyP2P{..}         = Just $ SubscriptionWorkerKademlia
                                          topologyKademlia
                                          NodeRelay
                                          topologyValency
                                          topologyFallbacks
    go TopologyTraditional{..} = Just $ SubscriptionWorkerKademlia
                                          topologyKademlia
                                          NodeCore
                                          topologyValency
                                          topologyFallbacks
    go TopologyAuxx{}   = Nothing

-- | Should we register to the Kademlia network? If so, is it essential that we
-- successfully join it (contact at least one existing peer)? Second component
-- is 'True' if yes.
topologyRunKademlia :: Topology kademlia -> Maybe (kademlia, Bool)
topologyRunKademlia = go
  where
    go TopologyCore{..}        = flip (,) False <$> topologyOptKademlia
    go TopologyRelay{..}       = flip (,) False <$> topologyOptKademlia
    go TopologyBehindNAT{}     = Nothing
    go TopologyP2P{..}         = Just (topologyKademlia, True)
    go TopologyTraditional{..} = Just (topologyKademlia, True)
    go TopologyAuxx{}          = Nothing

-- | Enqueue policy for the given topology
topologyEnqueuePolicy :: Topology kademia -> OQ.EnqueuePolicy NodeId
topologyEnqueuePolicy = go
  where
    go TopologyCore{}        = Policy.defaultEnqueuePolicyCore
    go TopologyRelay{}       = Policy.defaultEnqueuePolicyRelay
    go TopologyBehindNAT{..} = Policy.defaultEnqueuePolicyEdgeBehindNat
    go TopologyP2P{}         = Policy.defaultEnqueuePolicyEdgeP2P
    go TopologyTraditional{} = Policy.defaultEnqueuePolicyCore
    go TopologyAuxx{}        = Policy.defaultEnqueuePolicyEdgeBehindNat

-- | Dequeue policy for the given topology
topologyDequeuePolicy :: Topology kademia -> OQ.DequeuePolicy
topologyDequeuePolicy = go
  where
    go TopologyCore{}        = Policy.defaultDequeuePolicyCore
    go TopologyRelay{}       = Policy.defaultDequeuePolicyRelay
    go TopologyBehindNAT{..} = Policy.defaultDequeuePolicyEdgeBehindNat
    go TopologyP2P{}         = Policy.defaultDequeuePolicyEdgeP2P
    go TopologyTraditional{} = Policy.defaultDequeuePolicyCore
    go TopologyAuxx{}        = Policy.defaultDequeuePolicyEdgeBehindNat

-- | Failure policy for the given topology
topologyFailurePolicy :: Topology kademia -> OQ.FailurePolicy NodeId
topologyFailurePolicy = Policy.defaultFailurePolicy . topologyNodeType

-- | Maximum bucket size
topologyMaxBucketSize :: Topology kademia -> Bucket -> OQ.MaxBucketSize
topologyMaxBucketSize topology bucket =
    case bucket of
      BucketSubscriptionListener ->
        case topologySubscribers topology of
          Just (_subscriberType, maxBucketSize) -> maxBucketSize
          Nothing                               -> OQ.BucketSizeMax 0 -- subscription not allowed
      _otherBucket ->
        OQ.BucketSizeUnlimited

-- | Whether or not we want to enable the health-check endpoint to be used by Route53
-- in determining if a relay is healthy (i.e. it can accept more subscriptions or not)
topologyRoute53HealthCheckEnabled :: Topology kademia -> Bool
topologyRoute53HealthCheckEnabled = go
  where
    go TopologyCore{}        = False
    go TopologyRelay{}       = True
    go TopologyBehindNAT{..} = False
    go TopologyP2P{}         = False
    go TopologyTraditional{} = False
    go TopologyAuxx{}        = False

{-------------------------------------------------------------------------------
  Queue initialization
-------------------------------------------------------------------------------}

-- | The various buckets we use for the outbound queue
data Bucket =
    -- | Bucket for nodes we add statically
    BucketStatic

    -- | Bucket for nodes added by the behind-NAT worker
  | BucketBehindNatWorker

    -- | Bucket for nodes added by the Kademlia worker
  | BucketKademliaWorker

    -- | Bucket for nodes added by the subscription listener
  | BucketSubscriptionListener
  deriving (Eq, Ord, Enum, Bounded, Show)

-- | Initialize the outbound queue based on the network configuration
--
-- We add all statically known peers to the queue, so that we know to send
-- messages to those peers. This is relevant only for core nodes and
-- auxx. In the former case, those core nodes will in turn add this
-- core node to /their/ outbound queue because this node would equally be
-- a statically known peer; in the latter case, auxx is not expected
-- to receive any messages so messages in the reverse direction don't matter.
--
-- For behind NAT nodes and Kademlia nodes (P2P or traditional) we start
-- (elsewhere) specialized workers that add peers to the queue and subscribe
-- to (some of) those peers.
initQueue :: (MonadIO m, WithLogger m, FormatMsg msg)
          => NetworkConfig kademlia
          -> Maybe Monitoring.Store -- ^ EKG store (if used)
          -> m (OutboundQ msg NodeId Bucket)
initQueue NetworkConfig{..} mStore = do
    oq <- OQ.new (maybe "self" toString ncSelfName)
                 ncEnqueuePolicy
                 ncDequeuePolicy
                 ncFailurePolicy
                 (topologyMaxBucketSize   ncTopology)
                 (topologyUnknownNodeType ncTopology)

    case mStore of
      Nothing    -> return () -- EKG store not used
      Just store -> liftIO $ OQ.registerQueueMetrics (Just (toString cryptokamiNamespace)) oq store

    case ncTopology of
      TopologyAuxx peers -> do
        let peers' = simplePeers $ map (NodeRelay, ) peers
        void $ OQ.updatePeersBucket oq BucketStatic (\_ -> peers')
      TopologyBehindNAT{} ->
        -- subscription worker is responsible for adding peers
        return ()
      TopologyP2P{} ->
        -- Kademlia worker is responsible for adding peers
        return ()
      TopologyTraditional{} ->
        -- Kademlia worker is responsible for adding peers
        return ()
      TopologyCore{topologyStaticPeers = StaticPeers{..}} -> liftIO $
        staticPeersOnChange $ \peers -> do
          OQ.clearRecentFailures oq
          void $ OQ.updatePeersBucket oq BucketStatic (\_ -> peers)
      TopologyRelay{topologyStaticPeers = StaticPeers{..}} -> liftIO $
        staticPeersOnChange $ \peers -> do
          OQ.clearRecentFailures oq
          void $ OQ.updatePeersBucket oq BucketStatic (\_ -> peers)

    return oq

----------------------------------------------------------------------------
-- Constructing peers
----------------------------------------------------------------------------

-- | The number of peers we want to send to
--
-- In other words, this should correspond to the length of the outermost lists
-- in the OutboundQueue's 'Peers' data structure.
type Valency = Int

-- | The number of fallbacks for each peer we want to send to
--
-- In other words, this should corresponding to one less than the length of the
-- innermost lists in the OutboundQueue's 'Peers' data structure.
type Fallbacks = Int

-- | Construct 'Peers' from a set of potential peer nodes.
choosePeers :: Valency -> Fallbacks -> NodeType -> [NodeId] -> Peers NodeId
choosePeers valency fallbacks peerType =
      peersFromList mempty
    . fmap ((,) peerType)
    . transpose
    . take (1 + fallbacks)
    . mkGroupsOf valency
  where
    mkGroupsOf :: Int -> [a] -> [[a]]
    mkGroupsOf _ []  = []
    mkGroupsOf n lst = case splitAt n lst of
                         (these, those) -> these : mkGroupsOf n those

----------------------------------------------------------------------------
-- DNS support
----------------------------------------------------------------------------

type Resolver = DNS.Domain -> IO (Either DNSError [IPv4])

-- | Variation on resolveDnsDomains that returns node IDs
resolveDnsDomains :: NetworkConfig kademlia
                  -> [NodeAddr DNS.Domain]
                  -> IO [Either DNSError [NodeId]]
resolveDnsDomains NetworkConfig{..} dnsDomains =
    initDnsOnUse $ \resolve -> (fmap . fmap . fmap . fmap) addressToNodeId $
        DnsDomains.resolveDnsDomains resolve
                                     ncDefaultPort
                                     dnsDomains
{-# ANN resolveDnsDomains ("HLint: ignore Use <$>" :: String) #-}


-- | Initialize the DNS library whenever it's used
--
-- This isn't great for performance but it means that we do not initialize it
-- when we need it; initializing it once only on demand is possible but requires
-- jumping through too many hoops.
initDnsOnUse :: (Resolver -> IO a) -> IO a
initDnsOnUse k = k $ \dom -> do
    resolvSeed <- DNS.makeResolvSeed DNS.defaultResolvConf
    DNS.withResolver resolvSeed $ \resolver ->
      DNS.lookupA resolver dom
