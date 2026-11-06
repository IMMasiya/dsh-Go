// 轻量模式 (docs/design/companion.md §7): she talks to DeepSeek straight from
// the phone, with no engine and no host. The same Messages API the engine's
// DeepSeek adapter uses (@deepseek-ai/dsh-llm-deepseek), with the API key
// saved in the app; her conversation is a small file next to the pack.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const companionLightEndpoint = 'https://api.deepseek.com/anthropic/v1/messages';

/// The fast model of the official route (text and images); thinking off, so a
/// line comes back as quickly as she would say it.
const companionLightModel = 'deepseek-flash';

/// One line of the light conversation, as the model sees it.
@immutable
class CompanionLine {
  const CompanionLine.user(this.text) : fromHer = false;
  const CompanionLine.her(this.text) : fromHer = true;

  static CompanionLine? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String || text.isEmpty) return null;
    return switch (json['role']) {
      'user' => CompanionLine.user(text),
      'assistant' => CompanionLine.her(text),
      _ => null,
    };
  }

  final bool fromHer;
  final String text;

  String get role => fromHer ? 'assistant' : 'user';

  Map<String, Object?> toJson() => {'role': role, 'text': text};
}

enum CompanionLightFailure { noKey, badKey, busy, network, server }

class CompanionLightError implements Exception {
  const CompanionLightError(this.failure, [this.detail]);

  final CompanionLightFailure failure;
  final String? detail;

  @override
  String toString() => 'CompanionLightError(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Her reply to [lines], as text deltas. Cancelling the subscription drops the
/// request; [client] is the caller's to close.
Stream<String> streamCompanionReply({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<CompanionLine> lines,
  int maxTokens = 800,
}) async* {
  final request = http.Request('POST', Uri.parse(companionLightEndpoint))
    ..headers.addAll({
      'content-type': 'application/json',
      'accept': 'text/event-stream',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    })
    ..body = jsonEncode({
      'model': companionLightModel,
      'stream': true,
      'max_tokens': maxTokens,
      'thinking': {'type': 'disabled'},
      'system': system,
      'messages': [
        for (final line in lines) {'role': line.role, 'content': line.text},
      ],
    });
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(const Duration(seconds: 30));
  } on Object catch (error) {
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  }
  if (response.statusCode != 200) {
    final body = await response.stream.bytesToString().catchError((Object _) => '');
    throw CompanionLightError(switch (response.statusCode) {
      401 || 403 => CompanionLightFailure.badKey,
      429 => CompanionLightFailure.busy,
      _ => CompanionLightFailure.server,
    }, '${response.statusCode} ${body.length > 200 ? body.substring(0, 200) : body}');
  }
  final events = response.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      // A reply that stops arriving is a failed one, not a slow one.
      .timeout(const Duration(seconds: 45));
  try {
    await for (final line in events) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final Object? event;
      try {
        event = jsonDecode(data);
      } on FormatException {
        continue;
      }
      if (event is! Map) continue;
      switch (event['type']) {
        case 'content_block_delta':
          final delta = event['delta'];
          if (delta is Map && delta['type'] == 'text_delta' && delta['text'] is String) {
            yield delta['text'] as String;
          }
        case 'error':
          final error = event['error'];
          final kind = error is Map ? error['type'] : null;
          throw CompanionLightError(
            kind == 'overloaded_error' || kind == 'rate_limit_error'
                ? CompanionLightFailure.busy
                : CompanionLightFailure.server,
            error is Map ? '${error['message']}' : null,
          );
        case 'message_stop':
          return;
      }
    }
  } on CompanionLightError {
    rethrow;
  } on Object catch (error) {
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  }
}

/// The light conversation, kept on this phone.
class CompanionLightHistory {
  CompanionLightHistory(this.file);

  /// Next to the pack (`<root>/light-chat.json`): removing the pack keeps it.
  factory CompanionLightHistory.at(Directory root) => CompanionLightHistory(File('${root.path}/light-chat.json'));

  final File file;
  final List<CompanionLine> _lines = [];
  bool _loaded = false;
  Future<void> _writes = Future.value();

  /// Lines kept on disk; older ones fall off.
  static const keep = 80;

  /// Lines sent with each message (about a dozen turns).
  static const window = 24;

  List<CompanionLine> get lines => List.unmodifiable(_lines);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map && json['lines'] is List) {
        _lines.addAll([for (final line in json['lines'] as List) ?CompanionLine.fromJson(line)]);
      }
    } on Object {
      // Missing or unreadable: she starts afresh rather than not talking.
    }
  }

  void add(CompanionLine line) {
    _lines.add(line);
    if (_lines.length > keep) _lines.removeRange(0, _lines.length - keep);
  }

  /// Takes back the last line when it's the person's and went unanswered.
  CompanionLine? dropUnanswered() => _lines.isNotEmpty && !_lines.last.fromHer ? _lines.removeLast() : null;

  /// What the model gets: the last [window] lines, starting with the person,
  /// with lines from the same side joined (the API wants them alternating).
  List<CompanionLine> context() {
    var start = max(0, _lines.length - window);
    while (start < _lines.length && _lines[start].fromHer) {
      start++;
    }
    final out = <CompanionLine>[];
    for (final line in _lines.skip(start)) {
      if (out.isNotEmpty && out.last.fromHer == line.fromHer) {
        final joined = '${out.last.text}\n${line.text}';
        out[out.length - 1] = line.fromHer ? CompanionLine.her(joined) : CompanionLine.user(joined);
      } else {
        out.add(line);
      }
    }
    return out;
  }

  Future<void> save() => _writes = _writes.then((_) async {
    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'v': 1,
          'lines': [for (final line in _lines) line.toJson()],
        }),
      );
      await temp.rename(file.path);
    } on Object {
      // A lost write costs her a little memory, never the conversation in progress.
    }
  });

  Future<void> clear() async {
    _lines.clear();
    await _writes;
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing to forget, or it can't be: the next save overwrites it.
    }
  }
}
