import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'session.dart';
import 'signaling.dart';

/// The phone that shares its microphone. The session lives in [IntercomSession],
/// so pressing back / locking the phone doesn't stop it — it keeps running in the
/// background with a persistent notification. Stop is via that notification.
class BroadcastPage extends StatefulWidget {
  const BroadcastPage({super.key, required this.room});

  final String room;

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
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
        _session.isBroadcaster) {
      return;
    }
    await _session.start(room: widget.room, isBroadcaster: true);
  }

  void _onState() {
    final s = _session.state.value;
    if (s != CallState.idle) _wasActive = true;
    // Session ended (e.g. "Stop" from the notification) — return home.
    if (_wasActive && s == CallState.idle && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _session.state.removeListener(_onState);
    super.dispose(); // deliberately does NOT stop the session
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // Back keeps broadcasting alive — just minimize the app.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) FlutterForegroundTask.minimizeApp();
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Broadcasting · ${widget.room}')),
        body: Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: _session.micDenied,
            builder: (context, denied, _) {
              if (denied) {
                return _PermissionDenied(onOpenSettings: openAppSettings);
              }
              return ValueListenableBuilder<CallState>(
                valueListenable: _session.state,
                builder: (context, s, _) => _body(context, s),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, CallState s) {
    final isLive = s == CallState.live;
    final isPaused = s == CallState.paused;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          isLive ? Icons.mic : (isPaused ? Icons.pause_circle : Icons.mic_none),
          size: 120,
          color: isLive ? Colors.red : (isPaused ? Colors.orange : Colors.grey),
        ),
        const SizedBox(height: 24),
        Text(
          isLive
              ? '🔴 LIVE — mic is on'
              : (isPaused
                  ? 'Paused — phone is on a call'
                  : (_session.detail.value ?? 'Starting…')),
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'You are broadcasting.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
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
