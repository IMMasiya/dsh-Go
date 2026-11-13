// Live captions for a call: the call's own microphone (a PCM tap on the native
// capture, no second recorder) through the phone's streaming recognizer, while
// the downloaded model is there. What the person says appears as they say it.

import 'dart:async';

import '../../../voice/streaming_asr.dart';
import '../../../voice/streaming_pcm.dart';

class CallLiveCaptions {
  CallLiveCaptions(this._pcm, this._asr, this._model, this._onWords);

  final StreamingPcmCapture _pcm;
  final StreamingAsr _asr;
  final StreamingAsrModel _model;
  final void Function(String words) _onWords;
  StreamSubscription<StreamingAsrEvent>? _events;
  StreamSubscription<Object>? _frames;

  Future<void> start() async {
    _events = _asr.events.listen((event) => _onWords(event.text));
    await _asr.start(_model);
    // A frame that lands while it stops is simply not heard.
    _frames = _pcm.frames.listen((frame) => unawaited(_asr.feed(frame).catchError((Object _) {})));
    await _pcm.start(StreamingPcmSource.call);
  }

  Future<void> stop() async {
    await _pcm.stop();
    await _frames?.cancel();
    await _asr.stop(finalize: false);
    await _events?.cancel();
  }
}
