import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/core/widgets/retained_tab_stack.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

const _videoUrl = String.fromEnvironment('VIDEO_PREVIEW_URL');

void main() {
  runApp(const ProviderScope(child: _PlaybackVerificationApp()));
}

class _PlaybackVerificationApp extends StatefulWidget {
  const _PlaybackVerificationApp();

  @override
  State<_PlaybackVerificationApp> createState() =>
      _PlaybackVerificationAppState();
}

class _PlaybackVerificationAppState extends State<_PlaybackVerificationApp> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TYDES playback verification',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      scaffoldBackgroundColor: const Color(0xFFFFF8D9),
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('TYDES playback verification')),
      body: RetainedTabStack(
        index: _tab,
        children: const [
          _VerificationFeed(),
          Center(child: Text('Profile — the hidden feed must stay silent.')),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.view_list), label: 'Feed'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    ),
  );
}

class _VerificationFeed extends StatelessWidget {
  const _VerificationFeed();

  @override
  Widget build(BuildContext context) {
    if (_videoUrl.isEmpty) {
      return const Center(child: Text('VIDEO_PREVIEW_URL is required.'));
    }
    return ListView(
      cacheExtent: 1800,
      padding: const EdgeInsets.all(16),
      children: const [
        Text('Test-only layout. Scroll between clips, then switch tabs.'),
        SizedBox(height: 16),
        _VerificationClip(label: 'Clip A'),
        SizedBox(height: 650),
        _VerificationClip(label: 'Clip B'),
        SizedBox(height: 650),
      ],
    );
  }
}

class _VerificationClip extends StatelessWidget {
  const _VerificationClip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      SizedBox(
        height: 240,
        child: PageView(
          children: const [AutoplayVideoPlayer(url: _videoUrl, expand: true)],
        ),
      ),
    ],
  );
}
