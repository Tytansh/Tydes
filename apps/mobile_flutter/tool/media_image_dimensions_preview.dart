import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/core/widgets/media_image_dimensions.dart';

void main() => runApp(const _MetadataProbe());

/// Browser-only regression fixture. All images are generated inline, so this
/// never accesses account data, remote media, or a second provider request.
class _MetadataProbe extends StatefulWidget {
  const _MetadataProbe();

  @override
  State<_MetadataProbe> createState() => _MetadataProbeState();
}

class _MetadataProbeState extends State<_MetadataProbe> {
  late final Future<List<Size>> _checks = Future.wait([
    _htmlMetadata(80, 45),
    _htmlMetadata(45, 80),
    _htmlMetadata(500, 500),
  ]);

  Future<Size> _htmlMetadata(int width, int height) {
    final source = Uri.encodeComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height">'
      '<rect width="100%" height="100%" fill="#009da5"/></svg>',
    );
    final stream = NetworkImage(
      'data:image/svg+xml;charset=utf-8,$source',
      webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
    ).resolve(ImageConfiguration.empty);
    final done = Completer<Size>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        try {
          var isHtmlFallback = false;
          try {
            info.image;
          } on UnsupportedError {
            isHtmlFallback = true;
          }
          if (!isHtmlFallback) {
            throw StateError('This probe must exercise HTML-only ImageInfo.');
          }
          final size = mediaImageDimensions(info);
          if (size != Size(width.toDouble(), height.toDouble())) {
            throw StateError('Wrong dimensions: $size.');
          }
          done.complete(size);
        } catch (error, stack) {
          done.completeError(error, stack);
        } finally {
          info.dispose();
          stream.removeListener(listener);
        }
      },
      onError: (Object error, StackTrace? stack) {
        done.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return done.future;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('HTML photo metadata regression')),
      body: Center(
        child: FutureBuilder<List<Size>>(
          future: _checks,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text('FAIL: ${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Text('Checking generated HTML images…');
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('PASS: all three HTML-only photo sizes resolved'),
                for (final size in snapshot.data!)
                  Text('${size.width.toInt()} × ${size.height.toInt()}'),
              ],
            );
          },
        ),
      ),
    ),
  );
}
