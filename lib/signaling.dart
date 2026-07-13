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
  reconnecting,
  failed,
}

typedef StateCallback = void Function(CallState state, String? detail);

/// Handles the WebSocket signaling exchange and the WebRTC peer connection.
///
/// One instance per session. Set [isBroadcaster] to true on the phone that
/// shares its microphone, false on the phone that listens.
class Signaling {
  Signaling({required this.room, required this.isBroadcaster, this.onState});

  final String room;
  final bool isBroadcaster;
  final StateCallback? onState;

  WebSocketChannel? _ws;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  bool _peerPresent = false;
  bool _closed = false;
  bool _muted = false;

  CallState _state = CallState.idle;
  void _setState(CallState s, [String? detail]) {
    _state = s;
    onState?.call(s, detail);
  }

  /// Open the websocket, join the room, and prepare the peer connection.
  Future<void> connect() async {
    _closed = false;
    _setState(CallState.connecting, 'Connecting to server…');

    try {
      _ws = WebSocketChannel.connect(Uri.parse(AppConfig.signalingUrl));
      // Ensure the socket is actually open before we start sending.
      await _ws!.ready;
    } catch (e) {
      _setState(CallState.failed, 'Cannot reach signaling server: $e');
      return;
    }

    _ws!.stream.listen(
      _onSignal,
      onError: (e) => _setState(CallState.reconnecting, 'Connection error: $e'),
      onDone: () {
        if (!_closed) _setState(CallState.reconnecting, 'Disconnected');
      },
    );

    await _createPeerConnection();
    _sendSignal({'type': 'join', 'room': room});
    _setState(CallState.connecting, 'Waiting for the other phone…');
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
          _setState(CallState.live, 'Live');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _setState(CallState.reconnecting, 'Reconnecting…');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(CallState.failed, 'Connection failed');
          _restartIce();
          break;
        default:
          break;
      }
    };

    if (isBroadcaster) {
      // Capture the microphone and add the audio track to send.
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in _localStream!.getAudioTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
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
    await _pc!.setLocalDescription(offer);
    _sendSignal({
      'type': 'offer',
      'payload': {'sdp': offer.sdp, 'type': offer.type},
    });
  }

  Future<void> _handleOffer(Map<String, dynamic> payload) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
    );
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    _sendSignal({
      'type': 'answer',
      'payload': {'sdp': answer.sdp, 'type': answer.type},
    });
  }

  Future<void> _restartIce() async {
    if (_closed || !isBroadcaster || _pc == null) return;
    _setState(CallState.reconnecting, 'Recovering connection…');
    final offer = await _pc!.createOffer({'iceRestart': true});
    await _pc!.setLocalDescription(offer);
    _sendSignal({
      'type': 'offer',
      'payload': {'sdp': offer.sdp, 'type': offer.type},
    });
  }

  /// Mute / unmute the outgoing microphone (broadcaster only).
  void setMuted(bool muted) {
    _muted = muted;
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  bool get isMuted => _muted;
  CallState get state => _state;

  void _sendSignal(Map<String, dynamic> msg) {
    _ws?.sink.add(jsonEncode(msg));
  }

  Future<void> close() async {
    _closed = true;
    try {
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
