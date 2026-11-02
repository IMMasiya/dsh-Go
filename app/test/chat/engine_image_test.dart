import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _engine = 'http://127.0.0.1:3080';
const _emoji = '$_engine/api/dsh-emoji/assets/deepseek/8/ds_01.png';

class _Reader implements WorkspaceImageReader {
  final reads = <String>[];
  bool fails = false;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    reads.add(path);
    if (fails) throw const DshHttpException(401, 'unauthorized');
    return RasterImage(MemoryImage(Uint8List(0)));
  }
}

void main() {
  late _Reader reader;

  Widget scene(String url) => testApp(
    Scaffold(body: MarkdownImage(url: url)),
    overrides: [
      artifactFilesProvider.overrideWithValue(
        ArtifactFiles(
          connection: HostConnection(
            client: DshClient.withCarrier(DshHttpCarrier(DshConnection(Uri.parse(_engine)))),
            isLocal: true,
          ),
          channel: const FilesChannel(),
        ),
      ),
      engineImageReaderProvider.overrideWith((ref) => CachedImageReader(reader)),
    ],
  );

  setUp(() => reader = _Reader());

  // #361: the engine's own assets answer 401 to a plain NetworkImage.
  testWidgets('an image on the engine address is read through the session', (tester) async {
    await tester.pumpWidget(scene(_emoji));
    await tester.pump();
    expect(reader.reads, [_emoji]);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage), findsNothing);
  });

  testWidgets('an image on any other address stays a plain web image', (tester) async {
    await tester.pumpWidget(scene('https://example.com/a.png'));
    await tester.pump();
    expect(reader.reads, isEmpty);
  });

  testWidgets('a failed engine image shows why and a retry reads it again', (tester) async {
    reader.fails = true;
    await tester.pumpWidget(scene(_emoji));
    await tester.pump();
    await tester.pump();
    expect(reader.reads, [_emoji]);
    final retry = find.textContaining('重试');
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump();
    expect(reader.reads, [_emoji, _emoji]);
    expect(tester.takeException(), isNull);
  });
}
