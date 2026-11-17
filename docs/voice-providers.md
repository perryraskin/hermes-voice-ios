# Voice provider integration

Hermes owns reasoning and tools. Speech providers own speech recognition/output or the realtime audio session. The iPhone, CarPlay, CallKit and Live Activities share one `VoiceSession` regardless of provider.

## Current boundaries

- `Sources/VoiceProvider.swift`: provider IDs, display names, preference and capability selection. The persisted `fish_live3` ID is retained for compatibility; the user-facing name is Fish Audio.
- `Sources/FishVoiceTransport.swift`: native Fish/LiveKit session, microphone, transcript events and CallKit audio gating.
- `Sources/HermesApp.swift`: shared session state plus the current host WebSocket/PCM transport used by ElevenLabs. This transport has not yet been extracted into a generic adapter protocol.
- `server/fish_trial.py`: Fish session minting and scoped custom-LLM callback (filename retained for compatibility).
- `server/speech.py` and the `/v1/stream` route in `server/app.py`: ElevenLabs synthesis and realtime recognition.
- `/v1/capabilities`: `voice_providers` lists configured provider IDs. Readiness requires Hermes credentials and at least one provider. Legacy `fish_available` remains for older clients.

Provider readiness means configuration is present, not a successful provider health check. An explicitly advertised empty or unknown-only provider list must not start an unsupported transport. Older hosts without the list retain the previous capability behavior.

## Adding support

1. Add a stable ID and display name to `VoiceProvider`; choose an intentional fallback order. Never rename saved IDs to follow a model release.
2. Implement the provider transport and wire its selection into `VoiceSession.start`. Feed the existing state, transcript and mute properties; preserve generation guards so ended sessions cannot deliver late events.
3. Add host configuration/session routes and advertise the ID only when its required configuration is present. Keep long-lived credentials on the host. A new realtime provider may need its own protocol rather than the existing PCM transport.
4. Preserve CallKit activation/deactivation, mute/hold, cancellation and the attention broker's fixed-origin, read-back/confirmation rules. Provider switching must not create a second shared session or bypass decision authorization.
5. Test configuration absence, unknown providers, legacy compatibility, start/end, cancellation, reconnect ambiguity, audio interruption and incoming-call behavior. Validate physical iPhone/CarPlay routing separately.

This is explicit provider integration, not a claim that arbitrary voice APIs can be plugged in without code. Extract a shared transport protocol when a third integration establishes which lifecycle operations are actually common.

## Slow Fish turns

Fish's custom-LLM endpoint has a ten-second request deadline. The host waits up to five seconds for a complete Hermes answer. Longer turns receive a short acknowledgement while the original execution continues once in the background. Provider retries reuse the persisted execution rather than repeating tools.

During an active session, the updated app checks the private, device-authenticated `/v1/fish/sessions/{session}/results` route every two seconds. When the session is listening and recent user speech has stopped, it sends an opaque result marker through Fish's reliable `client-event` channel. The callback returns the stored answer for speech without starting another Hermes turn. Markers are scoped to the live session and cannot count as owner speech or decision confirmation. Polling stops when the session ends; this is not a scheduled agent task.

Deploy the host and updated app together: older apps can hear the acknowledgement but cannot retrieve the deferred answer. Results are not a durable inbox after hangup. An interrupted or uncertain execution is reported without automatically repeating a potentially completed action. This avoids the provider timeout; it does not make a slow specialist consultation finish faster.
