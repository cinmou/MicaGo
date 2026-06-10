import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import 'models/message_model.dart';

/// Full-screen media viewer (Part H): dim background, pinch-zoom, swipe between
/// multiple images, loading + error states. Bytes are fetched via the API
/// client (token travels in the Authorization header, never in a URL or log).
class MediaGalleryViewer extends StatefulWidget {
  final ApiClient api;
  final List<AttachmentModel> images;
  final int initialIndex;

  const MediaGalleryViewer({
    super.key,
    required this.api,
    required this.images,
    this.initialIndex = 0,
  });

  static Future<void> open(
    BuildContext context, {
    required ApiClient api,
    required List<AttachmentModel> images,
    int initialIndex = 0,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => MediaGalleryViewer(
          api: api,
          images: images,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  State<MediaGalleryViewer> createState() => _MediaGalleryViewerState();
}

class _MediaGalleryViewerState extends State<MediaGalleryViewer> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.images.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _page,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) =>
                _ZoomableImage(api: widget.api, attachment: widget.images[i]),
          ),
          // Top bar: close + counter, over a subtle gradient for legibility.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    if (multi)
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(
                          '${_index + 1} / ${widget.images.length}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomableImage extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _ZoomableImage({required this.api, required this.attachment});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  late Future<Uint8List> _future = _load();

  Future<Uint8List> _load() {
    final cacheKey = widget.attachment.previewUrl ?? widget.attachment.guid;
    final cached = imageByteCache[cacheKey];
    if (cached != null) return Future.value(cached);
    return widget.api.getAttachmentPreviewBytes(widget.attachment).then((b) {
      imageByteCache[cacheKey] = b;
      return b;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        if (snap.hasError || snap.data == null) {
          return _ErrorBody(
            name: widget.attachment.displayName,
            onRetry: () => setState(() => _future = _load()),
          );
        }
        return InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: Image.memory(
              snap.data!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _ErrorBody(
                name: widget.attachment.displayName,
                onRetry: () => setState(() => _future = _load()),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String name;
  final VoidCallback onRetry;
  const _ErrorBody({required this.name, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            color: Colors.white70,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            name,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// Shared in-memory cache for fetched image bytes (thread bubbles + viewer).
final Map<String, Uint8List> imageByteCache = {};
