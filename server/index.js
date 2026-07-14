// Tiny WebSocket signaling server for the audio intercom app.
//
// Responsibilities (and ONLY these):
//   - Group clients into rooms by a shared room code.
//   - Relay WebRTC signaling messages (offer / answer / ice) between the two
//     peers in a room.
//   - Tell peers when their partner joins or leaves.
//
// It never sees or carries audio — that flows directly between the phones via
// WebRTC (peer-to-peer, or relayed by your TURN server).
//
// Message protocol (JSON over WebSocket):
//   client -> server: { type: "join",  room: "ABC123" }
//   client -> server: { type: "offer"  | "answer" | "ice", room, payload }
//   server -> client: { type: "joined", peers: <number in room incl. self> }
//   server -> client: { type: "peer-joined" }      // a second peer arrived
//   server -> client: { type: "peer-left" }        // partner disconnected
//   server -> client: { type: "offer" | "answer" | "ice", payload }  // relayed
//   server -> client: { type: "error", message }

const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const MAX_PEERS_PER_ROOM = 2;

// room code -> Set<WebSocket>
const rooms = new Map();

// A minimal HTTP server so the host (Render/Railway/Fly) has a health check
// endpoint and so the WebSocket can share the same port.
const server = http.createServer((req, res) => {
  if (req.url === '/health' || req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('audio-intercom signaling: ok\n');
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server });

function send(ws, obj) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

// Send a message to every other peer in the same room.
function broadcastToPeers(room, sender, obj) {
  const peers = rooms.get(room);
  if (!peers) return;
  for (const peer of peers) {
    if (peer !== sender) send(peer, obj);
  }
}

function leaveRoom(ws) {
  const room = ws.room;
  if (!room) return;
  const peers = rooms.get(room);
  if (peers) {
    peers.delete(ws);
    broadcastToPeers(room, ws, { type: 'peer-left' });
    if (peers.size === 0) rooms.delete(room);
  }
  ws.room = null;
}

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.room = null;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (data) => {
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      send(ws, { type: 'error', message: 'invalid JSON' });
      return;
    }

    if (msg.type === 'join') {
      const room = String(msg.room || '').trim().toUpperCase();
      if (!room) {
        send(ws, { type: 'error', message: 'room code required' });
        return;
      }
      let peers = rooms.get(room);
      if (!peers) {
        peers = new Set();
        rooms.set(room, peers);
      }
      // Drop stale sockets first. When a phone's app is killed or it loses
      // network, its slot can linger until the heartbeat notices — which made a
      // reconnecting phone wrongly see "room full". Evict anything not OPEN.
      for (const p of [...peers]) {
        if (p.readyState !== p.OPEN) {
          peers.delete(p);
          if (p.room === room) p.room = null;
        }
      }
      if (peers.size >= MAX_PEERS_PER_ROOM) {
        send(ws, { type: 'error', message: 'room full' });
        return;
      }
      // Leave any previous room first.
      leaveRoom(ws);
      peers.add(ws);
      ws.room = room;
      send(ws, { type: 'joined', peers: peers.size });
      // Notify the existing peer that a partner arrived.
      broadcastToPeers(room, ws, { type: 'peer-joined' });
      console.log(`[join] room=${room} size=${peers.size}`);
      return;
    }

    // Relay signaling messages to the other peer in the room.
    if (msg.type === 'offer' || msg.type === 'answer' || msg.type === 'ice') {
      if (!ws.room) {
        send(ws, { type: 'error', message: 'join a room first' });
        return;
      }
      broadcastToPeers(ws.room, ws, { type: msg.type, payload: msg.payload });
      return;
    }

    send(ws, { type: 'error', message: `unknown message type: ${msg.type}` });
  });

  ws.on('close', () => leaveRoom(ws));
  ws.on('error', () => leaveRoom(ws));
});

// Drop dead connections so rooms don't leak (clients that vanished without close).
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
}, 15000);

wss.on('close', () => clearInterval(heartbeat));

server.listen(PORT, () => {
  console.log(`Signaling server listening on :${PORT}`);
});
