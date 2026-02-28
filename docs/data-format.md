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

Mesh payload (`MeshAnchorBatch`, `format=mesh_anchor_batch_v2`) stores per-anchor:
- `identifier`
- `transform` (4x4 column-major float array)
- `vertices` (flattened xyz float array)
- `face_indices` (triangle index list, flattened)

Control payloads over encrypted channel:
- `BackpressureHint` from desktop to scan
- `ResumeCheckpoint` acknowledgements for reconnect/replay alignment
