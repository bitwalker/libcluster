# Changelog

## Unreleased

- Clarify Kubernetes runtime node naming, Mix release configuration and connection diagnostics (#121).
- Add `prune: false` to DNSPoll to keep peers connected when DNS returns rotating or partial
  answers. Pruning remains enabled by default (#190, #196).
- Exclude deleting and terminal pods, and pods without a usable IP, from Kubernetes pods-mode
  discovery. Live not-ready pods remain discoverable; document polling and shutdown behavior.
- Add opt-in Kubernetes EndpointSlice discovery with explicit label selection, complete paginated
  snapshots, IPv4/IPv6 support, readiness/termination filtering and a least-privilege Role example
  (#213). Failed or incomplete lists preserve membership; legacy lookup modes remain available.
- Add optional `kubernetes_trusted_peer_cert_file` for explicitly trusted self-signed Kubernetes
  API server certificates (#200). Peer mode verifies complete certificate identity, hostname,
  validity, signature and certificate constraints, supports overlapping certificates for rotation,
  and replaces CA trust only when configured. Default service-account CA verification is unchanged.
- Enable Gossip UDP port sharing using the native Winsock socket option on Windows (#206),
  restrict BSD socket constants to BSD/macOS, and report bind failures with port/interface context.
- Recover Gossip UDP reception after network error notifications without restarting discovery;
  report an explicit failure if the socket cannot be reactivated.
- Document Kubernetes shutdown coordination with supervised discovery (#114), backed by local
  distributed-node tests. Endpoint withdrawal alone does not prevent a departing node from
  reconnecting through its own strategies; stop discovery before planned readiness withdrawal.

## 3.5.1

- Always verify Kubernetes API TLS peers using the service-account CA. A missing or invalid
  `ca.crt` now prevents discovery instead of sending credentials to an unverified server (#214).
  Deployments must supply the CA that trusts their API server; verification cannot be disabled.
- Accept Kubernetes endpoint addresses without an optional `targetRef`, using the endpoint or
  requested namespace when needed; skip addresses without a usable hostname in hostname mode.
- Ignore malformed Gossip packets, invalid encrypted payloads/padding, and compressed external
  terms. The existing wire format is preserved; Gossip still requires a trusted network.
- Restore CI on Ubuntu 24.04 with Elixir 1.13/OTP 24.3 through Elixir 1.20/OTP 29,
  action dependency locking, workflow security checks, and package validation. OTP versions
  older than 24.3 are no longer tested; the Elixir requirement remains `~> 1.13`.
- Replace recorded Kubernetes HTTP tests with local HTTPS fixtures and remove ExVCR and
  its transitive test dependencies.

## 3.5.0

- Add `kubernetes_use_cached_resources` option to Kubernetes strategy

## 3.4.1

- Use new cypher names
- Allow Epmd strategy to reconnect after connection failures
- Detect Self Signed Certificate Authority for Kubernetes Strategy
- Remove calls to deprecated `Logger.warn/2`
- Correct misspell of 'Empd' -> 'Epmd' in `Cluster.Strategy.LocalEpmd` moduledoc

## 3.4.0

### Added

- Telemetry events added for tracking node connects and disconnects

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
