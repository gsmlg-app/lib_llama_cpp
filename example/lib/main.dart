import 'package:flutter/material.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';

void main() {
  runApp(const InferenceDemoApp());
}

final class InferenceDemoApp extends StatelessWidget {
  const InferenceDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'lib_llama_cpp',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const InferenceDemoScreen(),
    );
  }
}

final class InferenceDemoScreen extends StatefulWidget {
  const InferenceDemoScreen({super.key});

  @override
  State<InferenceDemoScreen> createState() => _InferenceDemoScreenState();
}

final class _InferenceDemoScreenState extends State<InferenceDemoScreen> {
  final _client = const LibLlamaCpp();
  final _events = <String>[];
  var _isRunning = false;

  Future<void> _runStream() async {
    if (_isRunning) {
      return;
    }

    setState(() {
      _events.clear();
      _isRunning = true;
    });

    final commands = Stream<LlamaCommand>.fromIterable([
      const LlamaLoadModelCommand(modelPath: '/models/tinyllama.gguf'),
      const LlamaGenerateCommand(prompt: 'Write one sentence.', maxTokens: 16),
      const LlamaDisposeCommand(),
    ]);

    try {
      await for (final response in _client.transform(commands)) {
        if (!mounted) {
          return;
        }
        setState(() => _events.add(response.toString()));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _events.add(error.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _isRunning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('lib_llama_cpp')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: _isRunning ? null : _runStream,
                icon: _isRunning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_isRunning ? 'Running' : 'Run isolate stream'),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _events.isEmpty
                      ? const Center(child: Text('No events yet'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _events.length,
                          separatorBuilder: (context, index) => const Divider(),
                          itemBuilder: (context, index) {
                            return SelectableText(_events[index]);
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
