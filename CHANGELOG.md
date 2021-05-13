# Changelog

## Unreleased

### Added

- Clustering strategy for the Rancher container platform (see: https://github.com/rancher/rancher)
- LocalEpmd strategy that uses epmd to discover nodes on the local host

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
