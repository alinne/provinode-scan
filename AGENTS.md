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

- Before broad exploration, generate bounded context from the Workbench root with `pwsh -NoProfile -File scripts/get-agent-context.ps1 -Repo <repo> [-Capability <handle>]`.
- Workbench `manifests/agent-contracts.json` and `manifests/agent-capabilities.json` determine applicable authority; read only the contracts selected by that packet.
- Follow Workbench `docs/contracts/agent-oriented-documentation-and-commenting-contract-v1.md`: document semantic boundaries and invariants, never target comment density or narrate syntax.
- Use `pwsh -NoProfile -File scripts/run.ps1 -Repo <repo> -Task doctor|build|test|verify|docs`; `not_applicable` requires the registered concrete reason.
- Keep navigation-critical documents current in `manifests/agent-documents.json`. Oversized or mixed-responsibility source units require decomposition or an explicit reviewed disposition.
- Measure success through routing, authority, implementation/test discovery, task availability, and verification completion—not prose volume.
