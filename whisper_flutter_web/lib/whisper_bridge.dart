import 'dart:js_interop';

@JS('whisperApp.initialize')
external JSPromise<JSBoolean> _initialize();

@JS('whisperApp.startRecording')
external JSPromise<JSAny?> _startRecording();

@JS('whisperApp.stopRecording')
external JSPromise<JSString> _stopRecording(JSString language);

Future<bool> initializeWhisper() async {
  final result = await _initialize().toDart;
  return result.toDart;
}

Future<void> startRecording() async {
  await _startRecording().toDart;
}

Future<String> stopRecording(String language) async {
  final result = await _stopRecording(language.toJS).toDart;
  return result.toDart;
}

@JS('whisperFlutterInferenceDevice')
external JSString? get _inferenceDevice;

String getInferenceDevice() {
  return _inferenceDevice?.toDart ?? 'Unknown';
}