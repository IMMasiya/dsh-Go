// The WebView that draws the companion (app/assets/companion/). Everything
// Live2D happens in there; this widget serves it, passes commands in and events
// out, and pauses it when nobody can see it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../companion/companion_pack.dart';
import '../../companion/companion_server.dart';
import '../plugins/islands/island_platform.dart';

/// Phones with less memory than this get a smaller texture (4096² is about
/// 64 MB of GPU memory, more with mipmaps).
const _bigTextureFromBytes = 6 * 1024 * 1024 * 1024;

/// Sends commands to the stage; does nothing until it is ready.
class CompanionStageController {
  CompanionStageController({this.sink});

  /// Tests watch commands here instead of a WebView.
  final void Function(String type, Map<String, Object?> args)? sink;

  WebViewController? _web;
  bool _ready = false;

  void command(String type, [Map<String, Object?> args = const {}]) {
    sink?.call(type, args);
    final web = _web;
    if (web == null || !_ready) return;
    // Structured and JSON-encoded: nothing from a reply becomes script.
    unawaited(web.runJavaScript('stage.command(${jsonEncode({'type': type, ...args})})').catchError((Object _) {}));
  }
}

/// What the stage tells the page.
class CompanionStageEvents {
  const CompanionStageEvents({
    required this.onReady,
    required this.onFailed,
    required this.onTouch,
    required this.onWake,
    required this.onMood,
  });

  final VoidCallback onReady;
  final ValueChanged<String> onFailed;
  final void Function(String zone, String kind) onTouch;
  final VoidCallback onWake;
  final ValueChanged<String> onMood;
}

class CompanionStage extends StatefulWidget {
  const CompanionStage({super.key, required this.store, required this.controller, required this.events});

  final CompanionPackStore store;
  final CompanionStageController controller;
  final CompanionStageEvents events;

  @override
  State<CompanionStage> createState() => _CompanionStageState();
}

class _CompanionStageState extends State<CompanionStage> with WidgetsBindingObserver {
  static const _readyTimeout = Duration(seconds: 40);

  CompanionServer? _server;
  WebViewController? _web;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    try {
      final server = await CompanionServer.start(rootBundle, widget.store.pack);
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;
      final device = await IslandPlatform.instance.device();
      final small = device.totalMem > 0 && device.totalMem < _bigTextureFromBytes;
      final web = WebViewController(onPermissionRequest: (request) => unawaited(request.deny()));
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(const Color(0xFF0D2F55));
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              server.ownsUrl(request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) _fail('load ${error.errorCode}');
          },
        ),
      );
      await web.addJavaScriptChannel('DshCompanion', onMessageReceived: (m) => _onMessage(m.message));
      if (!mounted) return;
      setState(() {
        _web = web;
        widget.controller._web = web;
      });
      _timeout = Timer(_readyTimeout, () => _fail('timeout'));
      await web.loadRequest(
        server.pageUrl(query: {if (small) 'maxTexture': '2048', if (reduceMotion) 'reduceMotion': '1'}),
      );
    } on Object catch (error) {
      _fail('$error');
    }
  }

  void _onMessage(String raw) {
    if (!mounted) return;
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    final events = widget.events;
    switch (message['type']) {
      case 'ready':
        _timeout?.cancel();
        widget.controller._ready = true;
        events.onReady();
      case 'error':
        _fail('${message['message']}');
      case 'touch':
        final zone = message['zone'];
        final kind = message['kind'];
        if (zone is String && kind is String) events.onTouch(zone, kind);
      case 'wake':
        events.onWake();
      case 'mood':
        final mood = message['mood'];
        if (mood is String) events.onMood(mood);
    }
  }

  void _fail(String why) {
    _timeout?.cancel();
    if (mounted) widget.events.onFailed(why);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.controller.command('resume');
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        widget.controller.command('pause');
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    widget.controller
      .._web = null
      .._ready = false;
    unawaited(_server?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    if (web == null) return const SizedBox.expand();
    return WebViewWidget(
      controller: web,
      // Her touch handling lives in the page: strokes must not become scrolls
      // or the back gesture's competitors.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}
