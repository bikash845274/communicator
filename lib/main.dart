import 'package:flutter/material.dart';

import 'broadcast_page.dart';
import 'listen_page.dart';

void main() {
  runApp(const IntercomApp());
}

class IntercomApp extends StatelessWidget {
  const IntercomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
              'Use only on devices you own or with consent. The broadcasting '
              'phone always shows a visible "live mic" indicator.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
