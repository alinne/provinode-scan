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

## Clock-Centered Architecture Inheritance

- Inherit the workspace authority in `docs/architecture/clock-centered-engine-architecture-v1.md`; local instructions must not create a competing clock, resource, execution, artifact, or trust authority.
- The clock is Layer 0. LAN paths that require precision use genuine IEEE 1588/PTP with hardware timestamping; WAN paths federate site clock domains through authenticated transforms with explicit uncertainty, freshness, and holdover. Never label a monotonic or system-clock fallback as PTP.
- Resource declarations and scheduling evidence cover CPU/GPU/NPU, or mark a resource class explicitly `N/A`.
- Cross-boundary work follows the canonical operation/evidence/replay spine so intent, plans, work attempts, artifacts, evidence, and replay remain correlated.
- C++ is the default for reusable performance-sensitive hot paths, device/runtime integration, codecs, media, transport, geometry, native memory and synchronization, and CPU/GPU/NPU execution. Use C# only when managed contracts, orchestration, policy, services, SDK/CLI, or tooling materially make more sense, behind a stable ABI with thin wrappers. Do not perform blanket rewrites; migrations require measurements.
- This repository owns only Provinode Scan iOS UX, LiDAR capture, and secure-LAN adapter projections; shared spatial, clock, transport, trust, artifact, and reconstruction authority remains in the engine or versioned shared contracts.
