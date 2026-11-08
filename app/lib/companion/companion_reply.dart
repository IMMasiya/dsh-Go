// What the companion's reply text carries besides words: `[表情:开心]` and
// `[动作:点头]` marks, written by the model as the persona asks
// (runtime/bridge/dsh-go-bridge/cordis.patch.yml). The page shows the words and
// hands the marks to the stage. Pure, and fed the whole text so far on every
// streaming update.

import 'package:flutter/foundation.dart';

/// A faces the stage knows (`emotions` in app/assets/companion/stage.js).
const _emotions = {
  '平静': 'calm',
  'calm': 'calm',
  '开心': 'happy',
  '高兴': 'happy',
  'happy': 'happy',
  '害羞': 'shy',
  '脸红': 'shy',
  'shy': 'shy',
  '难过': 'sad',
  '伤心': 'sad',
  'sad': 'sad',
  '生气': 'angry',
  '黑脸': 'angry',
  'angry': 'angry',
  '惊讶': 'surprised',
  'surprised': 'surprised',
  '疑惑': 'confused',
  '困惑': 'confused',
  'confused': 'confused',
  '得意': 'smug',
  'smug': 'smug',
  '困': 'sleepy',
  '犯困': 'sleepy',
  'sleepy': 'sleepy',
  '担心': 'worried',
  'worried': 'worried',
};

const _actions = {
  '点头': 'nod',
  'nod': 'nod',
  '摇头': 'shake',
  'shake': 'shake',
  '歪头': 'tilt',
  'tilt': 'tilt',
  '抬头': 'lookUp',
  'lookUp': 'lookUp',
  '低头': 'duck',
  'duck': 'duck',
  '挥手': 'wave',
  'wave': 'wave',
  '跳一下': 'hop',
  '蹦': 'hop',
  'hop': 'hop',
  '摇尾巴': 'tail',
  'tail': 'tail',
};

enum CompanionMarkKind { emotion, action }

/// Whether [name] is already one of her own marks, which a model's own move of
/// the same name can't take over.
bool companionMarkKnown(CompanionMarkKind kind, String name) {
  final known = kind == CompanionMarkKind.emotion ? _emotions : _actions;
  return known.containsKey(name) || known.containsKey(name.toLowerCase());
}

@immutable
class CompanionMark {
  const CompanionMark(this.kind, this.name);

  final CompanionMarkKind kind;

  /// The stage's name for it.
  final String name;

  @override
  bool operator ==(Object other) => other is CompanionMark && other.kind == kind && other.name == name;

  @override
  int get hashCode => Object.hash(kind, name);

  @override
  String toString() => '${kind.name}:$name';
}

@immutable
class CompanionReply {
  const CompanionReply(this.words, this.marks);

  /// What to show: the text without marks.
  final String words;

  /// Marks in the order they appear; unknown names are dropped.
  final List<CompanionMark> marks;
}

final _mark = RegExp(r'[\[【]\s*(表情|动作|emotion|action)\s*[:：]\s*([^\]】\n]{1,16}?)\s*[\]】]', caseSensitive: false);

/// A mark still arriving at the end of the stream: held back so it never flashes.
final _partialMark = RegExp(
  r'[\[【](?:\s*(?:表|表情|动|动作|e|em|emo|emot|emoti|emotio|emotion|a|ac|act|acti|actio|action)?\s*(?:[:：][^\]】\n]{0,16})?)?$',
  caseSensitive: false,
);

/// Reads [text]. While [streaming], a trailing partial mark is held back.
/// [emotions] and [actions] map the labels of the model's own expressions and
/// motions to their raw names (companion_moves.dart); hers come first, since
/// they carry her pose as well as a face.
CompanionReply parseCompanionReply(
  String text, {
  bool streaming = false,
  Map<String, String> emotions = const {},
  Map<String, String> actions = const {},
}) {
  final marks = <CompanionMark>[];
  var words = text.replaceAllMapped(_mark, (m) {
    final kind = m[1]!.toLowerCase();
    final name = m[2]!;
    if (kind == '表情' || kind == 'emotion') {
      final emotion = _emotions[name] ?? _emotions[name.toLowerCase()] ?? emotions[name];
      if (emotion != null) marks.add(CompanionMark(CompanionMarkKind.emotion, emotion));
    } else {
      final action = _actions[name] ?? _actions[name.toLowerCase()] ?? actions[name];
      if (action != null) marks.add(CompanionMark(CompanionMarkKind.action, action));
    }
    return '';
  });
  if (streaming) words = words.replaceFirst(_partialMark, '');
  return CompanionReply(words.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim(), marks);
}

/// What goes in front of a message the person sends: the small facts the model
/// can't otherwise know, in the 〔〕 aside the persona explains. Null without any.
String? companionAside({DateTime? now, List<String> notes = const []}) {
  final parts = [
    if (now != null)
      '${now.month}月${now.day}日 ${_weekday[now.weekday - 1]} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    ...notes,
  ];
  return parts.isEmpty ? null : '〔${parts.join('，')}〕';
}

const _weekday = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// The aside line [companionAside] writes: it always starts with the date.
final _asideLine = RegExp(r'^〔\d{1,2}月\d{1,2}日 周[一二三四五六日] \d{2}:\d{2}[^\n]*〕$');

/// What the person actually typed, out of a message the page sent: whatever
/// the page put in front of it (the persona, its changes, her name, moves) all
/// comes before the aside, and the aside comes last. A message with no aside
/// is already only theirs.
String companionSaidText(String sent) {
  final lines = sent.split('\n');
  final aside = lines.indexWhere(_asideLine.hasMatch);
  if (aside < 0) return sent;
  return lines.skip(aside + 1).join('\n').trim();
}

/// How to greet someone coming back, from the clock and how long they were
/// away. Never reproachful: absence is news to her, not a debt.
enum CompanionGreeting { firstTime, morning, noon, afternoon, evening, lateNight, longAbsence, justNow }

CompanionGreeting companionGreeting(DateTime now, DateTime? lastSeen) {
  if (lastSeen == null) return CompanionGreeting.firstTime;
  final away = now.difference(lastSeen);
  if (away < const Duration(minutes: 20)) return CompanionGreeting.justNow;
  if (away > const Duration(days: 3)) return CompanionGreeting.longAbsence;
  return switch (now.hour) {
    >= 0 && < 5 => CompanionGreeting.lateNight,
    < 11 => CompanionGreeting.morning,
    < 14 => CompanionGreeting.noon,
    < 18 => CompanionGreeting.afternoon,
    < 23 => CompanionGreeting.evening,
    _ => CompanionGreeting.lateNight,
  };
}
