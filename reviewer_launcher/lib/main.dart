import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

void main() => runApp(const ReviewerLauncher());

class ReviewerLauncher extends StatelessWidget {
  const ReviewerLauncher({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'AI PR Reviewer',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff155eef)),
      useMaterial3: true,
    ),
    home: const ReviewHome(),
  );
}

class ReviewHome extends StatefulWidget {
  const ReviewHome({super.key});

  @override
  State<ReviewHome> createState() => _ReviewHomeState();
}

class _ReviewHomeState extends State<ReviewHome> {
  final _url = TextEditingController(
    text:
        'https://github.com/DileepJexpert/katasticho/compare/codex/contact-roles-field-sales-planning?expand=1',
  );
  final _repo = TextEditingController(text: r'C:\work\katasticho');
  final _target = TextEditingController(text: 'main');
  final _agent = TextEditingController(text: 'idfc-coder');
  final _output = TextEditingController(
    text: r'C:\Users\dileepkm\AI-PR-Reviews',
  );
  final _log = StringBuffer();
  bool _running = false;
  int? _exitCode;

  @override
  void dispose() {
    for (final controller in [_url, _repo, _target, _agent, _output]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _runReview() async {
    if (_url.text.trim().isEmpty || _repo.text.trim().isEmpty) {
      _append(
        'Enter both the GitHub compare URL and the local repository folder.',
      );
      return;
    }
    final script = File('../start-review.ps1').absolute.path;
    if (!File(script).existsSync()) {
      _append(
        'Cannot find start-review.ps1 at $script. Run this app from reviewer_launcher.',
      );
      return;
    }
    setState(() {
      _running = true;
      _exitCode = null;
      _log.clear();
      _append('Starting secure PR review...');
    });
    try {
      final process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        '-Repository',
        _repo.text.trim(),
        '-PrUrl',
        _url.text.trim(),
        '-Target',
        _target.text.trim(),
        '-CoderCommand',
        _agent.text.trim(),
        '-OutputRoot',
        _output.text.trim(),
        '-OpenReport',
      ]);
      unawaited(
        process.stdout
            .transform(systemEncoding.decoder)
            .listen(_append)
            .asFuture(),
      );
      unawaited(
        process.stderr
            .transform(systemEncoding.decoder)
            .listen(_append)
            .asFuture(),
      );
      final code = await process.exitCode;
      if (mounted) setState(() => _exitCode = code);
      _append(
        code == 0
            ? 'Review complete. Your HTML report was opened.'
            : 'Review stopped (exit code $code). Read the log above.',
      );
    } catch (error) {
      _append('Could not start PowerShell: $error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _append(String message) {
    if (!mounted) return;
    setState(() => _log.writeln(message.trimRight()));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              Text(
                'AI PR Reviewer',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Paste a GitHub compare URL. The launcher fetches the branch, creates a secure worktree, runs your local AI reviewer, and opens one HTML report.',
              ),
              const SizedBox(height: 28),
              _field(
                'GitHub compare URL',
                _url,
                hint: 'https://github.com/owner/repo/compare/branch',
              ),
              _field(
                'Local cloned repository',
                _repo,
                hint: r'C:\work\your-project',
              ),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      'Target branch if URL only has a source branch',
                      _target,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _field(
                      'Local AI executable',
                      _agent,
                      hint: 'idfc-coder',
                    ),
                  ),
                ],
              ),
              _field('Report output folder', _output),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _running ? null : _runReview,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(
                  _running ? 'Review running…' : 'Review PR and open report',
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Live review log',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Container(
                height: 260,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xff101828),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _log.isEmpty ? 'Ready.' : _log.toString(),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      color: Color(0xffd0d5dd),
                    ),
                  ),
                ),
              ),
              if (_exitCode != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _exitCode == 0
                        ? 'Success'
                        : 'Review failed — check the AI executable name and log.',
                    style: TextStyle(
                      color: _exitCode == 0 ? Colors.green : Colors.red,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
