# Run Local (M1)

1. Build and install `provinode-scan` on iPhone Pro (LiDAR-capable).
2. Start `provinode-room` AppHost on the same LAN.
3. In Scan app:
   - tap `Start Pairing` in desktop shell or call `POST https://<host>:7448/pairing/start` so receiver is advertised on mDNS
   - approve Local Network access on first launch (required for Bonjour discovery)
   - discover/select desktop endpoint (preferred, includes TLS fingerprint metadata)
   - or enter manual host (desktop LAN IP) + pairing port + desktop pairing TLS fingerprint
   - pair using short code + nonce
   - scanner mTLS identity is provisioned automatically from pairing response
   - start stream (secure hello is signed automatically using persisted scanner identity key)
   - start capture
4. Stop capture to finalize local `RoomCaptureSession` artifact.
