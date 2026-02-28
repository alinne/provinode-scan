# Capture Data Format

Session storage layout:
- `session.manifest.json`
- `samples.log`
- `blobs/sha256/<hash>`
- `integrity.json`

Capture sample kinds:
- `KeyframeRgb`
- `DepthFrame`
- `MeshAnchorBatch`
- `CameraPose`
- `Intrinsics`
- `Heartbeat`

Envelope fields include `session_id`, `sample_seq`, `capture_time_ns`, `clock_id`, and `hash_sha256`.
