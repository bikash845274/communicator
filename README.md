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
| `lib/signaling.dart` | WebSocket + WebRTC peer-connection logic |
| `lib/broadcast_page.dart` | Captures mic, shows live indicator, mute/stop |
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

## Known follow-ups (not yet implemented)

- **Android background streaming:** permissions are declared, but a foreground
  service is needed to keep the mic alive when the app is backgrounded. Add the
  [`flutter_foreground_task`](https://pub.dev/packages/flutter_foreground_task)
  plugin and start a `microphone`-type service from `BroadcastPage`.
- **TURN server:** must be provisioned for cross-network use (see above).
- **Pairing UX:** room codes are typed; a QR-code share would be friendlier.
