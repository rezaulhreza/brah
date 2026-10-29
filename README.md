# Bruh

A helper that sits next to your cursor on the Mac. Hold a hotkey, ask about what is on the
screen, and your own agent answers out loud and points at the place.

Bruh only sees, listens, talks and points. The agent you connect does the thinking and any
clicking. Hermes is the first agent. Claude and OpenClaw come next.

## What it does

- **Sees your screen.** A screenshot of the display under the cursor, with the cursor marked,
  goes with each question. Bruh's own windows are not in it.
- **Listens.** Hold the hotkey and talk. Your words show while you talk.
- **Answers out loud.** The answer streams in, and the voice starts at the first sentence.
- **Points.** A ring and a label show the exact place on the screen.
- **Stops when you say.** Stop, mute and hide are each one key.

## Run it

Needs macOS 14 or later and Xcode.

```bash
BRUH_SIGN_IDENTITY="Apple Development" scripts/bundle.sh
open build/Bruh.app
```

On the first run, allow Bruh in System Settings > Privacy & Security for Screen Recording and
Microphone, then open Bruh again. Without `BRUH_SIGN_IDENTITY` the app is signed ad hoc, and
macOS asks for Screen Recording again after each build.

| Key | Action |
|---|---|
| Hold ⌃⌥Space | Talk. Release to send |
| Tap ⌃⌥Space | Type a question. Press again to close |
| ⌃⌥. | Stop: listening, the agent and the voice |
| ⌃⌥M | Mute or unmute the voice |
| ⌃⌥H | Hide everything |
| Esc | Stop while it works, close after |

Drag the bubble by its empty space to move it. It stays there until the next question.

### Change the shortcuts

Set any of them in `~/.config/bruh/config.json`, then reopen Bruh:

```json
{"shortcuts": {"talk": "cmd+shift+space", "stop": "ctrl+option+.", "mute": "ctrl+option+m", "hide": "ctrl+option+h"}}
```

Modifiers: `ctrl`, `option` (or `alt`), `shift`, `cmd`. Keys: letters, digits, `space`, `return`,
`tab`, `esc`, `.`, `,`, `/`, the arrows and `f1` to `f12`. Each shortcut needs a modifier, except a
function key. A shortcut that is not valid, or that two actions share, goes back to its default,
and Bruh says why in its log. The menu shows the shortcuts in use.

## Connect Hermes

Bruh calls the Hermes API server (`/v1/chat/completions`) and streams the answer. It finds the
key in this order:

1. `BRUH_HERMES_URL` and `BRUH_HERMES_KEY` in the environment.
2. `~/.config/bruh/config.json`: `{"hermes": {"url": "http://127.0.0.1:8642", "key": "..."}}`
3. `API_SERVER_KEY` in `~/.hermes/.env`, with the URL `http://127.0.0.1:8642`.

## Voice

**With the `deepgram-live` Hermes plugin**, Bruh uses your live voice: the Aura voice, the Flux
listening model, the speed and the key terms that you set under `deepgram_live` in the Hermes
config. The plugin keeps your Deepgram key on the host and gives Bruh tokens that last 30
seconds; Bruh then streams to Deepgram directly, as the Hermes desktop app does.

**Without that plugin**, Bruh speaks and listens with the voice of your Hermes: the speech-to-text and text-to-speech
providers you set in Hermes (Deepgram, ElevenLabs, Edge, OpenAI, local Whisper and others). When
the provider can stream, your words show while you talk and the answer is spoken while it
arrives. When it cannot, Bruh sends the whole recording and speaks the whole answer.

The voice routes, and the plugin, are on the Hermes dashboard (`hermes dashboard`, port 9119 by
default).

- **A local dashboard with no sign-in:** nothing to set. Bruh reads the session token that the
  dashboard gives to local pages.
- **A dashboard with a sign-in** (for example one with `dashboard.public_url`): give Bruh the
  same username and password that you use for the dashboard.

```json
{"hermes": {"voice": {"url": "http://127.0.0.1:9119", "username": "...", "password": "..."}}}
```

Both routes use this sign-in. The environment can set `BRUH_HERMES_VOICE_URL`,
`BRUH_HERMES_USERNAME` and `BRUH_HERMES_PASSWORD` instead. The menu shows which voice Bruh uses.

When Bruh cannot reach the Hermes voice, it uses the speech engines of macOS, with the best
installed voice for your language. The default macOS voices sound robotic. For a better one,
download a Premium or Enhanced voice in System Settings > Accessibility > Spoken Content >
System Voice > Manage Voices.

## Roadmap

1. **Hands-free mode.** A wake word starts a conversation. Bruh listens again after each answer,
   until an idle time-out or "bye". Talking over the voice stops it.
2. **The agent acts.** Hermes clicks and types through `computer_use` (cua-driver) when you ask,
   and Bruh shows each step with the pointer. Stop takes control back at once.
3. **More agents.** Claude and OpenClaw, with the same see, talk and point contract.
4. **Settings window.** Choose the agent, the voice and the shortcuts (with a key recorder)
   without a config file, with secrets in the Keychain.
5. **App Store build.** Sandboxed: Bruh keeps to seeing and pointing, and the agent acts.

## Icons

The app icon and the menu bar icon are SVG files in `Resources/icon`. After you change one, run
`scripts/icons.sh` (needs `brew install librsvg`). It makes every size macOS needs.

## Test

```bash
swift test
build/Bruh.app/Contents/MacOS/Bruh --ask "Where is the search field?"
build/Bruh.app/Contents/MacOS/Bruh --talk 5
```

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE.md). You can read, run and change Bruh for personal and
other noncommercial use. You cannot sell it, or use it in or for a business, without a separate
commercial licence from the author. For a commercial licence, open an issue on this repository.
