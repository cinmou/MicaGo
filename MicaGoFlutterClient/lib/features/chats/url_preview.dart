import 'dart:async';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

final RegExp urlPreviewRegex = RegExp(
  r'(?:(?:https?:\/\/)|(?:www\.))[^\s<>()]+',
  caseSensitive: false,
);

String? firstUrlInText(String text) {
  final urls = urlsInText(text);
  return urls.isEmpty ? null : urls.first;
}

List<String> urlsInText(String text) {
  return [
    for (final match in urlPreviewRegex.allMatches(text))
      normalizePreviewUrl(text.substring(match.start, match.end)),
  ];
}

String normalizePreviewUrl(String raw) {
  final trimmed = raw.trim().replaceAll(RegExp(r'[.,!?;:]+$'), '');
  if (trimmed.startsWith(RegExp(r'https?:\/\/', caseSensitive: false))) {
    return trimmed;
  }
  return 'https://$trimmed';
}

class UrlPreviewCard extends StatefulWidget {
  final String url;
  final bool compact;

  const UrlPreviewCard({super.key, required this.url, this.compact = false});

  @override
  State<UrlPreviewCard> createState() => _UrlPreviewCardState();
}

class _UrlPreviewCardState extends State<UrlPreviewCard>
    with AutomaticKeepAliveClientMixin {
  late Future<_PreviewMetadata> _future;

  @override
  void initState() {
    super.initState();
    _future = _PreviewMetadata.fetch(widget.url);
  }

  @override
  void didUpdateWidget(covariant UrlPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = _PreviewMetadata.fetch(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return const SizedBox.shrink();

    return FutureBuilder<_PreviewMetadata>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data ?? _PreviewMetadata(url: widget.url);
        if (snap.connectionState == ConnectionState.done &&
            !data.hasDisplayContent) {
          return const SizedBox.shrink();
        }
        final maxWidth = widget.compact ? 260.0 : 320.0;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (data.imageUrl != null)
                  _PreviewImage(
                    url: data.imageUrl!,
                    maxWidth: maxWidth,
                    compact: widget.compact,
                  ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (snap.connectionState != ConnectionState.done &&
                          !data.hasDisplayContent)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else ...[
                        Text(
                          data.title ?? data.host,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if ((data.description ?? '').isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            data.description!,
                            maxLines: widget.compact ? 1 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 5),
                        Text(
                          data.siteName ?? data.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _PreviewImage extends StatefulWidget {
  final String url;
  final double maxWidth;
  final bool compact;

  const _PreviewImage({
    required this.url,
    required this.maxWidth,
    required this.compact,
  });

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  static final Map<String, Future<Size?>> _sizeCache = {};
  late Future<Size?> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = _sizeCache.putIfAbsent(
      widget.url,
      () => _resolveImageSize(widget.url),
    );
  }

  @override
  void didUpdateWidget(covariant _PreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _sizeFuture = _sizeCache.putIfAbsent(
        widget.url,
        () => _resolveImageSize(widget.url),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size?>(
      future: _sizeFuture,
      builder: (context, snap) {
        final size = snap.data;
        final aspect = size == null || size.height <= 0
            ? 16 / 9
            : (size.width / size.height).clamp(0.45, 2.4);
        final minWidth = widget.compact ? 170.0 : 210.0;
        final width = aspect >= 1
            ? widget.maxWidth
            : (widget.maxWidth * aspect).clamp(minWidth, widget.maxWidth);
        final maxHeight = widget.compact ? 220.0 : 300.0;
        final height = (width / aspect).clamp(90.0, maxHeight);

        return SizedBox(
          width: width,
          height: height,
          child: Image.network(
            widget.url,
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        );
      },
    );
  }

  static Future<Size?> _resolveImageSize(String url) {
    final completer = Completer<Size?>();
    final image = NetworkImage(url);
    late final ImageStreamListener listener;
    final stream = image.resolve(const ImageConfiguration());
    listener = ImageStreamListener(
      (info, _) {
        final image = info.image;
        completer.complete(
          Size(image.width.toDouble(), image.height.toDouble()),
        );
        stream.removeListener(listener);
      },
      onError: (_, _) {
        completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        stream.removeListener(listener);
        return null;
      },
    );
  }
}

class _PreviewMetadata {
  static final Map<String, _PreviewMetadata> _cache = {};

  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  _PreviewMetadata({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  String get host => Uri.tryParse(url)?.host.replaceFirst('www.', '') ?? url;

  bool get hasDisplayContent =>
      (title ?? '').isNotEmpty ||
      (description ?? '').isNotEmpty ||
      (imageUrl ?? '').isNotEmpty ||
      (siteName ?? '').isNotEmpty;

  static Future<_PreviewMetadata> fetch(String rawUrl) async {
    final url = normalizePreviewUrl(rawUrl);
    final cached = _cache[url];
    if (cached != null) return cached;

    final uri = Uri.parse(url);
    final response = await http.get(uri).timeout(const Duration(seconds: 6));
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.startsWith('image/')) {
      final metadata = _PreviewMetadata(url: url, imageUrl: url);
      _cache[url] = metadata;
      return metadata;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final metadata = _PreviewMetadata(url: url);
      _cache[url] = metadata;
      return metadata;
    }

    final document = html_parser.parse(response.body);
    String? meta(String key) => document
        .querySelector('meta[property="$key"]')
        ?.attributes['content']
        ?.trim();
    String? namedMeta(String key) => document
        .querySelector('meta[name="$key"]')
        ?.attributes['content']
        ?.trim();

    final image = _resolveUrl(
      url,
      meta('og:image') ?? namedMeta('twitter:image'),
    );
    final metadata = _PreviewMetadata(
      url: url,
      title:
          meta('og:title') ??
          namedMeta('twitter:title') ??
          document.querySelector('title')?.text.trim(),
      description:
          meta('og:description') ??
          namedMeta('description') ??
          namedMeta('twitter:description'),
      siteName: meta('og:site_name'),
      imageUrl: image,
    );
    _cache[url] = metadata;
    return metadata;
  }

  static String? _resolveUrl(String base, String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.hasScheme) return raw;
    return Uri.parse(base).resolveUri(uri).toString();
  }
}
