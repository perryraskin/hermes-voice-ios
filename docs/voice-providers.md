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
