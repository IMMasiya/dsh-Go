// Her voice: the phone's own text-to-speech (android CompanionVoicePlugin.kt,
// channel `dsh/companion_voice`). Off until the person turns it on, and it
// speaks a line for them to hear as they do (Pro C205/C309: first silent, on
// after hearing it). The text goes to the system's engine; the app keeps no audio.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabledKey = 'companion_voice_enabled';

enum CompanionVoiceEventType { start, range, done, stopped, error }

class CompanionVoiceEvent {
  const CompanionVoiceEvent(this.type, this.id, {this.start, this.end});

  final CompanionVoiceEventType type;
  final String id;

  /// For [CompanionVoiceEventType.range]: the characters being spoken now.
  final int? start;
  final int? end;
}

class CompanionVoice {
  CompanionVoice([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/companion_voice') {
    _channel.setMethodCallHandler(_heard);
  }

  final MethodChannel _channel;
  final _events = StreamController<CompanionVoiceEvent>.broadcast();

  /// Her pitch and pace: a little higher than the engine's default voice.
  static const pitch = 1.12;
  static const rate = 1.0;

  Stream<CompanionVoiceEvent> get events => _events.stream;

  Future<void> _heard(MethodCall call) async {
    if (call.method != 'event') return;
    final args = call.arguments;
    if (args is! Map) return;
    final type = CompanionVoiceEventType.values.asNameMap()[args['type']];
    final id = args['id'];
    if (type == null || id is! String) return;
    _events.add(
      CompanionVoiceEvent(type, id, start: (args['start'] as num?)?.toInt(), end: (args['end'] as num?)?.toInt()),
    );
  }

  /// Whether the engine can speak [language] (starting it the first time).
  Future<bool> ready({String language = 'zh-CN'}) async {
    try {
      return await _channel.invokeMethod<bool>('ready', {'language': language}) ?? false;
    } on Object {
      return false;
    }
  }

  /// Queues [text] under [id], or replaces whatever she is saying with [flush].
  Future<bool> speak(String id, String text, {bool flush = false}) async {
    try {
      return await _channel.invokeMethod<bool>('speak', {
            'id': id,
            'text': text,
            'flush': flush,
            'pitch': pitch,
            'rate': rate,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // Nothing was speaking, or there is no engine.
    }
  }

  void dispose() => unawaited(_events.close());
}

final companionVoiceProvider = Provider<CompanionVoice>((ref) {
  final voice = CompanionVoice();
  ref.onDispose(voice.dispose);
  return voice;
});

/// Whether she speaks aloud. Off by default; null until read.
class CompanionVoiceEnabled extends Notifier<bool?> {
  @override
  bool? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted && state == null) state = prefs.getBool(_enabledKey) ?? false;
    } on Object {
      // Stays null: silent.
    }
  }

  Future<void> set(bool on) async {
    state = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, on);
  }
}

final companionVoiceEnabledProvider = NotifierProvider<CompanionVoiceEnabled, bool?>(CompanionVoiceEnabled.new);

/// The sentences ready to be read aloud in [words] after [from]: up to the last
/// sentence end, or all of it once [final_] (a reply that has finished).
(String, int) companionSpeakable(String words, int from, {required bool final_}) {
  if (from >= words.length) return ('', words.length.clamp(0, from));
  final rest = words.substring(from);
  if (final_) return (rest.trim(), words.length);
  final end = RegExp(r'[。！？!?…~～\n]').allMatches(rest).lastOrNull?.end;
  if (end == null) return ('', from);
  return (rest.substring(0, end).trim(), from + end);
}
