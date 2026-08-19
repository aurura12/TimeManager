import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef SpeechTextCallback = void Function(String text, bool isFinal);

class SpeechRecognitionService {
  final SpeechToText _speech;
  bool _initialized = false;

  SpeechRecognitionService({SpeechToText? speech})
      : _speech = speech ?? SpeechToText();

  bool get isListening => _speech.isListening;

  Future<bool> start({
    required SpeechTextCallback onText,
    void Function(String message)? onError,
    void Function(String status)? onStatus,
  }) async {
    try {
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onError: (error) => onError?.call(error.errorMsg),
          onStatus: onStatus,
          options: [SpeechToText.androidNoBluetooth],
        );
      }
      if (!_initialized) {
        onError?.call('设备暂不支持语音识别或麦克风权限未开启');
        return false;
      }

      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          onText(result.recognizedWords, result.finalResult);
        },
        listenOptions: SpeechListenOptions(
          localeId: 'zh_CN',
          partialResults: true,
          cancelOnError: true,
          pauseFor: const Duration(seconds: 2),
          listenFor: const Duration(seconds: 30),
        ),
      );
      return true;
    } catch (_) {
      onError?.call('语音识别启动失败，请检查麦克风权限');
      return false;
    }
  }

  Future<void> stop() => _speech.stop();

  Future<void> cancel() => _speech.cancel();
}
