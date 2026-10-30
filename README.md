# Brah

Said "brah". A helper that sits next to your cursor on the Mac. Hold a hotkey, or say
"Hey Brah", ask about what is on the screen, and your own agent answers out loud and points at
the place. Ask it to do something, and it does it after your yes.

Brah sees, listens, talks and points. The agent you connect does the thinking and the clicking.
Hermes is the first agent. Claude and OpenClaw come next.

## What it does

- **Sees your screen.** A screenshot of the display under the cursor, with the cursor marked,
  goes with each question. Brah's own windows are not in it.
- **Listens.** Hold the hotkey and talk. Your words show while you talk.
- **Hands-free.** Say "Hey Brah" to start a conversation. Brah listens again after each answer,
  until you say "bye" or stop talking for a while. Talk over the voice to stop it. The wake word
  is heard on the Mac: no audio leaves it until you say "Hey Brah".
- **Answers out loud.** The answer streams in, and the voice starts at the first sentence. Echo
  cancellation keeps Brah from hearing itself.
- **Points.** A ring and a label show the exact place on the screen.
- **Acts, after your yes.** Ask it to do something on the screen. The agent says what it will do
  and waits. Click **Allow** or say "yes". Until then, the agent's screen tools are locked.
  The bubble shows each step. Stop locks the screen again at once.
- **Stops when you say.** The bubble has buttons to listen, mute, stop and close, and each has a
  key too. A copy button shows on the answer.

## Screen actions

Hermes acts on the screen with its `computer_use` tool, which Hermes leaves off for the API
server. Turn it on for the API server:

```bash
hermes tools enable computer_use --platform api_server
```

Brah locks the agent's screen tools until you allow an action. The lock needs the
`screen-remote` Hermes plugin; without it, the agent's promise to ask first is the only gate.
Screen actions only work with a Hermes on this Mac. A Hermes on a server would act on the server,
so Brah tells it not to.

## Run it

Needs macOS 14 or later and Xcode.

```bash
BRAH_SIGN_IDENTITY="Apple Development" scripts/bundle.sh
open build/Brah.app
```

On the first run, allow Brah in System Settings > Privacy & Security for Screen Recording,
Microphone and Speech Recognition, then open Brah again. Without `BRAH_SIGN_IDENTITY` the app is
signed ad hoc, and macOS asks for Screen Recording again after each build.

| Key | Action |
|---|---|
| Hold ⌃⌥Space | Talk. Release to send |
| Tap ⌃⌥Space | Type a question. Press again to close |
| ⌃⌥. | Stop: listening, the agent and the voice |
| ⌃⌥M | Mute or unmute the voice |
| ⌃⌥H | Hide everything |
| ⌃⌥J | Hands-free: listen for "Hey Brah", or stop |
| Esc | Stop while it works, close after |

Drag the bubble by its empty space to move it. It stays there until the next question.

### Change the shortcuts

Open **Settings** from the Brah menu. Under Shortcuts, click the shortcut of an action, then
press the new keys. Esc cancels. Brah does not accept a key that another action uses, and says
so under the action. Click **Save** to use the new shortcuts.

The Settings window writes `~/.config/brah/config.json`. You can also set the shortcuts in that
file yourself, then reopen Brah:

```json
{"shortcuts": {"talk": "cmd+shift+space", "stop": "ctrl+option+.", "mute": "ctrl+option+m", "hide": "ctrl+option+h", "handsFree": "ctrl+option+j"}}
```

Modifiers: `ctrl`, `option` (or `alt`), `shift`, `cmd`. Keys: letters, digits, `space`, `return`,
`tab`, `esc`, `.`, `,`, `/`, the arrows and `f1` to `f12`. Each shortcut needs a modifier, except a
function key. A shortcut that is not valid, or that two actions share, goes back to its default,
and Brah says why in its log. The menu shows the shortcuts in use.

## Connect Hermes

Brah calls the Hermes API server (`/v1/chat/completions`) and streams the answer. Hermes can
run on this Mac or on a server, for example a VPS behind a Cloudflare tunnel, or a computer on
your Tailscale network. Both `http://` and `https://` addresses work.

