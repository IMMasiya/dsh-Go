import 'package:flutter/services.dart';

/// 安卓原生灵动岛（Android 16 实时更新）的桥。
///
/// 只有回合进行中才发：开始 → [start]，进度变化 → [update]，结束 → [stop]。
/// 系统不接受（版本太低、用户关了开关、没有前台服务）时通知退化成普通常驻通知，
/// 这些判断都在原生侧，Dart 这边只负责按回合生命周期调用。
class LiveUpdates {
  static const MethodChannel _channel = MethodChannel('dsh/notify');

  static Future<void> start({
    required String sessionId,
    String title = '',
    String text = '',
  }) =>
      _call('liveStart', {
        'sessionId': sessionId,
        'title': title,
        'text': text,
      });

  static Future<void> update({
    String? sessionId,
    int? percent,
    String? text,
  }) =>
      _call('liveUpdate', {
        'sessionId': sessionId,
        'percent': percent,
        'text': text,
      });

  static Future<void> stop({String? sessionId}) =>
      _call('liveStop', {'sessionId': sessionId});

  /// 原生没有这个通道（比如桌面端或旧构建）时静默失败：实时更新只是锦上添花。
  static Future<void> _call(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // 忽略：不影响会话本身。
    }
  }
}
