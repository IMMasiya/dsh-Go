// Words as they are spoken: a recorder's PCM (a tap on the native capture, no
// second recorder) through the phone's streaming recognizer, while its model is
// downloaded. A call shows them as captions; dictation as provisional text.

import 'dart:async';

import 'streaming_asr.dart';
import 'streaming_pcm.dart';

class LiveWords {
  LiveWords(this._pcm, this._asr, this._model, this._source, this._onWords);

  final StreamingPcmCapture _pcm;
  final StreamingAsr _asr;
  final StreamingAsrModel _model;
  final StreamingPcmSource _source;
  final void Function(String words) _onWords;
  StreamSubscription<StreamingAsrEvent>? _events;
  StreamSubscription<Object>? _frames;

  Future<void> start() async {
    _events = _asr.events.listen((event) => _onWords(event.text));
    await _asr.start(_model);
    // A frame that lands while it stops is simply not heard.
    _frames = _pcm.frames.listen((frame) => unawaited(_asr.feed(frame).catchError((Object _) {})));
    await _pcm.start(_source);
  }

  Future<void> stop() async {
    await _pcm.stop();
    await _frames?.cancel();
    await _asr.stop(finalize: false);
    await _events?.cancel();
  }
}