The easy way is the Settings window: open **Settings** from the Brah menu and fill in the Hermes
address and the API key under Agent. With no address, Brah uses `http://127.0.0.1:8642`. Brah
keeps the key in your Keychain, not in a file.

Brah finds the key in this order:

1. `BRAH_HERMES_URL` and `BRAH_HERMES_KEY` in the environment.
2. The Keychain, where the Settings window saves the key.
3. `~/.config/brah/config.json`: `{"hermes": {"url": "http://127.0.0.1:8642", "key": "..."}}`
4. `API_SERVER_KEY` in `~/.hermes/.env`, with the URL `http://127.0.0.1:8642`.

### Cloudflare Access

When Hermes is behind Cloudflare Access, make a service token in Cloudflare Zero Trust. Put its
client ID and client secret in Settings under Cloudflare Access. Brah sends them as the
`CF-Access-Client-Id` and `CF-Access-Client-Secret` headers to the Hermes address and to the
dashboard. Brah keeps both in the Keychain. The environment can set
`BRAH_CF_ACCESS_CLIENT_ID` and `BRAH_CF_ACCESS_CLIENT_SECRET` instead.

## Voice

**With the `deepgram-live` Hermes plugin**, Brah uses your live voice: the Aura voice, the Flux
listening model, the speed and the key terms that you set under `deepgram_live` in the Hermes
config. The plugin keeps your Deepgram key on the host and gives Brah tokens that last 30
seconds; Brah then streams to Deepgram directly, as the Hermes desktop app does.

**Without that plugin**, Brah speaks and listens with the voice of your Hermes: the speech-to-text and text-to-speech
providers you set in Hermes (Deepgram, ElevenLabs, Edge, OpenAI, local Whisper and others). When
the provider can stream, your words show while you talk and the answer is spoken while it
arrives. When it cannot, Brah sends the whole recording and speaks the whole answer.

The voice routes, and the plugin, are on the Hermes dashboard (`hermes dashboard`, port 9119 by
default).

- **A local dashboard with no sign-in:** nothing to set. Brah reads the session token that the
  dashboard gives to local pages.
- **A dashboard with a sign-in** (for example one with `dashboard.public_url`): give Brah the
  same username and password that you use for the dashboard.

Set the dashboard address, the username and the password in Settings under Voice. Brah keeps
the password in your Keychain. You can also put the address and the username in
`~/.config/brah/config.json`:

```json
{"hermes": {"voice": {"url": "http://127.0.0.1:9119", "username": "..."}}}
```

Older setups can keep `"password"` in that file too. Brah uses the Keychain password first.
Both routes use this sign-in. The environment can set `BRAH_HERMES_VOICE_URL`,
`BRAH_HERMES_USERNAME` and `BRAH_HERMES_PASSWORD` instead, and these win over the Settings
window. The menu shows which voice Brah uses.

When Brah cannot reach the Hermes voice, it uses the speech engines of macOS, with the best
installed voice for your language. The default macOS voices sound robotic. For a better one,
download a Premium or Enhanced voice in System Settings > Accessibility > Spoken Content >
System Voice > Manage Voices.

## Roadmap

1. **More agents.** Claude and OpenClaw, with the same see, talk and point contract.
2. **App Store build.** Sandboxed: Brah keeps to seeing and pointing, and the agent acts.

## Icons

The app icon and the menu bar icon are SVG files in `Resources/icon`. After you change one, run
`scripts/icons.sh` (needs `brew install librsvg`). It makes every size macOS needs.

## Test

```bash
swift test
build/Brah.app/Contents/MacOS/Brah --ask "Where is the search field?"
build/Brah.app/Contents/MacOS/Brah --talk 5
build/Brah.app/Contents/MacOS/Brah --converse
```

`--converse` starts a hands-free conversation as "Hey Brah" does. `BRAH_SNAPSHOT_PATH=/tmp/s.jpg`
saves the exact picture the agent gets.

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE.md). You can read, run and change Brah for personal and
other noncommercial use. You cannot sell it, or use it in or for a business, without a separate
commercial licence from the author. For a commercial licence, open an issue on this repository.
