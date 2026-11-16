# README screenshots

These are captures of the actual native SwiftUI app in the iPhone 15 simulator, iOS 26.5. The live screen and transcript use synthetic data in a DEBUG-only fixture; they do not establish backend, CallKit or CarPlay behavior.

1. Generate the project and build a signed-for-Simulator Debug app using the README instructions.
2. Open it normally to capture the ready screen.
3. Relaunch it with the process argument `--showcase-conversation` for the synthetic listening view. The fixture opens no socket, records no microphone audio and contacts no providers.
4. Tap **Conversation transcript** to capture the transcript view.

Use the session-bound Device panel command or your supported simulator screenshot tool for the captures. Files are ready.png, conversation.png and transcript.png in this directory's images folder. There is no private host, device credential, real task or user conversation in these captures. Release builds do not contain the fixture.
