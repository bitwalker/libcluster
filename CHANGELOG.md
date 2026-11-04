# Changelog

## Unreleased

- Add `kubernetes_poll_backoff` to `Cluster.Strategy.Kubernetes`, applying capped
  exponential backoff with jitter after a failed poll so a degraded API server is
  not polled at the fixed interval. Disabled by default.
- Explain mixed-version worker compatibility, staged rollouts and version-scoped discovery tradeoffs (#180).
- Explain DNS readiness, discovery retries and application-owned Mnesia bootstrap coordination (#111).
- Document named-port Kubernetes SRV queries, per-Pod identities and bounded distribution/mesh diagnostics (#149).
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

## 3.5.1 — 2026-11-01

[Published package](https://hex.pm/packages/libcluster/3.5.1) ·
[Matching source](https://github.com/bitwalker/libcluster/commit/1d2da143cacb29ad2e3321f2df6d1d3d87d30ebd)

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
- Correct the DNSPoll `polling_interval` option name in its documentation (#215).

## 3.5.0 — 2025-01-09

[Source](https://github.com/bitwalker/libcluster/commit/6d8c11f57b9bde9a047e2ea9276f19b58c371466) · [Changes](https://github.com/bitwalker/libcluster/compare/0d888303b4d3c0bd45d83baea36d2a5dd7100dea...6d8c11f57b9bde9a047e2ea9276f19b58c371466)

- Add `kubernetes_use_cached_resources` to Kubernetes discovery, requesting
  `resourceVersion=0` when enabled (#207).
- Correct Kubernetes query-parameter encoding with `URI.encode_query/2`.

## 3.4.1 — 2024-09-17

[Source](https://github.com/bitwalker/libcluster/commit/0d888303b4d3c0bd45d83baea36d2a5dd7100dea) · [Changes](https://github.com/bitwalker/libcluster/compare/cf6d4141d6c740a0a182b2bbc9caf18aa457c065...0d888303b4d3c0bd45d83baea36d2a5dd7100dea)

- Add telemetry events for successful and failed node connections and disconnections,
  including durations for successful operations.
- Add the `telemetry ~> 1.3` runtime dependency and raise the Elixir requirement
  from `~> 1.8` to `~> 1.13`.
- Correct the LocalEpmd module name in its documentation.

The earlier changelog labeled telemetry as 3.4.0. Hex has no published 3.4.0;
the verified 3.4.1 package first contains this feature.

## 3.3.3 — 2023-06-22

[Source](https://github.com/bitwalker/libcluster/commit/cf6d4141d6c740a0a182b2bbc9caf18aa457c065) · [Changes](https://github.com/bitwalker/libcluster/compare/256e58b49d7a4e153c3ec49029107d1057aadb74...cf6d4141d6c740a0a182b2bbc9caf18aa457c065)

- Add an optional Epmd connection retry timeout, defaulting to the existing
  one-time connection behavior (#183).
- Verify Kubernetes API TLS peers when a service-account `ca.crt` is present (#194).
  This version still permits unverified TLS when that file is absent; 3.5.1 makes
  verification mandatory.
- Use `Logger.warning/2` on supported Elixir versions, retaining the older fallback (#195).
- Expand Kubernetes setup and node-naming documentation (#185), and document LocalEpmd
  startup requirements.

## 3.3.2 — 2023-01-25

[Source](https://github.com/bitwalker/libcluster/commit/256e58b49d7a4e153c3ec49029107d1057aadb74) · [Changes](https://github.com/bitwalker/libcluster/compare/568209ac56cfb3ae41f5757ed8fc769099b657fc...256e58b49d7a4e153c3ec49029107d1057aadb74)

- Use the configured Gossip multicast interface when joining the multicast group (#165).
- Adjust Gossip port-reuse handling for Linux (#187); subsequent corrections are listed
  under Unreleased.
- Replace the explicit OTP application list with `extra_applications`, and remove the
  library config directory.
- Correct generated documentation source references to use bare version tags (#166).
- Add Mix release naming guidance and a DNSSRV namespace example (#172).

## 3.3.1 — 2022-01-18

[Source](https://github.com/bitwalker/libcluster/commit/568209ac56cfb3ae41f5757ed8fc769099b657fc) · [Changes](https://github.com/bitwalker/libcluster/compare/b5b2f068f1ff6e715a99748ff1b37d5fce74dc2d...568209ac56cfb3ae41f5757ed8fc769099b657fc)

- Use the supported `:aes_256_cbc` cipher name for encrypted Gossip messages (#161).

## 3.3.0

### Changed

- Default multicast address is now 233.252.1.32, was 230.1.1.251, [commit](https://github.com/bitwalker/libcluster/commit/449a65e14f152a83a0f8ee371f05743610cd292f)


## 2.3.0

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
