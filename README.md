# Bruh

A helper that sits next to your cursor on the Mac. Press a hotkey, ask about what is on the
screen, and your own agent answers out loud and points at the place.

Bruh only sees, talks and points. The agent you connect does the thinking and any clicking.
Hermes is the first agent. Claude and OpenClaw come next.

## Run it

```bash
BRUH_SIGN_IDENTITY="Apple Development" scripts/bundle.sh
open build/Bruh.app
```

On the first run, allow Bruh in System Settings > Privacy & Security > Screen Recording, then
open Bruh again.

| Key | Action |
|---|---|
| ⌃⌥Space | Ask (press again to close) |
| ⌃⌥. | Stop the agent and the voice |
| ⌃⌥H | Hide everything |
| Esc | Stop while it thinks, close after |

## Connect Hermes

Bruh calls the Hermes API server (`/v1/chat/completions`). It finds the key in this order:

1. `BRUH_HERMES_URL` and `BRUH_HERMES_KEY` in the environment.
2. `~/.config/bruh/config.json`: `{"hermes": {"url": "http://127.0.0.1:8642", "key": "..."}}`
3. `API_SERVER_KEY` in `~/.hermes/.env`, with the URL `http://127.0.0.1:8642`.

## Test

```bash
swift test
build/Bruh.app/Contents/MacOS/Bruh --ask "Where is the search field?"
```
