# Run Local (M1)

1. Build and install `provinode-scan` on iPhone Pro (LiDAR-capable).
2. Start `provinode-room` AppHost on the same LAN.
3. In Scan app:
   - discover/select desktop endpoint
   - or enter manual host (desktop LAN IP) + pairing port
   - pair using short code + nonce
   - start capture
4. Stop capture to finalize local `RoomCaptureSession` artifact.
