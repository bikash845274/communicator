# Free deployment runbook

Two free services get this working across different networks:
**Render** (signaling) + **Metered** (TURN). ~15 minutes, no credit card for either.

---

## Step 1 — Put the code on GitHub
Render deploys from a Git repo.

```bash
cd "app communicator"
git init
git add .
git commit -m "Audio intercom app + signaling server"
# create an empty repo on github.com, then:
git remote add origin https://github.com/<you>/audio-intercom.git
git branch -M main
git push -u origin main
```
(Ask me to run these for you if you'd like.)

## Step 2 — Deploy the signaling server on Render (free)
1. Sign up at https://render.com (free, GitHub login works).
2. **New ► Blueprint**, pick your `audio-intercom` repo.
3. Render reads `render.yaml` and creates the `audio-intercom-signaling` web
   service on the **free** plan. Click **Apply**.
4. When it's live you get a URL like
   `https://audio-intercom-signaling.onrender.com`.
   Your signaling URL is the same with `wss://`:
   **`wss://audio-intercom-signaling.onrender.com`**
5. Test it: open the `https://…onrender.com/health` URL in a browser — it should
   say `audio-intercom signaling: ok`.

> Free Render services sleep after ~15 min idle. The first connection after a
> quiet spell takes ~30–50s to wake, then it's fast. Fine for personal use.

## Step 3 — Get free TURN credentials from Metered
1. Sign up at https://www.metered.ca (free tier ≈ 50 GB/month).
2. In the dashboard open **TURN Server ► Credentials** (or the "ICE Servers"
   snippet). You'll get values like:
   - URL: `turn:standard.relay.metered.ca:80` (or a `:443` variant)
   - Username: `<generated>`
   - Credential: `<generated>`
3. Keep these for Step 4.

## Step 4 — Run the app pointing at both
On each phone's build, pass the URLs at launch (no source editing):

```bash
flutter run \
  --dart-define=SIGNALING_URL=wss://audio-intercom-signaling.onrender.com \
  --dart-define=TURN_URL=turn:standard.relay.metered.ca:80 \
  --dart-define=TURN_USER=<your-metered-username> \
  --dart-define=TURN_PASS=<your-metered-credential>
```

Do this on both phones. On one tap **Broadcast**, the other **Listen**, same
room code.

To bake the values into a release build instead, use the same flags with
`flutter build apk` / `flutter build ios`.

## Step 5 — Verify the cross-network path
Put the **broadcaster on cellular data** and the **listener on WiFi** (or two
different cities). If the listener hears audio, TURN + signaling are working.
If it connects only on the same WiFi but not across networks, the TURN
credentials aren't being applied — recheck the `--dart-define` TURN flags.

---

### Quick reference
| Thing | Value |
|---|---|
| Signaling URL | `wss://<your-render-service>.onrender.com` |
| TURN URL / user / pass | from Metered dashboard |
| Health check | `https://<your-render-service>.onrender.com/health` |
