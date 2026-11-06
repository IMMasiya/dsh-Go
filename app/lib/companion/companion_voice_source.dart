// Where her voice comes from: the phone's own text-to-speech, an OpenAI-
// compatible speech API (OpenAI, SiliconFlow, and most self-hosted GPT-SoVITS /
// CosyVoice / Fish-Speech / edge-tts servers), or any HTTP API the person
// describes. Settings, fetching one sentence's audio, and the audio's loudness
// for her mouth. Playback and the queue are companion_voice.dart's.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum CompanionVoiceSource { system, openai, custom }

@immutable
class CompanionVoiceSettings {
  const CompanionVoiceSettings({
    this.on = false,
    this.source = CompanionVoiceSource.system,
    this.openaiBase = 'https://api.openai.com/v1',
    this.openaiKey = '',
    this.openaiModel = 'gpt-4o-mini-tts',
    this.openaiVoice = 'alloy',
    this.customUrl = '',
    this.customPost = true,
    this.customHeaders = '',
    this.customBody = '{"text": "{text}"}',
    this.customField = '',
  });

  final bool on;
  final CompanionVoiceSource source;
  final String openaiBase;
  final String openaiKey;
  final String openaiModel;
  final String openaiVoice;
  final String customUrl;
  final bool customPost;

  /// One `Name: value` per line. Kept in secure storage: it often carries a key.
  final String customHeaders;
  final String customBody;

  /// Where the audio is in a JSON reply (`data.audio`, `items.0.url`); empty
  /// when the reply is the audio itself.
  final String customField;

  /// Whether the chosen source has what it needs to be asked at all.
  bool get configured => switch (source) {
    CompanionVoiceSource.system => true,
    CompanionVoiceSource.openai => openaiBase.trim().isNotEmpty && openaiVoice.trim().isNotEmpty,
    CompanionVoiceSource.custom => customUrl.trim().isNotEmpty,
  };

  CompanionVoiceSettings copyWith({
    bool? on,
    CompanionVoiceSource? source,
    String? openaiBase,
    String? openaiKey,
    String? openaiModel,
    String? openaiVoice,
    String? customUrl,
    bool? customPost,
    String? customHeaders,
    String? customBody,
    String? customField,
  }) => CompanionVoiceSettings(
    on: on ?? this.on,
    source: source ?? this.source,
    openaiBase: openaiBase ?? this.openaiBase,
    openaiKey: openaiKey ?? this.openaiKey,
    openaiModel: openaiModel ?? this.openaiModel,
    openaiVoice: openaiVoice ?? this.openaiVoice,
    customUrl: customUrl ?? this.customUrl,
    customPost: customPost ?? this.customPost,
    customHeaders: customHeaders ?? this.customHeaders,
    customBody: customBody ?? this.customBody,
    customField: customField ?? this.customField,
  );

  /// The part kept in plain preferences: no keys, no headers.
  Map<String, Object?> plain() => {
    'source': source.name,
    'openaiBase': openaiBase,
    'openaiModel': openaiModel,
    'openaiVoice': openaiVoice,
    'customUrl': customUrl,
    'customPost': customPost,
    'customBody': customBody,
    'customField': customField,
  };

  static CompanionVoiceSettings fromPlain(Object? json, {bool on = false}) {
    final map = json is Map ? json : const {};
    String text(String key, String fallback) => map[key] is String ? map[key] as String : fallback;
    const d = CompanionVoiceSettings();
    return CompanionVoiceSettings(
      on: on,
      source: CompanionVoiceSource.values.asNameMap()[map['source']] ?? d.source,
      openaiBase: text('openaiBase', d.openaiBase),
      openaiModel: text('openaiModel', d.openaiModel),
      openaiVoice: text('openaiVoice', d.openaiVoice),
      customUrl: text('customUrl', d.customUrl),
      customPost: map['customPost'] is bool ? map['customPost'] as bool : d.customPost,
      customBody: text('customBody', d.customBody),
      customField: text('customField', d.customField),
    );
  }
}

const _onKey = 'companion_voice_enabled';
const _plainKey = 'companion_voice_v1';
const _openaiKeyKey = 'companion_voice_openai_key';
const _headersKey = 'companion_voice_custom_headers';

/// Her voice settings; null until read (then she stays silent).
class CompanionVoiceSettingsController extends Notifier<CompanionVoiceSettings?> {
  static const _secure = FlutterSecureStorage();

