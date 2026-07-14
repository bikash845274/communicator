import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'session.dart';
import 'signaling.dart';

/// The phone that listens to the other phone's microphone. The session lives in
/// [IntercomSession], so back / lock don't stop it — it keeps running in the
/// background with a persistent notification. Stop is via that notification.
class ListenPage extends StatefulWidget {
  const ListenPage({super.key, required this.room});

  final String room;

  @override
  State<ListenPage> createState() => _ListenPageState();
}

class _ListenPageState extends State<ListenPage> {
  final _session = IntercomSession.instance;
  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    _session.state.addListener(_onState);
    _ensureStarted();
  }

  Future<void> _ensureStarted() async {
    if (_session.isActive &&
        _session.room == widget.room &&
        !_session.isBroadcaster) {
      return;
    }
    await _session.start(room: widget.room, isBroadcaster: false);
  }

  void _onState() {
    final s = _session.state.value;
    if (s != CallState.idle) _wasActive = true;
    if (_wasActive && s == CallState.idle && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _session.state.removeListener(_onState);
    super.dispose(); // deliberately does NOT stop the session
  }

  ({IconData icon, Color color, String label}) _status(CallState s) {
    switch (s) {
      case CallState.live:
        return (icon: Icons.volume_up, color: Colors.green, label: 'Live — listening');
      case CallState.connecting:
        return (
          icon: Icons.hourglass_top,
          color: Colors.orange,
          label: _session.detail.value ?? 'Connecting…'
        );
      case CallState.paused:
        return (icon: Icons.pause_circle, color: Colors.orange, label: 'Paused');
      case CallState.reconnecting:
        return (icon: Icons.sync, color: Colors.orange, label: 'Reconnecting…');
      case CallState.failed:
        return (
          icon: Icons.error_outline,
          color: Colors.red,
          label: _session.detail.value ?? 'Connection failed'
        );
      case CallState.idle:
        return (icon: Icons.hearing, color: Colors.grey, label: 'Idle');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) FlutterForegroundTask.minimizeApp();
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Listening · ${widget.room}')),
        body: Center(
          child: ValueListenableBuilder<CallState>(
            valueListenable: _session.state,
            builder: (context, state, _) {
              final s = _status(state);
              return Column(
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
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
