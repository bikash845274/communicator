import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';

/// Connection lifecycle states surfaced to the UI.
enum CallState {
  idle,
  connecting, // websocket open, waiting for / negotiating with the peer
  live, // media flowing
  paused, // mic temporarily released because the phone is on a call
  reconnecting,
  failed,
}

typedef StateCallback = void Function(CallState state, String? detail);

/// Handles the WebSocket signaling exchange and the WebRTC peer connection.
///
/// One instance per session. Set [isBroadcaster] to true on the phone that
/// shares its microphone, false on the phone that listens.
class Signaling {
  Signaling({
    required this.room,
    required this.isBroadcaster,
    required this.clientId,
    this.onState,
  });

  final String room;
  final bool isBroadcaster;
  final String clientId;
  final StateCallback? onState;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  bool _peerPresent = false;
  bool _closed = false;

  // Signaling-server reconnect state.
  Timer? _reconnectTimer;
  int _retryAttempt = 0;
  bool _pcConnected = false; // is the WebRTC media connection currently up?

  CallState _state = CallState.idle;
  void _setState(CallState s, [String? detail]) {
    _state = s;
    onState?.call(s, detail);
  }

  /// Prepare the peer connection (once) and connect to the signaling server,
  /// retrying automatically until it succeeds.
  Future<void> connect() async {
    _closed = false;
    await _createPeerConnection();
    await _openWebSocket();
  }

  /// (Re)open the signaling WebSocket. On failure or drop it schedules another
  /// attempt with backoff, so a sleeping/cold-starting server or a network blip
  /// self-heals instead of leaving the app stuck on "Connecting…".
  Future<void> _openWebSocket() async {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _setState(
      _pcConnected ? CallState.reconnecting : CallState.connecting,
      'Connecting to server…',
    );

    final channel = WebSocketChannel.connect(Uri.parse(AppConfig.signalingUrl));
    try {
      // A cold-starting free server can take ~30s to wake, so be patient.
      await channel.ready.timeout(const Duration(seconds: 40));
    } catch (_) {
      await channel.sink.close();
      _scheduleReconnect();
      return;
    }
    if (_closed) {
      await channel.sink.close();
      return;
    }

    _ws = channel;
    _retryAttempt = 0;
    _wsSub = channel.stream.listen(
      _onSignal,
      onError: (_) => _handleWsDrop(),
      onDone: _handleWsDrop,
      cancelOnError: true,
    );

    // (Re)join the room. If a partner is already present, negotiation resumes
    // via the normal joined / peer-joined handling.
    _sendSignal({'type': 'join', 'room': room, 'clientId': clientId});
    if (!_pcConnected) {
      _setState(CallState.connecting, 'Waiting for the other phone…');
    }
  }

  void _handleWsDrop() {
    if (_closed) return;
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _retryAttempt++;
    // Backoff 2s, 4s, 6s … capped at 20s.
    final delay = Duration(seconds: (_retryAttempt * 2).clamp(2, 20));
    _setState(
      _pcConnected ? CallState.reconnecting : CallState.connecting,
      'Reconnecting to server…',
    );
    _reconnectTimer = Timer(delay, _openWebSocket);
  }

