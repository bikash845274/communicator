import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'signaling.dart';

const _kRoom = 'last_room';
const _kBroadcaster = 'is_broadcaster';
const _kAutoStart = 'auto_start';
const _kClientId = 'client_id';

/// A saved session to auto-resume.
typedef SavedSession = ({String room, bool isBroadcaster});

/// Owns the single live WebRTC [Signaling] session so it survives page
/// navigation, backgrounding, and (on Android) reboots. WebRTC stays in the main
/// isolate; a foreground service keeps the app process alive + shows a persistent
/// notification. Everything here is transparent — the notification and the OS mic
/// indicator are always visible while active.
class IntercomSession {
  IntercomSession._();
  static final IntercomSession instance = IntercomSession._();

  Signaling? _signaling;
  final ValueNotifier<CallState> state = ValueNotifier(CallState.idle);
  final ValueNotifier<String?> detail = ValueNotifier(null);
  final ValueNotifier<bool> micDenied = ValueNotifier(false);

  String? room;
  bool isBroadcaster = false;

  bool get isActive => _signaling != null;

  /// Configure the foreground-task plugin. Call once at app start (main isolate).
  static void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'audio_intercom',
        channelName: 'Audio Intercom',
        channelDescription: 'Keeps the intercom running in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true, // Android: restart the service after a reboot.
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Start (or restart) a session and persist it for auto-resume.
  Future<void> start({required String room, required bool isBroadcaster}) async {
    if (_signaling != null) {
      await _teardown();
    }
    this.room = room;
    this.isBroadcaster = isBroadcaster;
    micDenied.value = false;

    // The broadcaster needs the microphone.
    if (isBroadcaster) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        micDenied.value = true;
        return;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRoom, room);
    await prefs.setBool(_kBroadcaster, isBroadcaster);
    await prefs.setBool(_kAutoStart, true);
    final clientId = await _clientId(prefs);

    await _ensureNotificationPermission();
    await _startOrUpdateService();

    final signaling = Signaling(
      room: room,
      isBroadcaster: isBroadcaster,
      clientId: clientId,
      onState: (s, d) {
        detail.value = d;
        state.value = s;
        _updateNotification(s);
      },
    );
    _signaling = signaling;
    await signaling.connect();
  }

  /// End the session, clear auto-resume, and stop the service.
  Future<void> stop() async {
    await _teardown();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoStart, false);
    await FlutterForegroundTask.stopService();
  }

  Future<void> _teardown() async {
    await _signaling?.close();
    _signaling = null;
    state.value = CallState.idle;
    detail.value = null;
  }

  /// A stable per-install id so the server can tell a reconnecting phone apart
  /// from a genuinely different one (prevents a false "room full" on reconnect).
  Future<String> _clientId(SharedPreferences prefs) async {
    var id = prefs.getString(_kClientId);
    if (id == null || id.isEmpty) {
      id = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '-${Random().nextInt(0xFFFFFFF).toRadixString(36)}';
      await prefs.setString(_kClientId, id);
    }
    return id;
  }

  Future<void> _ensureNotificationPermission() async {
    final p = await FlutterForegroundTask.checkNotificationPermission();
    if (p != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  String get _title =>
      isBroadcaster ? 'Broadcasting · ${room ?? ''}' : 'Listening · ${room ?? ''}';

  String _textFor(CallState s) {
    switch (s) {
      case CallState.live:
        return isBroadcaster ? 'Live — mic is on' : 'Live — listening';
      case CallState.paused:
        return 'Paused — phone is on a call';
      case CallState.reconnecting:
        return 'Reconnecting…';
      case CallState.failed:
        return 'Connection problem';
      case CallState.connecting:
        return 'Connecting…';
      case CallState.idle:
        return 'Idle';
    }
  }

  static const _stopButton = [NotificationButton(id: 'stop', text: 'Stop')];

  Future<void> _startOrUpdateService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await _updateNotification(state.value);
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: 2718,
      notificationTitle: _title,
      notificationText: _textFor(state.value),
      notificationButtons: _stopButton,
      callback: startCallback,
    );
  }

  Future<void> _updateNotification(CallState s) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: _title,
      notificationText: _textFor(s),
      notificationButtons: _stopButton,
    );
  }

  /// The saved session to auto-resume, or null if none / auto-start disabled.
  static Future<SavedSession?> savedSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kAutoStart) ?? false)) return null;
    final room = prefs.getString(_kRoom);
    if (room == null || room.isEmpty) return null;
    return (room: room, isBroadcaster: prefs.getBool(_kBroadcaster) ?? true);
  }
}

/// Entry point for the foreground-service isolate (must be top-level).
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_IntercomTaskHandler());
}

class _IntercomTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // If the system started us (e.g. after a reboot), bring the app to the
    // foreground so the main isolate can auto-resume the session from prefs.
    if (starter == TaskStarter.system) {
      FlutterForegroundTask.launchApp();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      // Ask the main isolate to tear down WebRTC, then stop the service.
      FlutterForegroundTask.sendDataToMain('stop');
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}
