# Bruh

A helper that sits next to your cursor on the Mac. Hold a hotkey, ask about what is on the
screen, and your own agent answers out loud and points at the place.

Bruh only sees, listens, talks and points. The agent you connect does the thinking and any
clicking. Hermes is the first agent. Claude and OpenClaw come next.

## Run it

```bash
BRUH_SIGN_IDENTITY="Apple Development" scripts/bundle.sh
open build/Bruh.app
```

On the first run, allow Bruh in System Settings > Privacy & Security for Screen Recording and
Microphone, then open Bruh again.

| Key | Action |
|---|---|
| Hold ⌃⌥Space | Talk. Release to send |
| Tap ⌃⌥Space | Type a question. Press again to close |
| ⌃⌥. | Stop: listening, the agent and the voice |
| ⌃⌥M | Mute or unmute the voice |
| ⌃⌥H | Hide everything |
| Esc | Stop while it works, close after |

## Connect Hermes

Bruh calls the Hermes API server (`/v1/chat/completions`) and streams the answer. It finds the
key in this order:

1. `BRUH_HERMES_URL` and `BRUH_HERMES_KEY` in the environment.
2. `~/.config/bruh/config.json`: `{"hermes": {"url": "http://127.0.0.1:8642", "key": "..."}}`
3. `API_SERVER_KEY` in `~/.hermes/.env`, with the URL `http://127.0.0.1:8642`.

## Voice

Bruh uses the voice of your Hermes: the speech-to-text and text-to-speech providers you set in
Hermes (Deepgram, ElevenLabs, Edge, OpenAI, local Whisper and others). When the provider can
stream, your words show while you talk and the answer is spoken while it arrives. When it cannot,
Bruh sends the whole recording and speaks the whole answer.

The voice routes are on the Hermes web backend and need its sign-in:

```json
{"hermes": {"voice": {"url": "http://127.0.0.1:9130", "username": "...", "password": "..."}}}
```

The environment can set `BRUH_HERMES_VOICE_URL`, `BRUH_HERMES_USERNAME` and
`BRUH_HERMES_PASSWORD` instead. With no Hermes voice, Bruh uses the speech engines of macOS.

## Roadmap

1. **Hands-free mode.** A wake word starts a conversation. Bruh listens again after each answer,
   until an idle time-out or "bye". Talking over the voice stops it.
2. **The agent acts.** Hermes clicks and types through `computer_use` (cua-driver) when you ask,
   and Bruh shows each step with the pointer. Stop takes control back at once.
3. **More agents.** Claude and OpenClaw, with the same see, talk and point contract.
4. **Settings window.** Choose the agent, the voice and the hotkeys without a config file.
5. **App Store build.** Sandboxed: Bruh keeps to seeing and pointing, and the agent acts.

## Test

```bash
swift test
build/Bruh.app/Contents/MacOS/Bruh --ask "Where is the search field?"
build/Bruh.app/Contents/MacOS/Bruh --talk 5
```
