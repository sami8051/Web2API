# web-to-api

Turn free web AI chat sessions into a **local OpenAI-compatible API**.

Use DeepSeek, Kimi, and Qwen through their browser interfaces — no official API keys required. Any tool that speaks the OpenAI Chat Completions API (Cursor, Open WebUI, custom scripts) can connect to `http://127.0.0.1:3456/v1`.

**The project is maintained.** This update retargets the adapters to the current DeepSeek, Kimi, and Qwen site APIs and session formats.

**Most people never touch the CLI after install** — everything runs through the built-in **Web Dashboard** at `http://127.0.0.1:3456`.

![Web dashboard — providers, session import, ops](img/ui_demo.jpg)

## Windows: one-command install (Web2API)

**Web2API** = this upstream project + a Windows installer and system-tray launcher. One PowerShell command (not admin) installs **or updates** everything: Node.js (if missing, with your consent), the latest [`PruhaNLP/web-to-api`](https://github.com/PruhaNLP/web-to-api), its dependencies and build, the tray launcher, an optional start-at-sign-in entry, and starts the API on port **3456**.

```powershell
irm https://raw.githubusercontent.com/sami8051/Web2API/main/install.ps1 | iex
```

It asks before installing Node.js (via `winget`) and before adding the sign-in startup entry. When it finishes you get the dashboard at `http://127.0.0.1:3456/`, the API at `http://127.0.0.1:3456/v1`, and a status dot near the clock (green running, amber starting, red error, grey stopped) with a menu: **Start, Stop, Restart, Open Dashboard, Open API, Open Logs, Start with Windows, Exit**. The API restarts automatically if it crashes.

Extra options need the script-block form (`irm | iex` cannot take switches):

```powershell
$i = [scriptblock]::Create((irm https://raw.githubusercontent.com/sami8051/Web2API/main/install.ps1))
& $i -Yes                      # no prompts (accepts Node.js install + startup entry)
& $i -NoStartup                # do not create/refresh the sign-in startup entry
& $i -Port 3457                # other port (remembered for later updates)
```

### Update

Run the install command again. It checks the upstream commit; if unchanged it only refreshes the launcher and makes sure the API is running. If upstream moved, it builds the new version **in a staging folder** (`npm ci`, `npm run build`, a smoke test that the CLI flags the launcher needs still exist), and only then swaps it in. A failed download, build or smoke test leaves your running version untouched and prints the log path. `-Force` rebuilds even if unchanged; `-UpstreamRef <tag|sha>` installs a specific upstream version (it is not remembered, a plain re-run follows `main` again).

### Rollback

The previous build is kept. Run:

```powershell
& $i -Rollback
```

### Uninstall

```powershell
& $i -Uninstall               # stops the tray + API, removes the startup entry and the install folder; KEEPS your data
& $i -Uninstall -RemoveData   # also deletes sessions/settings and the Chrome profile (you must type DELETE; -Yes skips that)
```

### What goes where

| Path | Contents | Touched by update / rollback / uninstall? |
|------|----------|-------------------------------------------|
| `%LOCALAPPDATA%\Web2API\app` (+ `app.prev`) | upstream build | replaced on update, removed on uninstall |
| `%LOCALAPPDATA%\Web2API\launcher` | our tray launcher; a locally edited copy is backed up as `*.bak-<time>` before being replaced | replaced / removed |
| `%LOCALAPPDATA%\Web2API\install.json`, `logs\` | installed commit, port, paths; installer logs | removed on uninstall |
| `%USERPROFILE%\.web-to-api` | sessions, auth flags, settings, API logs | **kept** unless `-RemoveData` |
| `%USERPROFILE%\web-to-api\chrome-profile` | Chrome profile with your logins | **kept** unless `-RemoveData` |
| `shell:startup\web-to-api.lnk` | start-at-sign-in entry | created with consent, removed on uninstall |

Safety behaviour: only one tray and one installer can run at once; if port 3456 is held by another program the installer and tray report it (name and PID) and retry until it is free, they never kill it and never silently move to another port; `-RemoveData` refuses any path that is not a sub-folder of your user profile. Log files: `%USERPROFILE%\.web-to-api\logs` (tray: **Open Logs**).

### How this repo relates to upstream

The repository root is a snapshot of upstream `PruhaNLP/web-to-api` (so `git clone` + `npm run dev` still work for development); Web2API's own files are `install.ps1` and `scripts/windows/`. **The installer does not use that snapshot**: it downloads the current upstream into the disposable `app\` folder and records the exact commit in `install.json`, so upstream updates reach users without anyone merging them here, and our launcher never gets overwritten by an upstream change. Customise via installer options (port, state dir, Chrome profile are remembered in `install.json`); do not hand-edit `app\`, it is replaced on update.

> Security note: the one-liner runs a script from this repository, then downloads and builds third-party code (upstream + its npm dependencies) on your machine. Read [`install.ps1`](install.ps1) first if you want to; it is short and does nothing outside the folders in the table above.

## Start here (Web UI)

1. **Install & start** (one time):

   ```bash
   git clone https://github.com/PruhaNLP/web-to-api.git
   cd web-to-api
   npm install
   npm run build
   npm run dev -- --browser-mode launch --port 3456
   ```

   Your browser should open the dashboard. If not, go to **http://127.0.0.1:3456** manually.

2. **Copy the API URL** — top bar shows `http://127.0.0.1:3456/v1`. Click **Copy** and paste it into Cursor, Open WebUI, or any OpenAI client. API key can be anything (e.g. `local`).

3. **Import your login** — middle panel **Session Import**:
   - **Kimi** — on kimi.ai run `copy(localStorage.getItem('refresh_token'))` and paste that JWT. Access tokens (~15 min) are rejected.
   - **DeepSeek** — DevTools → Console → **Console Export**. Auth is `userToken` / `settingsJwt` in localStorage (`deepseek-state.json`). Cookie-Editor no longer has the JWT.
   - **Qwen** — Cookie-Editor `qwen.json` **and** Console state `qwen-state.json`.
   - Click **Import Session** — saved to `~/.web-to-api/imports/` and applied immediately.

4. **Check it works** — right panel **Ops** tab → **Check All** or **Deep Test**. Green = ready.

5. **Connect your app** — use model `auto` (tries providers in order) or copy a model ID from the provider cards (dropdown + **Copy ID**).

That’s it. No curl, no manual file paths unless you prefer them.

### Dashboard tabs

| Tab | What it’s for |
|-----|----------------|
| **Ops** | Health checks, smoke tests, re-import sessions, Telegram test alert |
| **Settings** | Auto model order, Telegram error alerts (proxy + bot token + chat ID) |
| **Logs** | Live `server.log` — auto-refreshes and scrolls to newest lines |

### When you need the command line

- **Headless VPS** (no browser on the server): copy JSON files into `~/.web-to-api/imports/` and restart — see [Provider session requirements](#provider-session-requirements).
- **Proxy** (blocked sites): add `--proxy-server`, `--proxy-user`, `--proxy-pass` to the start command — same proxy you use in a browser.
- **Don’t open browser on start**: `--no-open` and open the dashboard URL yourself.

## How it works

```text
Your client (OpenAI SDK, Cursor, curl, …)
  → http://127.0.0.1:3456/v1
  → web-to-api
  → Playwright Chromium (saved login session)
  → chat.deepseek.com / kimi.ai / chat.qwen.ai
```

The server reuses your browser cookies and session state. It does not store vendor API keys.

## Features

- **Web dashboard** — visual setup: session import, health, ops, settings, logs (no CLI required for day-to-day use)
- **OpenAI-compatible API** — `GET /v1/models`, `POST /v1/chat/completions` (stream + non-stream)
- **Three providers** — DeepSeek Instant/Expert (± thinking), Kimi K2.6 (± thinking), Qwen 3.8 / 3.7 / 3.6
- **`auto` model** — tries models in order until one succeeds
- **Pseudo tool calls** — prompt-based tool calling for clients that expect OpenAI `tool_calls`
- **Structured output** — `response_format` via prompt + JSON parse
- **Headless-friendly** — launch mode, HTTP proxy, systemd install

## Web dashboard (details)

The dashboard is the main interface. After `npm run dev`, open **http://127.0.0.1:3456**.

**Top bar** — API base URL with one-click copy, server health, uptime, browser status.

**Providers (left)** — see which sites are logged in, pick a model from the dropdown, **Copy ID** for your client config.

**Session Import (center)** — Kimi: paste `refresh_token`. DeepSeek: one Console state file. Qwen: cookies + Console state. Files land in `~/.web-to-api/imports/` and reload on restart.

**Right panel**
- **Ops** — Check All, Deep Test, Re-import Sessions, Telegram test
- **Settings** — auto model fallback order, Telegram alerts (HTTP proxy if `api.telegram.org` is blocked)
- **Logs** — tail of `~/.web-to-api/logs/server.log`

**Interactive login** — if you have a display (desktop or Xvfb), you can log in through Chrome from the provider cards instead of importing files. On a headless VPS, use Session Import only.

## Quick start (CLI reference)

### Requirements

- Node.js 20+
- Google Chrome or Chromium

### Install & run

Same as [Start here](#start-here-web-ui). Minimal one-liner after clone:

```bash
npm install && npm run build && npm run dev -- --browser-mode launch --port 3456
```

### Display & headless (Linux)

Chromium runs **headed** (window) when `DISPLAY` is set, **headless** when it is not. There is no single correct value — it depends on your machine.

| Setup | What to do |
|-------|------------|
| **Desktop** (monitor connected) | Run as above. `DISPLAY` is usually already set (e.g. `:0` or `:1`). Dashboard → Login works. |
| **VPS / SSH, no GUI** | **Recommended:** export session JSON into `~/.web-to-api/imports/` — API works without any display. |
| **VPS but you need a visible browser** (login, debugging) | Start a **virtual display** (Xvfb), then export `DISPLAY` to it. |

**Virtual display example** (headless server, when you need headed Chrome):

```bash
# once: sudo apt install xvfb   (or xvfb-run on some distros)

Xvfb :99 -screen 0 1920x1080x24 &
export DISPLAY=:99   # any free number (:99, :100, …) — not mandatory

npm run dev -- --browser-mode launch --port 3456 --no-open
```

Use `echo $DISPLAY` on your desktop to see what you already have — do not copy `:99` unless you started Xvfb on that number.

**Without `DISPLAY`:** launch mode still works; Playwright uses headless Chromium. That is enough if sessions come from import files. Interactive Dashboard login is awkward without a real or virtual display — prefer **Session Import** on servers.

On a **headless server**, do **not** rely on Dashboard → Login unless you run Xvfb (or similar). Use **session file import** (see below).

Verify:

```bash
curl http://127.0.0.1:3456/admin/health
curl http://127.0.0.1:3456/v1/models
curl http://127.0.0.1:3456/admin/imports   # import folder + provider specs
```

### Smoke test

```bash
curl http://127.0.0.1:3456/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "Reply with one word: ok"}],
    "stream": false
  }'
```

## Client configuration

Point any OpenAI-compatible client at:

```text
Base URL:  http://127.0.0.1:3456/v1
API key:   any string (ignored unless --auth-token is set)
```

Use **`/v1/chat/completions`**, not `/v1/responses`.

Example with the OpenAI Node SDK:

```typescript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'http://127.0.0.1:3456/v1',
  apiKey: 'local',
});

const res = await client.chat.completions.create({
  model: 'auto',
  messages: [{ role: 'user', content: 'Hello!' }],
});
console.log(res.choices[0].message.content);
```

## Models

| Model ID | Provider |
|----------|----------|
| `auto` | Fallback chain (recommended) |
| `deepseek-web/deepseek-instant` | DeepSeek |
| `deepseek-web/deepseek-instant-thinking` | DeepSeek |
| `deepseek-web/deepseek-expert` | DeepSeek |
| `deepseek-web/deepseek-expert-thinking` | DeepSeek |
| `kimi-web/kimi-k2.6` | Kimi |
| `kimi-web/kimi-k2.6-thinking` | Kimi |
| `qwen-web/qwen3.8-max` | Qwen |
| `qwen-web/qwen3.7-plus` | Qwen |
| `qwen-web/qwen3.7-max` | Qwen |
| `qwen-web/qwen3.6-plus` | Qwen |

## CLI options

```bash
web-to-api [options]

  -p, --port <port>              Listen port (default: 3456)
  --host <host>                  Bind address (default: 127.0.0.1)
  --auth-token <token>           Require Bearer token for /v1 and /admin
  --browser-mode <mode>          attach | launch (default: attach; use launch on headless)
  --chrome-profile <dir>         Chrome user data directory
  --proxy-server <url>           HTTP proxy for browser traffic
  --proxy-user / --proxy-pass    Proxy credentials
  --state-dir <dir>              Data directory (default: ~/.web-to-api)
  --no-open                      Skip opening dashboard
```

## Data layout

Runtime files never live in the project root.

```text
~/.web-to-api/                 # WTA_STATE_DIR — runtime data
  auth.json                    # provider auth flags
  settings.json                # auto model order, Telegram alerts, etc.
  logs/
  imports/                     # drop session JSON here
    deepseek-state.json        # Console localStorage (userToken / settingsJwt)
    kimi.json                  # refresh_token only
    qwen.json                  # Cookie-Editor
    qwen-state.json            # Console localStorage

~/web-to-api/
  chrome-profile/              # persistent login when you have a display
```

On startup the server auto-imports any files found in `imports/`.

## Provider session requirements

| Provider | Headless (no VNC) | Import file | What must be in the export |
|----------|-------------------|-------------|----------------------------|
| **DeepSeek** | ✅ import or profile | `deepseek-state.json` | Console localStorage (`userToken` / `settingsJwt`). Cookie-Editor no longer has the JWT |
| **Kimi** | ✅ import | paste `refresh_token` | `localStorage.refresh_token` from kimi.ai. Access JWT (~15 min) is rejected |
| **Qwen** | ✅ import | `qwen.json` + `qwen-state.json` | Cookie-Editor cookies **and** Console localStorage (`token`) |

**Headless workflow (proven):**

1. Export each provider as in the table above (Kimi: refresh JWT text; DeepSeek: Console state; Qwen: cookies + state).
2. Copy to `~/.web-to-api/imports/` (`kimi.json`, `deepseek-state.json`, `qwen.json` + `qwen-state.json`).
3. Start server — auto-import on boot — or run `npm run cookies:refresh`.
4. Smoke: `curl …/v1/chat/completions` with `"model": "qwen-web/qwen3.8-max"`.

**With a display** (local PC): you can also log in via Dashboard → Login or use a persistent Chrome profile at `~/web-to-api/chrome-profile/`.

Supported import formats:

- Cookie Editor array: `[{ "name": "...", "value": "...", "domain": "..." }]`
- Custom object: `{ "origin": "...", "cookies": "...", "localStorage": { ... } }`
- Playwright `storageState`: `{ "cookies": [...], "origins": [...] }`

API: `GET /admin/imports` returns the full spec for each provider.

## Cookie / session refresh

```bash
# 1. Put files in ~/.web-to-api/imports/
# 2. Either restart the server (auto-import) or:
npm run cookies:refresh
npm run cookies:refresh -- --status
```

Or use dashboard **Session Import** or **Ops → Re-import Sessions** (applies immediately and saves to `imports/`).

## Windows tray launcher from a git checkout (developers)

If you cloned this repo instead of using the installer, [`scripts/windows/web-to-api-tray.ps1`](scripts/windows/web-to-api-tray.ps1) runs the checkout in the background with the same tray menu (Windows PowerShell 5.1, no extra dependencies). It runs, detected from `package.json` at each start: `npm run start` if defined, else the built `bin` entry (`node dist/cli.js`) when newer than `src/`, else `npm run dev`; always with `--no-open --browser-mode launch --port 3456`. Stop sends Ctrl+C so the CLI closes Chrome cleanly, then force-kills the process tree if needed.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\web-to-api-tray.ps1             # run now
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\web-to-api-tray.ps1 -Install    # + start at sign-in (asks first)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\web-to-api-tray.ps1 -Uninstall  # remove startup entry, close tray
```

The dashboard's **Restart** button uses systemd and does nothing on Windows; use the tray's Restart.

## Environment variables

| Variable | Description |
|----------|-------------|
| `WTA_PORT` | Listen port |
| `WTA_HOST` | Bind address |
| `WTA_AUTH_TOKEN` | API bearer token |
| `WTA_STATE_DIR` | Runtime data directory (default `~/.web-to-api`) |
| `WTA_IMPORTS_DIR` | Session import folder (default `$WTA_STATE_DIR/imports`) |
| `WTA_PROXY_SERVER` | Browser HTTP proxy |
| `WTA_PROXY_USER` / `WTA_PROXY_PASS` | Proxy auth |
| `WTA_TELEGRAM_BOT_TOKEN` | Error alerts (optional; also configurable in Settings tab) |
| `WTA_TELEGRAM_CHAT_ID` | Telegram chat ID |
| `WTA_TELEGRAM_PROXY_SERVER` | HTTP proxy for Telegram Bot API (Settings tab) |
| `WTA_TELEGRAM_PROXY_USER` / `WTA_TELEGRAM_PROXY_PASS` | Telegram proxy auth |
| `DISPLAY` | X11 display for headed Chromium (`:0` desktop, `:99` Xvfb, etc.) |

## Admin API

Management endpoints — all available in the dashboard; use these only if you automate outside the Web UI:

| Endpoint | Description |
|----------|-------------|
| `GET /admin/health` | Server & provider health |
| `GET /admin/providers` | Provider list & auth status |
| `POST /admin/auth/login` | Start browser login flow |
| `POST /admin/auth/import-state` | Import cookies / storage state |
| `GET /admin/imports` | Import folder path + provider session specs |

## Development

```bash
npm run typecheck
npm run test:unit
npm run dev
```

## Security

- Binds to `127.0.0.1` by default — do not expose publicly without `--auth-token`.
- Session cookies live in the Chromium profile and state directory. Do not commit them.
- Use a dedicated browser profile, not your daily driver.

## Known limitations & risks

This project automates free web chat UIs. That works, but it comes with real trade-offs. Read this before relying on it in production.

### Terms of service & account risk

- You are using **unofficial** access paths, not vendor APIs.
- DeepSeek, Kimi, and Qwen may change their web UI, block automation, rate-limit, or **suspend accounts** if they detect non-browser usage patterns.
- High request volume, headless browsers, datacenter IPs, or shared proxies increase that risk.
- **This is not a substitute for a paid API** if you need stability, SLA, or compliance.

### Reliability

- Web endpoints change without notice. A provider can break overnight until the adapter is updated.
- **`auto` fallback** helps, but if all models fail you still get errors — there is no guaranteed uptime.
- Qwen uses DOM automation (typing into the page). It is slower and more fragile than direct API calls.
- Sessions expire. Cookies go stale; you may need to re-login or re-import state files.
- Reasoning / tool-call output is **pseudo** — parsed from model text, not native vendor function calling. Complex agents may mis-parse JSON.

### Security & privacy

- **Session cookies = full account access.** Anyone with your state dir, Chrome profile, or an open API port can use your logged-in sessions.
- Default bind is localhost, but `--host 0.0.0.0` without `--auth-token` exposes your sessions to the network.
- The dashboard and `/admin/*` routes can import cookies and trigger logins. Protect them the same way as the API.
- Do **not** commit `deepseek-state.json`, `kimi.json`, `qwen.json`, `qwen-state.json`, or Chrome profile directories. They contain live session material.
- Proxy credentials in env vars or systemd units must stay off public repos and shared logs.

### Operational issues

- **Headless + proxy** setups are harder to debug than local Chrome with a visible window. On a VPS without GUI, use session import; use Xvfb only if you need headed login/debug.
- Snap Chromium on Linux cannot use profiles inside dot-folders in `$HOME`; use `~/web-to-api/chrome-profile` or similar.
- One Chromium profile per instance. Running multiple servers on the same profile can corrupt locks or sessions.
- Long conversations are collapsed into one web prompt. Very large histories may truncate, slow down, or confuse the model.
- Streaming is emulated for some paths (`auto`, pseudo tools): the server may wait for a full response before emitting SSE chunks.

### Client compatibility

- Implements **`/v1/chat/completions` only** — not `/v1/responses`, `/v1/embeddings`, or Anthropic `/v1/messages`.
- Clients that require native tool calling, strict JSON schema enforcement, or vision may not work as expected.
- Model IDs are bridge-specific (`deepseek-web/...`), not identical to official API model names.

### Legal & ethical

- You are responsible for how you use the tool and for complying with each provider's terms and local law.
- Do not use this to bypass paywalls, scrape at scale, or resell access without understanding vendor policies.

## License

MIT — see [LICENSE](LICENSE).