  Future<void> _createPeerConnection() async {
    _pc = await createPeerConnection({
      'iceServers': AppConfig.iceServers,
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _sendSignal({
        'type': 'ice',
        'payload': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    _pc!.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _pcConnected = true;
          _setState(CallState.live, 'Live');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _pcConnected = false;
          _setState(CallState.reconnecting, 'Reconnecting…');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _pcConnected = false;
          _setState(CallState.failed, 'Connection failed');
          _restartIce();
          break;
        default:
          break;
      }
    };

    if (isBroadcaster) {
      // Capture the microphone and add the audio track to send. flutter_webrtc
      // manages the platform audio session itself; we don't add a second audio
      // manager on top (that produced false "on a call" pauses on some phones).
      // Capture the mic with the voice-call DSP turned OFF. The defaults
      // (noise suppression, auto gain, echo cancel, voice band-pass) are tuned
      // for a person talking into the phone and make ambient/room audio sound
      // thin and gated — bad for a monitor. Disabling them gives fuller audio.
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': false,
          'noiseSuppression': false,
          'autoGainControl': false,
          // Android (goog-prefixed) equivalents:
          'googEchoCancellation': false,
          'googNoiseSuppression': false,
          'googAutoGainControl': false,
          'googHighpassFilter': false,
          'googTypingNoiseDetection': false,
        },
        'video': false,
      });
      await _pc!.addTrack(_localStream!.getAudioTracks().first, _localStream!);
    } else {
      // Listener only receives; mark the transceiver as recv-only.
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.RecvOnly,
        ),
      );
      // Remote audio plays through the device output automatically once the
      // track arrives; nothing to render for audio-only.
      _pc!.onTrack = (event) {
        if (event.track.kind == 'audio') {
          _setState(CallState.live, 'Live');
        }
      };
    }
  }

  Future<void> _onSignal(dynamic raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'joined':
        // If two peers are already present and we own the media, start the offer.
        final peers = msg['peers'] as int? ?? 1;
        if (peers >= 2) _peerPresent = true;
        if (_peerPresent && isBroadcaster) await _makeOffer();
        break;

      case 'peer-joined':
        _peerPresent = true;
        // The broadcaster drives negotiation once the listener is present.
        if (isBroadcaster) await _makeOffer();
        break;

      case 'peer-left':
        _peerPresent = false;
        _setState(CallState.connecting, 'Other phone left. Waiting…');
        break;

      case 'offer':
        await _handleOffer(msg['payload'] as Map<String, dynamic>);
        break;

      case 'answer':
        final p = msg['payload'] as Map<String, dynamic>;
        await _pc?.setRemoteDescription(
          RTCSessionDescription(p['sdp'] as String, p['type'] as String),
        );
        break;

      case 'ice':
        final p = msg['payload'] as Map<String, dynamic>;
        await _pc?.addCandidate(RTCIceCandidate(
          p['candidate'] as String?,
          p['sdpMid'] as String?,
          p['sdpMLineIndex'] as int?,
        ));
        break;

      case 'error':
        _setState(CallState.failed, msg['message'] as String? ?? 'Server error');
        break;
    }
  }

  Future<void> _makeOffer() async {
    if (_pc == null) return;
    final offer = await _pc!.createOffer();
    final tuned = RTCSessionDescription(
      _boostOpus(offer.sdp ?? ''),
      offer.type,
    );
    await _pc!.setLocalDescription(tuned);
    _sendSignal({
      'type': 'offer',
      'payload': {'sdp': tuned.sdp, 'type': tuned.type},
    });
  }

  /// Raise Opus audio quality in the SDP: high bitrate, full 48 kHz playback,
  /// and in-band forward error correction (better resilience to packet loss).
  /// Defaults are low-bitrate narrowband voice, which sounds poor for a monitor.
  String _boostOpus(String sdp) {
    final lines = sdp.split(RegExp(r'\r\n|\n'));
    String? pt;
    for (final l in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+) opus/48000').firstMatch(l);
      if (m != null) {
        pt = m.group(1);
        break;
      }
    }
    if (pt == null) return sdp;

    const params =
        'maxaveragebitrate=128000;maxplaybackrate=48000;useinbandfec=1;stereo=1;sprop-stereo=1';
    final out = <String>[];
    var patched = false;
    for (final l in lines) {
      if (l.startsWith('a=fmtp:$pt ')) {
        out.add(l.contains('maxaveragebitrate') ? l : '$l;$params');
        patched = true;
      } else {
        out.add(l);
        // No existing fmtp line for opus — add one right after its rtpmap.
        if (!patched && l.startsWith('a=rtpmap:$pt opus/48000')) {
          out.add('a=fmtp:$pt $params');
          patched = true;
        }
      }
    }
    return out.join('\r\n');
  }

  Future<void> _handleOffer(Map<String, dynamic> payload) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
    );
    final answer = await _pc!.createAnswer();
    // The receiver's fmtp governs what the sender transmits, so the listener's
    // answer is what actually raises the audio quality it gets.
    final tuned = RTCSessionDescription(_boostOpus(answer.sdp ?? ''), answer.type);
    await _pc!.setLocalDescription(tuned);
    _sendSignal({
      'type': 'answer',
      'payload': {'sdp': tuned.sdp, 'type': tuned.type},
    });
  }

  Future<void> _restartIce() async {
    if (_closed || !isBroadcaster || _pc == null) return;
    _setState(CallState.reconnecting, 'Recovering connection…');
    final offer = await _pc!.createOffer({'iceRestart': true});
    final tuned = RTCSessionDescription(_boostOpus(offer.sdp ?? ''), offer.type);
    await _pc!.setLocalDescription(tuned);
    _sendSignal({
      'type': 'offer',
      'payload': {'sdp': tuned.sdp, 'type': tuned.type},
    });
  }

  CallState get state => _state;

  void _sendSignal(Map<String, dynamic> msg) {
    _ws?.sink.add(jsonEncode(msg));
  }

  Future<void> close() async {
    _closed = true;
    try {
      _reconnectTimer?.cancel();
      await _wsSub?.cancel();
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
      await _localStream?.dispose();
      await _pc?.close();
      await _ws?.sink.close();
    } catch (_) {
      // Best-effort teardown.
    }
    _setState(CallState.idle, null);
  }
}