  @override
  CompanionVoiceSettings? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_plainKey);
      var settings = CompanionVoiceSettings.fromPlain(
        raw == null ? null : jsonDecode(raw),
        on: prefs.getBool(_onKey) ?? false,
      );
      try {
        settings = settings.copyWith(
          openaiKey: await _secure.read(key: _openaiKeyKey) ?? '',
          customHeaders: await _secure.read(key: _headersKey) ?? '',
        );
      } on Object {
        // No secure storage (tests, a broken keystore): no keys, nothing else lost.
      }
      if (ref.mounted && state == null) state = settings;
    } on Object {
      if (ref.mounted && state == null) state = const CompanionVoiceSettings();
    }
  }

  Future<void> update(CompanionVoiceSettings next) async {
    final before = state;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    if (before?.on != next.on) await prefs.setBool(_onKey, next.on);
    await prefs.setString(_plainKey, jsonEncode(next.plain()));
    try {
      if (before?.openaiKey != next.openaiKey) await _secure.write(key: _openaiKeyKey, value: next.openaiKey);
      if (before?.customHeaders != next.customHeaders) await _secure.write(key: _headersKey, value: next.customHeaders);
    } on Object {
      // Kept for this run only.
    }
  }
}

final companionVoiceSettingsProvider = NotifierProvider<CompanionVoiceSettingsController, CompanionVoiceSettings?>(
  CompanionVoiceSettingsController.new,
);

// ── Fetching ───────────────────────────────────────────────────────────────

class CompanionVoiceError implements Exception {
  const CompanionVoiceError(this.reason);

  /// Short and technical: `HTTP 401 …`, `timeout`, `not audio`, `no field data.audio`.
  final String reason;

  @override
  String toString() => 'CompanionVoiceError($reason)';
}

@immutable
class CompanionVoiceAudio {
  const CompanionVoiceAudio(this.bytes, this.ext);

  final Uint8List bytes;

  /// wav, mp3, ogg, flac, m4a, or bin when unknown (the player may still manage).
  final String ext;
}

/// The format [bytes] are in, by their first bytes.
String companionAudioKind(Uint8List bytes) {
  bool at(int i, List<int> magic) =>
      bytes.length >= i + magic.length && Iterable<int>.generate(magic.length).every((k) => bytes[i + k] == magic[k]);
  if (at(0, ascii.encode('RIFF')) && at(8, ascii.encode('WAVE'))) return 'wav';
  if (at(0, ascii.encode('ID3')) || (bytes.length > 1 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)) return 'mp3';
  if (at(0, ascii.encode('OggS'))) return 'ogg';
  if (at(0, ascii.encode('fLaC'))) return 'flac';
  if (at(4, ascii.encode('ftyp'))) return 'm4a';
  return 'bin';
}

/// One sentence of [text] from the settings' external source.
Future<CompanionVoiceAudio> fetchCompanionVoice(
  CompanionVoiceSettings settings,
  String text,
  http.Client client, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final http.Response response;
  try {
    response = await switch (settings.source) {
      CompanionVoiceSource.openai => client.post(
        Uri.parse('${settings.openaiBase.trim().replaceAll(RegExp(r'/+$'), '')}/audio/speech'),
        headers: {
          'content-type': 'application/json',
          if (settings.openaiKey.trim().isNotEmpty) 'authorization': 'Bearer ${settings.openaiKey.trim()}',
        },
        body: jsonEncode({
          'model': settings.openaiModel.trim(),
          'input': text,
          'voice': settings.openaiVoice.trim(),
          // Raw loudness for her mouth; servers that can't still answer in their own format.
          'response_format': 'wav',
        }),
      ),
      CompanionVoiceSource.custom => _custom(settings, text, client),
      CompanionVoiceSource.system => throw const CompanionVoiceError('system voice is not fetched'),
    }.timeout(timeout);
  } on TimeoutException {
    throw const CompanionVoiceError('timeout');
  } on CompanionVoiceError {
    rethrow;
  } on Object catch (error) {
    throw CompanionVoiceError(error.toString().split('\n').first);
  }
  if (response.statusCode != 200) {
    final note = utf8.decode(response.bodyBytes.take(160).toList(), allowMalformed: true).replaceAll('\n', ' ').trim();
    throw CompanionVoiceError('HTTP ${response.statusCode}${note.isEmpty ? '' : ' $note'}');
  }
  var bytes = response.bodyBytes;
  final field = settings.source == CompanionVoiceSource.custom ? settings.customField.trim() : '';
  if (field.isNotEmpty) bytes = await _fromJson(bytes, field, client, timeout);
  final kind = companionAudioKind(bytes);
  // A JSON or HTML error page that came back as 200.
  if (kind == 'bin' && bytes.isNotEmpty && (bytes.first == 0x7B || bytes.first == 0x3C)) {
    throw const CompanionVoiceError('not audio');
  }
  if (bytes.isEmpty) throw const CompanionVoiceError('empty reply');
  return CompanionVoiceAudio(bytes, kind);
}

