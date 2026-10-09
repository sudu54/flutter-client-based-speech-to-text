import 'package:flutter/material.dart';

import 'whisper_bridge.dart';

void main() {
  runApp(const WhisperApp());
}

class WhisperApp extends StatelessWidget {
  const WhisperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Whisper Flutter Web',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
        ),
        useMaterial3: true,
      ),
      home: const WhisperHomePage(),
    );
  }
}

class WhisperHomePage extends StatefulWidget {
  const WhisperHomePage({super.key});

  @override
  State<WhisperHomePage> createState() => _WhisperHomePageState();
}

class _WhisperHomePageState extends State<WhisperHomePage> {
  final TextEditingController _controller =
      TextEditingController();

  String _language = 'auto';

  bool _isLoading = false;
  bool _isRecording = false;

  String _status = 'Loading Whisper...';

  // ------------------------------------------------------------
  // Metrics
  // ------------------------------------------------------------

  Stopwatch? _recordingStopwatch;

  double? _modelLoadSeconds;
  double? _recordingSeconds;
  double? _transcriptionSeconds;
  double? _releaseToTextSeconds;

  String _inferenceDevice = 'Unknown';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  // ------------------------------------------------------------
  // Whisper initialization
  // ------------------------------------------------------------

  Future<void> _initialize() async {
    final stopwatch = Stopwatch()..start();

    try {
      setState(() {
        _isLoading = true;
        _status = 'Loading Whisper model...';
      });

      await initializeWhisper();

      _inferenceDevice = getInferenceDevice();


      stopwatch.stop();

      if (!mounted) {
        return;
      }

      setState(() {
        _modelLoadSeconds =
            stopwatch.elapsedMilliseconds / 1000.0;

        _isLoading = false;
        _status = 'Ready';
      });
    } catch (e) {
      stopwatch.stop();

      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _status = 'Failed to load Whisper: $e';
      });
    }
  }

  // ------------------------------------------------------------
  // Start recording
  // ------------------------------------------------------------

  Future<void> _startRecording() async {
    if (_isLoading || _isRecording) {
      return;
    }

    try {
      await startRecording();

      _recordingStopwatch = Stopwatch()..start();

      if (!mounted) {
        return;
      }

      setState(() {
        _isRecording = true;
        _status = 'Listening...';

        // Clear metrics specific to this recording.
        _recordingSeconds = null;
        _transcriptionSeconds = null;
        _releaseToTextSeconds = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isRecording = false;
        _status = 'Microphone error: $e';
      });
    }
  }

  // ------------------------------------------------------------
  // Stop recording and transcribe
  // ------------------------------------------------------------

  Future<void> _stopRecording() async {
    if (!_isRecording) {
      return;
    }

    // Capture the exact time the user released the mic.
    final releaseTime = Stopwatch()..start();

    _recordingStopwatch?.stop();

    final recordingSeconds =
        (_recordingStopwatch?.elapsedMilliseconds ?? 0) /
            1000.0;

    try {
      if (!mounted) {
        return;
      }

      setState(() {
        _isRecording = false;
        _isLoading = true;
        _status = 'Transcribing...';
        _recordingSeconds = recordingSeconds;
      });

      // This is the actual Whisper inference operation.
      final transcriptionStopwatch = Stopwatch()..start();

      final text = await stopRecording(_language);

      transcriptionStopwatch.stop();

      final transcriptionSeconds =
          transcriptionStopwatch.elapsedMilliseconds /
              1000.0;

      // Now add the text to the TextField.
      if (text.isNotEmpty) {
        final current = _controller.text.trim();

        if (current.isEmpty) {
          _controller.text = text;
        } else {
          _controller.text = '$current $text';
        }

        _controller.selection =
            TextSelection.collapsed(
          offset: _controller.text.length,
        );
      }

      /*
       * This is the user-visible latency:
       *
       * mic release
       *      ↓
       * Whisper processing
       *      ↓
       * TextField updated
       */
      releaseTime.stop();

      final releaseToTextSeconds =
          releaseTime.elapsedMilliseconds / 1000.0;

      if (!mounted) {
        return;
      }

      setState(() {
        _transcriptionSeconds = transcriptionSeconds;
        _releaseToTextSeconds =
            releaseToTextSeconds;

        _isLoading = false;
        _status = 'Ready';
      });
    } catch (e) {
      releaseTime.stop();

      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _status = 'Transcription error: $e';
      });
    }
  }

  // ------------------------------------------------------------
  // Metrics UI
  // ------------------------------------------------------------

  Widget _metricRow(
    String label,
    double? value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label),
          ),
          Text(
            value == null
                ? '—'
                : '${value.toStringAsFixed(2)} s',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetrics() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.grey.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          const Text(
            'Metrics',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 10),

          _metricRow(
            'Model load',
            _modelLoadSeconds,
          ),

          _metricRow(
            'Recording',
            _recordingSeconds,
          ),

          _metricRow(
            'Transcription',
            _transcriptionSeconds,
          ),

          _metricRow(
            'Release → text',
            _releaseToTextSeconds,
          ),

          const Divider(),

          Row(
            children: [
              const Expanded(
                child: Text('Inference'),
              ),
              Text(
                _inferenceDevice,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Whisper Large-v3 Turbo',
        ),
        centerTitle: true,
      ),

      body: SafeArea(
  child: SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 700,
        ),
        child: Column(
          children: [
            const SizedBox(height: 20),

            Text(
              'Client-side speech transcription',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 8),

            Text(
              'Audio is transcribed in your browser.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 24),

            TextField(
              controller: _controller,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Transcription',
                hintText:
                    'Your spoken text will appear here...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),

            const SizedBox(height: 16),

            Row(
              children: [
                const Text('Language:'),

                const SizedBox(width: 16),

                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _language,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'auto',
                        child: Text('Auto detect'),
                      ),
                      DropdownMenuItem(
                        value: 'en',
                        child: Text('English'),
                      ),
                      DropdownMenuItem(
                        value: 'hi',
                        child: Text('Hindi'),
                      ),
                      DropdownMenuItem(
                        value: 'kn',
                        child: Text('Kannada'),
                      ),
                      DropdownMenuItem(
                        value: 'ta',
                        child: Text('Tamil'),
                      ),
                      DropdownMenuItem(
                        value: 'te',
                        child: Text('Telugu'),
                      ),
                      DropdownMenuItem(
                        value: 'ml',
                        child: Text('Malayalam'),
                      ),
                      DropdownMenuItem(
                        value: 'mr',
                        child: Text('Marathi'),
                      ),
                      DropdownMenuItem(
                        value: 'bn',
                        child: Text('Bengali'),
                      ),
                      DropdownMenuItem(
                        value: 'gu',
                        child: Text('Gujarati'),
                      ),
                      DropdownMenuItem(
                        value: 'pa',
                        child: Text('Punjabi'),
                      ),
                    ],
                    onChanged: _isRecording || _isLoading
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }

                            setState(() {
                              _language = value;
                            });
                          },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            GestureDetector(
              onTapDown: (_) {
                _startRecording();
              },
              onTapUp: (_) {
                _stopRecording();
              },
              onTapCancel: () {
                _stopRecording();
              },
              child: AnimatedContainer(
                duration: const Duration(
                  milliseconds: 150,
                ),
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isRecording
                      ? Colors.red
                      : theme.colorScheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: (_isRecording
                              ? Colors.red
                              : theme.colorScheme.primary)
                          .withValues(alpha: 0.30),
                      blurRadius: 18,
                      spreadRadius:
                          _isRecording ? 5 : 0,
                    ),
                  ],
                ),
                child: Icon(
                  _isRecording
                      ? Icons.stop
                      : Icons.mic,
                  color: Colors.white,
                  size: 38,
                ),
              ),
            ),

            const SizedBox(height: 12),

            Text(
              _isRecording
                  ? 'Release to transcribe'
                  : 'Press and hold to speak',
              style: theme.textTheme.bodyLarge,
            ),

            const SizedBox(height: 16),

            _buildMetrics(),

            const SizedBox(height: 12),

            if (_isLoading)
              const SizedBox(
                width: 250,
                child: LinearProgressIndicator(),
              ),

            const SizedBox(height: 8),

            Text(
              _status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),

            const SizedBox(height: 20),

            Text(
              'Whisper large-v3-turbo • ONNX • Browser-side inference',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  ),
),
);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}





