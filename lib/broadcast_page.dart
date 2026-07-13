import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'signaling.dart';

/// The phone that shares its microphone. Shows a clear, always-visible
/// "live mic" indicator so broadcasting is never covert.
class BroadcastPage extends StatefulWidget {
  const BroadcastPage({super.key, required this.room});

  final String room;

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  Signaling? _signaling;
  CallState _state = CallState.idle;
  String? _detail;
  bool _muted = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() => _permissionDenied = true);
      return;
    }
    final signaling = Signaling(
      room: widget.room,
      isBroadcaster: true,
      onState: (s, d) {
        if (mounted) {
          setState(() {
            _state = s;
            _detail = d;
          });
        }
      },
    );
    _signaling = signaling;
    await signaling.connect();
  }

  void _toggleMute() {
    final next = !_muted;
    _signaling?.setMuted(next);
    setState(() => _muted = next);
  }

  @override
  void dispose() {
    _signaling?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLive = _state == CallState.live;
    return Scaffold(
      appBar: AppBar(title: Text('Broadcasting · ${widget.room}')),
      body: Center(
        child: _permissionDenied
            ? _PermissionDenied(onOpenSettings: openAppSettings)
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isLive ? Icons.mic : Icons.mic_none,
                    size: 120,
                    color: isLive ? Colors.red : Colors.grey,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    isLive
                        ? (_muted ? 'MIC MUTED' : '🔴 LIVE — mic is on')
                        : (_detail ?? 'Starting…'),
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Anyone with code "${widget.room}" can hear this phone.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  FilledButton.tonalIcon(
                    onPressed: isLive ? _toggleMute : null,
                    icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                    label: Text(_muted ? 'Unmute' : 'Mute'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop broadcasting'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PermissionDenied extends StatelessWidget {
  const _PermissionDenied({required this.onOpenSettings});
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.mic_off, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'Microphone permission is required to broadcast.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onOpenSettings,
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }
}
