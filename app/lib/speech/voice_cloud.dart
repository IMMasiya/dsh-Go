// Recognizers in the cloud for 语音输入 and 语音通话: DeepSeek's (the signed-in
// account or the API key, deepseek_speech.dart), or an OpenAI-compatible
// `/audio/transcriptions` service the person set up (speech_settings.dart).
// Both take a whole recording; nothing is recognized while still speaking.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../state/connection_state.dart';
import '../state/voice_settings.dart';
import 'deepseek_speech.dart';
import 'speech_settings.dart';

abstract class VoiceCloud {
  /// The longest recording it takes, in seconds.
  int get maxSeconds;

  /// What was said in [wav] (16 kHz mono PCM16). Throws [DeepSeekSpeechError]
  /// (also for the other service: same kinds of failure).
  Future<String> transcribe(Uint8List wav);
}

class DeepSeekVoiceCloud implements VoiceCloud {
  DeepSeekVoiceCloud(this._speech);
  final DeepSeekSpeech _speech;

  @override
  int get maxSeconds => deepSeekAsrMaxSeconds;

  @override
  Future<String> transcribe(Uint8List wav) async {
    try {
      return await _speech.transcribe(wav);
    } finally {
      _speech.close();
    }
  }
}

/// An OpenAI-compatible `/audio/transcriptions`.
class OpenAiVoiceCloud implements VoiceCloud {
  OpenAiVoiceCloud(this.settings, this._client);
  final CloudAsrSettings settings;
  final http.Client Function() _client;

  @override
  int get maxSeconds => 300;

  @override
  Future<String> transcribe(Uint8List wav) async {
    final base = settings.base.trim().replaceAll(RegExp(r'/+$'), '');
    final request = http.MultipartRequest('POST', Uri.parse('$base/audio/transcriptions'))
      ..fields['model'] = settings.model.trim()
      ..fields['response_format'] = 'json'
      ..files.add(http.MultipartFile.fromBytes('file', wav, filename: 'speech.wav'));
    if (settings.key.trim().isNotEmpty) request.headers['authorization'] = 'Bearer ${settings.key.trim()}';
    final client = _client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request)).timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.busy, 'timeout');
    } on Object catch (error) {
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.network, error.toString().split('\n').first);
    } finally {
      client.close();
    }
    final note = utf8.decode(response.bodyBytes.take(200).toList(), allowMalformed: true).replaceAll('\n', ' ');
    if (response.statusCode != 200) {
      throw DeepSeekSpeechError(switch (response.statusCode) {
        401 || 403 => DeepSeekSpeechFailure.unauthorized,
        402 => DeepSeekSpeechFailure.insufficientBalance,
        413 => DeepSeekSpeechFailure.tooLarge,
        429 => DeepSeekSpeechFailure.rateLimited,
        >= 500 => DeepSeekSpeechFailure.busy,
        _ => DeepSeekSpeechFailure.rejected,
      }, note);
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map && json['text'] is String) return (json['text'] as String).trim();
    } on FormatException {
      // Some servers answer text/plain.
      return utf8.decode(response.bodyBytes).trim();
    }
    throw DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, note);
  }
}

/// The cloud recognizer for [mode]: DeepSeek's for deepseek (and for auto,
/// when someone can pay for it), the person's own service for cloud; null
/// when there is none (auto then uses the phone's or the engine's).
typedef VoiceCloudResolver = Future<VoiceCloud?> Function(VoiceMode mode);

final voiceCloudProvider = Provider<VoiceCloudResolver>((ref) {
  return (mode) async {
    switch (mode) {
      case VoiceMode.deepseek || VoiceMode.auto:
        final speech = await ref.read(deepSeekSpeechProvider)();
        return speech == null ? null : DeepSeekVoiceCloud(speech);
      case VoiceMode.cloud:
        final settings = await ref.read(cloudAsrProvider.notifier).ready();
        return settings.configured ? OpenAiVoiceCloud(settings, ref.read(deepSeekSpeechHttpProvider)) : null;
      case VoiceMode.system || VoiceMode.engine:
        return null;
    }
  };
});

/// The engine's own recognizer (the on-device voice model), for a call when
/// no cloud one can be had.
class EngineVoiceCloud implements VoiceCloud {
  EngineVoiceCloud(this._client, this._catalog);
  final DshClient _client;
  final SpeechCatalog _catalog;

  @override
  int get maxSeconds => _catalog.maxSeconds;

  @override
  Future<String> transcribe(Uint8List wav) async {
    try {
      final transcript = await _client.transcribe(wav, providerId: _catalog.providerId, language: _catalog.language);
      return transcript.text;
    } on Object catch (error) {
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.busy, error.toString().split('\n').first);
    }
  }
}

/// The recognizer a 语音通话 uses: it needs one that takes a recording (the
/// phone's own service can't). The chosen mode's first, then DeepSeek's, then
/// the engine's voice model.
final callRecognizerProvider = Provider<Future<VoiceCloud?> Function()>((ref) {
  return () async {
    final mode = await ref.read(voiceSettingsProvider.notifier).ready();
    final cloud = ref.read(voiceCloudProvider);
    Future<VoiceCloud?> engine() async {
      final client = ref.read(activeConnectionProvider).value?.client;
      if (client == null) return null;
      try {
        final catalog = await client.speechCatalog().timeout(const Duration(seconds: 4));
        if (catalog?.selected?.usable ?? false) return EngineVoiceCloud(client, catalog!);
      } catch (_) {
        // No voice model on this engine.
      }
      return null;
    }

    return switch (mode) {
      VoiceMode.engine => await engine() ?? await cloud(VoiceMode.deepseek),
      VoiceMode.cloud => await cloud(VoiceMode.cloud) ?? await cloud(VoiceMode.deepseek) ?? await engine(),
      VoiceMode.auto || VoiceMode.deepseek || VoiceMode.system => await cloud(VoiceMode.deepseek) ?? await engine(),
    };
  };
});
