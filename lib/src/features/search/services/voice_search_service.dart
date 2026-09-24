import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

class VoiceSearchService {
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;

  Future<bool> initSpeech() async {
    _speechEnabled = await _speechToText.initialize(
      onError: (error) => debugPrint('Speech Error: $error'),
      onStatus: (status) => debugPrint('Speech Status: $status'),
    );
    return _speechEnabled;
  }

  void startListening(Function(String) onResult) async {
    if (!_speechEnabled) await initSpeech();
    
    await _speechToText.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          onResult(result.recognizedWords);
        }
      },
      localeId: 'bn_BD', // Default to Bangla as per DNA
    );
  }

  void stopListening() async {
    await _speechToText.stop();
  }

  bool get isListening => _speechToText.isListening;
}
