import 'package:flutter/material.dart';

import 'signaling.dart';

/// The phone that listens to the other phone's microphone. Audio plays through
/// the device's speaker/earpiece automatically once connected.
class ListenPage extends StatefulWidget {
  const ListenPage({super.key, required this.room});

  final String room;

  @override
  State<ListenPage> createState() => _ListenPageState();
}

class _ListenPageState extends State<ListenPage> {
  Signaling? _signaling;
  CallState _state = CallState.connecting;
  String? _detail;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final signaling = Signaling(
      room: widget.room,
      isBroadcaster: false,
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

  @override
  void dispose() {
    _signaling?.close();
    super.dispose();
  }

  ({IconData icon, Color color, String label}) get _status {
    switch (_state) {
      case CallState.live:
        return (icon: Icons.volume_up, color: Colors.green, label: 'Live — listening');
      case CallState.connecting:
        return (icon: Icons.hourglass_top, color: Colors.orange, label: _detail ?? 'Connecting…');
      case CallState.reconnecting:
        return (icon: Icons.sync, color: Colors.orange, label: 'Reconnecting…');
      case CallState.failed:
        return (icon: Icons.error_outline, color: Colors.red, label: _detail ?? 'Connection failed');
      case CallState.idle:
        return (icon: Icons.hearing, color: Colors.grey, label: 'Idle');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: Text('Listening · ${widget.room}')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(s.icon, size: 120, color: s.color),
            const SizedBox(height: 24),
            Text(
              s.label,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Room code: ${widget.room}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 40),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.call_end),
              label: const Text('Stop listening'),
            ),
          ],
        ),
      ),
    );
  }
}
