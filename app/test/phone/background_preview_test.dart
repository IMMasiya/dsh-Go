// Real PhoneChannel/EventChannel and dialog; the native stream alone is synthetic.
// No replacement parser/decoder and no wall-clock sleeps. Engine decode is joined
// through Image.onCreate; lifecycle/cancel races use explicit barriers.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/ui/phone/background_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

const _events = EventChannel('test/phone/background-preview');
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAFElEQVR4nGPUiFrAwMDAxMDAgKAAFWIBKNw5NZUAAAAASUVORK5CYII=',
);

Map<String, Object?> _event(String state, int sequence, {int task = 7, int generation = 1}) => {
  'taskId': task, 'generation': generation, 'sequence': sequence, 'state': state,
  'width': state == 'frame' ? 2 : 0, 'height': state == 'frame' ? 3 : 0,
  'imageBytes': state == 'frame' ? _png : null,
};

class _NativePreview {
  final calls = <String>[];
  final arguments = <Object?>[];
  MockStreamHandlerEventSink? sink;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (args, events) {
          calls.add('listen'); arguments.add(args); sink = events;
        },
        onCancel: (_) { calls.add('cancel'); sink = null; },
      ),
    );
  }

  void emit(Object? event) => sink!.success(event);
}

/// MockStreamHandler.onCancel is void. Delay only the encoded ACK, so the
/// production subscription must await its actual cancel Future before re-listen.
class _CancelAckMessenger implements BinaryMessenger {
  _CancelAckMessenger(this.delegate);
  final TestDefaultBinaryMessenger delegate;
  Completer<void>? cancelAck;
  final calls = <String>[];

  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    final call = channel == _events.name && message != null
        ? _events.codec.decodeMethodCall(message) : null;
    if (call != null) calls.add(call.method);
    final response = await delegate.send(channel, message);
    if (call?.method == 'cancel') await cancelAck?.future;
    return response;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) => delegate.setMessageHandler(channel, handler);

  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data, ui.PlatformMessageResponseCallback? callback) =>
      delegate.handlePlatformMessage(channel, data, callback);
}

/// Observes the real engine image handles without intercepting codec work.
class _Images {
  final previousCreate = ui.Image.onCreate;
  final previousDispose = ui.Image.onDispose;
  final created = <ui.Image>[];
  final disposed = <ui.Image>[];
  Completer<ui.Image>? next;
  void Function()? retireOnCreate;

  void install() {
    ui.Image.onCreate = (image) {
      previousCreate?.call(image);
      if (image.width != 2 || image.height != 3) return;
      created.add(image);
      final pending = next;
      next = null;
      final retire = retireOnCreate;
      retireOnCreate = null;
      retire?.call();
      pending?.complete(image);
    };
    ui.Image.onDispose = (image) {
      disposed.add(image);
      previousDispose?.call(image);
    };
  }

  void restore() {
    ui.Image.onCreate = previousCreate;
    ui.Image.onDispose = previousDispose;
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) { await tester.pump(); }
}