Future<http.Response> _custom(CompanionVoiceSettings settings, String text, http.Client client) {
  final url = Uri.parse(settings.customUrl.trim().replaceAll('{text}', Uri.encodeQueryComponent(text)));
  final headers = <String, String>{};
  for (final line in const LineSplitter().convert(settings.customHeaders)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  if (!settings.customPost) return client.get(url, headers: headers);
  // Inside the template's quotes: the text escaped as a JSON string's content.
  final escaped = jsonEncode(text);
  final body = settings.customBody.replaceAll('{text}', escaped.substring(1, escaped.length - 1));
  headers.putIfAbsent('content-type', () => 'application/json');
  return client.post(url, headers: headers, body: body);
}

/// The audio at [path] in a JSON reply: base64 (a data: URL too) or a link.
Future<Uint8List> _fromJson(Uint8List body, String path, http.Client client, Duration timeout) async {
  Object? node;
  try {
    node = jsonDecode(utf8.decode(body));
  } on FormatException {
    throw const CompanionVoiceError('reply is not JSON');
  }
  for (final step in path.split('.')) {
    final index = int.tryParse(step);
    if (node is Map && node.containsKey(step)) {
      node = node[step];
    } else if (node is List && index != null && index >= 0 && index < node.length) {
      node = node[index];
    } else {
      throw CompanionVoiceError('no field $path');
    }
  }
  if (node is! String || node.isEmpty) throw CompanionVoiceError('no field $path');
  if (node.startsWith('http://') || node.startsWith('https://')) {
    try {
      final audio = await client.get(Uri.parse(node)).timeout(timeout);
      if (audio.statusCode != 200) throw CompanionVoiceError('HTTP ${audio.statusCode} for the audio link');
      return audio.bodyBytes;
    } on TimeoutException {
      throw const CompanionVoiceError('timeout');
    }
  }
  final data = node.contains(',') && node.startsWith('data:') ? node.substring(node.indexOf(',') + 1) : node;
  try {
    return base64.decode(base64.normalize(data.replaceAll(RegExp(r'\s'), '')));
  } on FormatException {
    throw CompanionVoiceError('field $path is neither base64 nor a link');
  }
}

// ── Loudness ───────────────────────────────────────────────────────────────

/// How open her mouth should be every [frameMs] while a WAV plays (0–1), from
/// its loudness against its own loudest moment; null for anything that isn't
/// 16-bit PCM WAV.
List<double>? companionLoudness(Uint8List wav, {int frameMs = 40}) {
  if (companionAudioKind(wav) != 'wav') return null;
  final data = ByteData.sublistView(wav);
  int? channels;
  int? rate;
  int? bits;
  var offset = 12;
  int? start;
  int? length;
  while (offset + 8 <= wav.length) {
    final id = ascii.decode(wav.sublist(offset, offset + 4), allowInvalid: true);
    var size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ' && body + 16 <= wav.length) {
      if (data.getUint16(body, Endian.little) != 1) return null; // Not PCM.
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      start = body;
      // Streaming servers write a placeholder size: take what is there.
      if (size == 0 || size == 0xFFFFFFFF || body + size > wav.length) size = wav.length - body;
      length = size;
      break;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  if (channels == null || rate == null || bits != 16 || start == null || length == null || channels == 0) return null;
  final frameSamples = max(1, rate * frameMs ~/ 1000);
  final stride = 2 * channels;
  final count = length ~/ stride;
  final levels = <double>[];
  for (var first = 0; first < count; first += frameSamples) {
    var sum = 0.0;
    final last = min(count, first + frameSamples);
    for (var i = first; i < last; i++) {
      final sample = data.getInt16(start + i * stride, Endian.little) / 32768.0;
      sum += sample * sample;
    }
    levels.add(sqrt(sum / (last - first)));
  }
  final peak = levels.fold<double>(0, max);
  if (peak < 1e-4) return List.filled(levels.length, 0);
  return [
    for (final level in levels)
      // Quiet breaths stay closed; speech opens it, never all the way.
      level / peak < 0.12 ? 0 : (pow(level / peak, 0.7) * 0.9).toDouble(),
  ];
}
