# Provinode Scan AGENTS

- Native iOS codebase for LiDAR room capture and secure LAN streaming.
- Keep iOS minimum version at 17.0 unless a documented migration plan updates it.
- Capture schema and wire payloads must remain compatible with `provinode-room-contracts` major version.
- Do not add cloud-only dependencies for M1/M2 flows.

## Internal API Standard

- Current conformance state: shared payload contracts are `Adapter Client Guarded` consumers of `provinode-room-contracts`.
- Do not create new app-local schema drift for capture, session, trust, or LAN payloads that already have a shared contract source.
- Any new cross-process API or event contract introduced here must publish a durable artifact and identify whether it belongs in `apps/provinode-room-contracts` or a shared `linnaeus/*` contract foundation.
