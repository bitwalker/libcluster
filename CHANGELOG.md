# Changelog

## Unreleased

- Use new cypher names
- Allow Epmd strategy to reconnect after connection failures
- Detect Self Signed Certificate Authority for Kubernetes Strategy
- Remove calls to deprecated `Logger.warn/2`
- Prune flag for DNSPoll strategy

### 3.3.0

### Changed

- Default multicast address is now 233.252.1.32, was 230.1.1.251, [commit](https://github.com/bitwalker/libcluster/commit/449a65e14f152a83a0f8ee371f05743610cd292f)


### 2.3.0

### Added

- Clustering strategy for the Rancher container platform (see: https://github.com/rancher/rancher)
- LocalEpmd strategy that uses epmd to discover nodes on the local host
- Gossip strategy multicast interface is used for adding multicast membership

## 2.0.0

### Added

- Configurable `connect` and `disconnect` options for implementing strategies
  on top of custom topologies
- The ability to start libcluster for more than a single topology
- Added `polling_interval` option to Kubernetes strategy
- Added ability to specify a list of hosts for the Epmd strategy to connect to on start

### Removed

- Cluster.Events module, as it was redundant and unused

### Changed

- Configuration format has changed significantly, please review the docs
