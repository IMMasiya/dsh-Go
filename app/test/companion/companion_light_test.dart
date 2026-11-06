import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_light.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _sse(List<Map<String, Object?>> events) =>
    [for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join();

Map<String, Object?> _text(String text) => {
  'type': 'content_block_delta',
  'index': 0,
  'delta': {'type': 'text_delta', 'text': text},
};

MockClient _answering(int status, String body, {void Function(http.BaseRequest, String)? seen}) =>
    MockClient.streaming((request, bodyStream) async {
      seen?.call(request, await bodyStream.bytesToString());
      return http.StreamedResponse(Stream.value(utf8.encode(body)), status);
    });

void main() {
  group('reply', () {
    test('asks DeepSeek the way the engine does and streams her words', () async {
      late http.BaseRequest request;
      late Map<String, Object?> body;
      final client = _answering(
        200,
        _sse([
          {'type': 'message_start', 'message': <String, Object?>{}},
          {'type': 'ping'},
          _text('[表情:开心]'),
          _text('你来啦。'),
          {'type': 'message_delta', 'delta': <String, Object?>{}},
          {'type': 'message_stop'},
        ]),
        seen: (r, b) {
          request = r;
          body = jsonDecode(b) as Map<String, Object?>;
        },
      );
      final words = await streamCompanionReply(
        client: client,
        apiKey: 'sk-test',
        system: '你是鲸鱼娘',
        lines: const [CompanionLine.user('你好')],
      ).toList();
      expect(words.join(), '[表情:开心]你来啦。');
      expect(request.url.toString(), 'https://api.deepseek.com/anthropic/v1/messages');
      expect(request.headers['x-api-key'], 'sk-test');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(body['model'], 'deepseek-flash');
      expect(body['stream'], isTrue);
      expect(body['thinking'], {'type': 'disabled'});
      expect(body['system'], '你是鲸鱼娘');
      expect(body['messages'], [
        {'role': 'user', 'content': '你好'},
      ]);
    });

    test('a refused key, a busy model and an error event say which', () async {
      Future<CompanionLightFailure> failure(MockClient client) async {
        try {
          await streamCompanionReply(
            client: client,
            apiKey: 'k',
            system: 's',
            lines: const [CompanionLine.user('hi')],
          ).toList();
        } on CompanionLightError catch (error) {
          return error.failure;
        }
        fail('no error');
      }

      expect(await failure(_answering(401, '{"error":"bad key"}')), CompanionLightFailure.badKey);
      expect(await failure(_answering(429, '')), CompanionLightFailure.busy);
      expect(await failure(_answering(500, 'oops')), CompanionLightFailure.server);
      expect(
        await failure(
          _answering(
            200,
            _sse([
              _text('嗯'),
              {
                'type': 'error',
                'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
              },
            ]),
          ),
        ),
        CompanionLightFailure.busy,
      );
      expect(
        await failure(MockClient.streaming((_, _) async => throw const SocketException('offline'))),
        CompanionLightFailure.network,
      );
    });
  });

  group('history', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('companion-light'));
    tearDown(() => root.deleteSync(recursive: true));

    test('what the model gets starts with the person and alternates', () {
      final history = CompanionLightHistory.at(root)
        ..add(const CompanionLine.her('上一次的话'))
        ..add(const CompanionLine.user('在吗'))
        ..add(const CompanionLine.user('〔她刚才被摸了头〕\n嘿'))
        ..add(const CompanionLine.her('在呀'));
      expect(history.context().map((l) => (l.role, l.text)), [('user', '在吗\n〔她刚才被摸了头〕\n嘿'), ('assistant', '在呀')]);
    });

    test('only the latest lines go out, and only so many are kept', () {
      final history = CompanionLightHistory.at(root);
      for (var i = 0; i < 100; i++) {
        history
          ..add(CompanionLine.user('问$i'))
          ..add(CompanionLine.her('答$i'));
      }
      expect(history.lines, hasLength(CompanionLightHistory.keep));
      final sent = history.context();
      expect(sent, hasLength(CompanionLightHistory.window));
      expect(sent.first.fromHer, isFalse);
      expect(sent.last.text, '答99');
    });

    test('kept on disk; an unanswered line can be taken back; clear forgets', () async {
      final history = CompanionLightHistory.at(root)
        ..add(const CompanionLine.user('你好'))
        ..add(const CompanionLine.her('你好呀'))
        ..add(const CompanionLine.user('没回的话'));
      expect(history.dropUnanswered()?.text, '没回的话');
      expect(history.dropUnanswered(), isNull);
      await history.save();

      final again = CompanionLightHistory.at(root);
      await again.load();
      expect(again.lines.map((l) => l.text), ['你好', '你好呀']);

      await again.clear();
      final empty = CompanionLightHistory.at(root);
      await empty.load();
      expect(empty.lines, isEmpty);
    });

    test('an unreadable file starts afresh', () async {
      File('${root.path}/light-chat.json').writeAsStringSync('{not json');
      final history = CompanionLightHistory.at(root);
      await history.load();
      expect(history.lines, isEmpty);
    });
  });
}
