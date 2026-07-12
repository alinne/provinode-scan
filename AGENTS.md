# Provinode Scan AGENTS

- Native iOS codebase for LiDAR room capture and secure LAN streaming.
- Keep iOS minimum version at 17.0 unless a documented migration plan updates it.
- Capture schema and wire payloads must remain compatible with `provinode-room-contracts` major version.
- Do not add cloud-only dependencies for M1/M2 flows.

## Internal API Standard

- Current conformance state: shared payload contracts are `Adapter Client Guarded` consumers of `provinode-room-contracts`.
- Do not create new app-local schema drift for capture, session, trust, or LAN payloads that already have a shared contract source.
- Any new cross-process API or event contract introduced here must publish a durable artifact and identify whether it belongs in `apps/provinode-room-contracts` or a shared `linnaeus/*` contract foundation.
- Future startup/connect UX in this repo must consume the shared host-model, lifecycle, and error-code contracts instead of inventing Scan-only lifecycle language.
- If startup/connect errors are shown in-app, use native selectable text so the stable error code and detail can be copied by simple text selection whenever platform controls allow it.

## Workspace Agent Standard

- Context/applicability: use `scripts/get-agent-context.ps1`; `manifests/agent-contracts.json` selects exact capability contracts and sections.
- Documentation/code: follow `docs/contracts/agent-oriented-documentation-and-commenting-contract-v1.md`; explain invariants, never target comment density, and decompose oversized sources or record a reviewed disposition.
- Tasks/freshness: use `scripts/run.ps1` with `doctor|build|test|verify|docs`; keep `manifests/agent-documents.json` current.
- Success is correct routing, authority, code/test discovery, and verification—not prose volume.
