import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'broadcast_page.dart';
import 'listen_page.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required so the main isolate can receive data (e.g. the "Stop" button)
  // from the foreground-service isolate.
  FlutterForegroundTask.initCommunicationPort();
  IntercomSession.initForegroundTask();
  runApp(const IntercomApp());
}

class IntercomApp extends StatefulWidget {
  const IntercomApp({super.key});

  @override
  State<IntercomApp> createState() => _IntercomAppState();
}

class _IntercomAppState extends State<IntercomApp> {
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoResume());
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    super.dispose();
  }

  // "Stop" pressed in the persistent notification.
  void _onTaskData(Object data) {
    if (data == 'stop') IntercomSession.instance.stop();
  }

  // On launch (or reboot-triggered launch), resume the last session.
  Future<void> _maybeAutoResume() async {
    final saved = await IntercomSession.savedSession();
    if (saved == null) return;
    _navKey.currentState?.push(MaterialPageRoute(
      builder: (_) => saved.isBroadcaster
          ? BroadcastPage(room: saved.room)
          : ListenPage(room: saved.room),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'Audio Intercom',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _roomController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Ask for the microphone once, up front. If already decided, no dialog.
    Permission.microphone.request();
  }

  String get _room => _roomController.text.trim().toUpperCase();

  void _open(Widget Function(String room) builder) {
    if (_room.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a room code first')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => builder(_room)),
    );
  }

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Intercom')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Text(
              'Pair two phones with the same code, then choose one to broadcast '
              'and one to listen.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _roomController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Room code',
                hintText: 'e.g. HOME01',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.vpn_key),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: () => _open((room) => BroadcastPage(room: room)),
              icon: const Icon(Icons.mic),
              label: const Text('Broadcast (share this mic)'),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: () => _open((room) => ListenPage(room: room)),
              icon: const Icon(Icons.hearing),
              label: const Text('Listen (hear the other phone)'),
            ),
            const Spacer(),
            Text(
              'Runs in the background with a notification until you stop it. '
              'The broadcasting phone always shows a visible "live mic" indicator.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