void _pause(WidgetTester tester) {
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

Future<void> _mount(WidgetTester tester, PhoneChannel channel, {bool resumed = true}) async {
  _resume(tester);
  if (!resumed) _pause(tester);
  await tester.pumpWidget(goldenApp(
    brightness: Brightness.light,
    home: PhoneBackgroundPreviewDialog(channel: channel, taskId: 7),
  ));
  await _flush(tester);
}

Future<ui.Image> _frame(WidgetTester tester, _NativePreview native, _Images images, int sequence) async {
  final made = Completer<ui.Image>();
  images.next = made;
  native.emit(_event('frame', sequence));
  await _flush(tester); // Deliver EventChannel and start the real engine codec.
  final image = (await tester.runAsync(() => made.future.timeout(const Duration(seconds: 10))))!;
  await _flush(tester); // Join the dialog continuation and any render handle clone.
  return image;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
  _resume(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preview parser accepts every non-image state and rejects malformed identity', () {
    for (final state in ['off', 'waiting', 'unavailable', 'protected']) {
      final value = PhonePreviewFrame.parse(_event(state, 0));
      expect(value?.state, state);
      expect(value?.imageBytes, isNull);
    }
    for (final malformed in [
      null, 'frame', _event('busy', 1), _event('waiting', -1),
      _event('waiting', 1, task: 0), _event('waiting', 1, generation: -1),
      {..._event('waiting', 1), 'taskId': 7.0},
    ]) { expect(PhonePreviewFrame.parse(malformed), isNull); }
    final legacy = PhoneBackgroundStatus.fromMap({});
    expect(legacy.previewVersion, isNull);
    expect(legacy.previewEnabled, isFalse);
  });

  test('frame parser bounds byte payload and geometry independently', () {
    expect(PhonePreviewFrame.parse(_event('frame', 1))?.imageBytes, same(_png));
    expect(PhonePreviewFrame.parse({..._event('frame', 1), 'imageBytes': Uint8List(128 * 1024)}), isNotNull);
    for (final fields in <Map<String, Object?>>[
      {'imageBytes': Uint8List(0)}, {'imageBytes': Uint8List(128 * 1024 + 1)},
      {'imageBytes': [1, 2, 3]}, {'imageBytes': null}, {'width': 0},
      {'width': 801}, {'height': 801}, {'height': 1.5},
    ]) { expect(PhonePreviewFrame.parse({..._event('frame', 1), ...fields}), isNull); }
  });

  testWidgets('only resumed and current route subscribes; covering route cancels', (tester) async {
    final native = _NativePreview()..install();
    await _mount(tester, PhoneChannel(preview: _events), resumed: false);
    expect(native.calls, isEmpty);
    _resume(tester);
    await _flush(tester);
    expect(native.calls, ['listen']);
    expect(native.arguments, [{'taskId': 7}]);
    native.emit(_event('waiting', 0));
    await _flush(tester);
    expect(find.text(appL10n.phonePreviewWaiting), findsOneWidget);
    final navigator = Navigator.of(tester.element(find.byType(PhoneBackgroundPreviewDialog)));
    unawaited(navigator.push<void>(PageRouteBuilder<void>(
      opaque: false, transitionDuration: Duration.zero, reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const Scaffold(body: Text('cover')),
    )));
    await _flush(tester);
    expect(native.calls, ['listen', 'cancel']);
    navigator.pop();
    await _flush(tester);
    expect(native.calls, ['listen', 'cancel', 'listen']);
    await _unmount(tester);
    expect(native.calls.last, 'cancel');
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid background and resume awaits cancel ACK before another listen', (tester) async {
    final native = _NativePreview()..install();
    final gate = _CancelAckMessenger(TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger);
    final channel = PhoneChannel(preview: EventChannel(_events.name, _events.codec, gate));
    await _mount(tester, channel);
    final ack = Completer<void>();
    gate.cancelAck = ack;
    try {
      _pause(tester);
      _resume(tester);
      await _flush(tester);
      expect(gate.calls, ['listen', 'cancel']);
      expect(native.calls, ['listen', 'cancel']);
      ack.complete();
      await _flush(tester);
      expect(gate.calls, ['listen', 'cancel', 'listen']);
    } finally {
      if (!ack.isCompleted) ack.complete();
      gate.cancelAck = null;
      await _unmount(tester);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover and background release decoded images without ImageCache', (tester) async {
    final native = _NativePreview()..install();
    final images = _Images()..install();
    try {
      await _mount(tester, PhoneChannel(preview: _events));
      final cache = PaintingBinding.instance.imageCache;
      final entries = cache.currentSize;
      final live = cache.liveImageCount;
      final image = await _frame(tester, native, images, 1);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(image));
      expect(image.debugDisposed, isFalse);
      expect(cache.currentSize, entries);
      expect(cache.liveImageCount, live);
      final navigator = Navigator.of(tester.element(find.byType(PhoneBackgroundPreviewDialog)));
      unawaited(navigator.push<void>(PageRouteBuilder<void>(
        opaque: false, transitionDuration: Duration.zero, reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const Scaffold(body: Text('cover')),
      )));
      await _flush(tester);
      expect(find.byType(RawImage, skipOffstage: false), findsNothing);
      expect(image.debugDisposed, isTrue);
      expect(images.disposed.where((value) => identical(value, image)), hasLength(1));
      expect(native.calls, ['listen', 'cancel']);
      navigator.pop();
      await _flush(tester);
      final next = await _frame(tester, native, images, 2);
      _pause(tester);
      await _flush(tester);
      expect(find.byType(RawImage, skipOffstage: false), findsNothing);
      expect(next.debugDisposed, isTrue);
      expect(native.calls, ['listen', 'cancel', 'listen', 'cancel']);
    } finally {
      try {
        await _unmount(tester);
        expect(images.created.every((image) => image.debugDisposed), isTrue,
            reason: 'Both owner handles and RawImage render clones must retire.');
      } finally { images.restore(); }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('task, generation and sequence reject late state; a newer clear releases pixels', (tester) async {
    final native = _NativePreview()..install();
    final images = _Images()..install();
    try {
      await _mount(tester, PhoneChannel(preview: _events));
      final image = await _frame(tester, native, images, 10);
      for (final event in [
        _event('off', 99, task: 8), _event('off', 99, generation: 0),
        _event('off', 9), _event('off', 10),
      ]) { native.emit(event); }
      await _flush(tester);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(image));
      native.emit(_event('off', 11));
      await _flush(tester);
      expect(find.byType(RawImage), findsNothing);
      expect(find.text(appL10n.phonePreviewOff), findsOneWidget);
      expect(image.debugDisposed, isTrue);
      // Older waiting/protected events must not revive or relabel the cleared observation.
      native.emit(_event('waiting', 10));
      native.emit(_event('protected', 99, task: 8));
      await _flush(tester);
      expect(find.text(appL10n.phonePreviewOff), findsOneWidget);
      final recovered = await _frame(tester, native, images, 12);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(recovered));
      native.emit({'malformed': true});
      await _flush(tester);
      expect(find.byType(RawImage), findsNothing);
      expect(recovered.debugDisposed, isTrue);
      expect(find.text(appL10n.phonePreviewUnavailable), findsOneWidget);
    } finally {
      try {
        await _unmount(tester);
        expect(images.created.every((image) => image.debugDisposed), isTrue,
            reason: 'Both owner handles and RawImage render clones must retire.');
      } finally { images.restore(); }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('image created after the viewer retires is disposed without becoming RawImage', (tester) async {
    final native = _NativePreview()..install();
    final images = _Images()..install();
    try {
      await _mount(tester, PhoneChannel(preview: _events));
      // The real codec calls onCreate before returning its FrameInfo. Retire the
      // consumer at this exact boundary, not after an arbitrary timed sleep.
      images.retireOnCreate = () => _pause(tester);
      final late = await _frame(tester, native, images, 1);
      expect(late.debugDisposed, isTrue);
      expect(images.disposed.where((value) => identical(value, late)), hasLength(1));
      expect(find.byType(RawImage), findsNothing);
      expect(native.calls, ['listen', 'cancel']);
    } finally {
      try {
        await _unmount(tester);
        expect(images.created.every((image) => image.debugDisposed), isTrue,
            reason: 'Both owner handles and RawImage render clones must retire.');
      } finally { images.restore(); }
    }
    expect(tester.takeException(), isNull);
  });
}
