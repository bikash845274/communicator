# Audio Intercom

Listen to the live microphone of one phone from another phone — even when the
two phones are in different cities on different networks (WiFi or cellular).
Audio only, live only (nothing is recorded).

Built with Flutter (iOS + Android) and WebRTC. A tiny Node WebSocket server
pairs the two phones; the live audio flows peer-to-peer (or via a TURN relay).

> ⚠️ **Consent:** Use only on devices you own or with everyone's consent. The
> broadcasting phone always shows a visible "🔴 LIVE — mic is on" indicator.

## How it works

```
 Phone A (Broadcast)        Signaling server (Node/ws)        Phone B (Listen)
   mic ─► WebRTC ──ws──────► pairs by room code ◄──────ws── WebRTC ─► speaker
            └──────── audio flows P2P, or via TURN relay ────────┘
                         (STUN + TURN for NAT traversal)
```

- **Signaling server** (`server/`) only relays connection-setup messages. It
  never sees audio.
- **STUN** lets each phone find its public address (Google's free STUN is built in).
- **TURN** relays audio when a direct path is impossible. **Required for two
  phones on different networks** — without it, cross-network calls won't connect.

## Project layout

| Path | What |
|------|------|
| `lib/main.dart` | Home screen: enter room code, pick Broadcast or Listen |
| `lib/session.dart` | Keeps the session alive (foreground service, notification, auto-resume) |
| `lib/signaling.dart` | WebSocket + WebRTC logic, auto-reconnect, call handling |
| `lib/broadcast_page.dart` | Captures mic, auto-live indicator, pauses during calls |
| `lib/listen_page.dart` | Receives + plays remote audio, shows status |
| `lib/config.dart` | Signaling URL + STUN/TURN servers (**edit this**) |
| `server/index.js` | Node WebSocket signaling server |

## 1. Run the signaling server

```bash
cd server
npm install
npm start          # listens on :8080, health check at /health
```

For a real cross-city test, deploy this folder to Render / Railway / Fly.io and
use the resulting `wss://…` URL below.

## 2. Configure the app

Edit `lib/config.dart`:

- **`signalingUrl`**
  - Android emulator → host machine: `ws://10.0.2.2:8080` (default)
  - Real phones on same WiFi as your computer: `ws://<your-computer-LAN-IP>:8080`
  - Deployed: `wss://your-app.onrender.com`
  - Or override at launch without editing code:
    `flutter run --dart-define=SIGNALING_URL=wss://your-app.onrender.com`
- **`iceServers`** — uncomment and fill in the TURN entry for cross-network use.
  Get TURN credentials from self-hosted [coturn](https://github.com/coturn/coturn)
  or a managed provider (Cloudflare, Metered, Twilio).

## 3. Run the app

```bash
flutter pub get
flutter run            # pick a device; repeat on the second phone
```

On one phone tap **Broadcast**, on the other tap **Listen**, using the **same
room code**. Listener should hear the broadcaster within a second or two.

## Testing checklist

1. **Same WiFi:** works with STUN only (no TURN needed).
2. **Different networks (the real test):** put the broadcaster on cellular and
   the listener on WiFi. Requires TURN configured — proves NAT traversal.
3. **Background:** lock the broadcaster's screen; audio keeps flowing (iOS
   background-audio mode is enabled; on Android, see note below).
4. **Resilience:** toggle airplane mode briefly; the connection auto-recovers
   (ICE restart).

## Keeping it running reliably (phone settings)

The app runs in the background via a foreground service (persistent notification)
and auto-reconnects to the server. It also prompts to ignore battery optimization
on first start. But aggressive OEM battery managers — **Realme / OPPO (ColorOS)**
and **MIUI / HyperOS (Xiaomi/Redmi/POCO)** — will still kill it unless you allow
it. Do these on the **broadcasting** phone (the one you leave running):

0. **Do NOT hide the app.** A hidden app (App Hider / hidden space) is treated as
   inactive and killed within minutes, and can't be locked in Recents. Keep it
   visible if you want it to keep broadcasting.
1. **Auto-launch / Autostart → ON**
   Realme/ColorOS: Settings → Apps → **Auto-launch** → enable *audio_intercom*.
   MIUI: Settings → Apps → Manage apps → *audio_intercom* → **Autostart**.
2. **Allow background activity / No battery restriction**
   Realme: Settings → Battery → **App battery management** → *audio_intercom* →
   **Allow background activity** + **Allow auto-launch** (and turn OFF
   **"Sleep standby optimization"** in Battery settings — it kills apps when idle).
   MIUI: Settings → Apps → *audio_intercom* → **Battery saver → No restrictions**.
3. **Lock it in Recents** so "Clear all" won't kill it
   Recents (□) → swipe down on / long-press the app card → **Lock** 🔒.
4. **Exit with Home / Back / lock screen — never swipe it out of Recents.**
   Swiping from Recents kills the app (and the broadcast); backgrounding keeps it running.

**Optional — hide the notification banner** (Android requires the banner for the
foreground service, but you can turn it off in the OS): Settings → Apps →
*audio_intercom* → **Notifications → OFF**. Broadcasting keeps working; the green
OS mic indicator stays (it is not app-controllable).

**iPhone:** no special settings — iOS keeps background audio alive via the
background-audio mode; trust the developer profile + allow mic on first launch.
(iOS cannot auto-start after a reboot — reopen the app once.)

### Keep the free server awake

Render's free tier sleeps after ~15 min idle, which makes the listener wait
(or, on older builds, hang) on a cold start. Point a free uptime pinger at the
health endpoint so it never sleeps:

- **UptimeRobot** / **cron-job.org** → HTTP(s) monitor, 5-min interval, URL:
  `https://<your-app>.onrender.com/health`

While a broadcaster is actively connected the server stays warm on its own; the
pinger covers the gaps when nothing is connected.

## Deployment & install helpers

See `DEPLOY.md` for the full free deploy runbook (Render + Metered TURN). Local,
git-ignored helper scripts (they contain TURN credentials — never committed):

- `run.sh` — run on a tethered device with config baked in
- `build-apk.sh` — build a shareable release APK (Android installs by tapping it)
- `install-ios.sh` — build + install onto a connected iPhone (iOS has no
  tap-to-install file; the phone must be tethered, or use TestFlight)

## Known follow-ups (optional)

- **TURN server:** must be provisioned for cross-network use (see above).
- **Pairing UX:** room codes are typed; a QR-code share would be friendlier.
- **Survive "Clear all":** to keep broadcasting after the app is force-swiped from
  Recents, the audio engine would need to run inside the foreground-service
  isolate (larger rewrite). Today, use the Recents-lock + battery settings above.
