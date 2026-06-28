import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/network/api_client.dart';
import 'media_viewer.dart';
import 'models/message_model.dart';
import 'url_preview.dart';

/// Renders a single attachment in a message bubble, choosing the right view by
/// kind. Display-only — the server has no media-send endpoint (C2 gap).
///
/// [imageSiblings] are all image attachments in the same message; tapping an
/// image opens the full-screen gallery at this image's [imageIndex] so the user
/// can swipe between them.
class AttachmentView extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final List<AttachmentModel> imageSiblings;
  final int imageIndex;

  const AttachmentView({
    super.key,
    required this.api,
    required this.attachment,
    this.imageSiblings = const [],
    this.imageIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (attachment.isOpaquePreviewPayload) {
      return const SizedBox.shrink();
    }
    // C32: stickers (incl. third-party iMessage sticker packs) are handled first
    // and always as a sticker — we try to render the image and, if that fails,
    // show a clean "Sticker" placeholder rather than a broken file/“TIFF” card.
    if (attachment.isStickerLike) {
      return _StickerAttachment(api: api, attachment: attachment);
    }
    if (attachment.canRenderInlineImage) {
      return _ImageAttachment(
        api: api,
        attachment: attachment,
        siblings: imageSiblings.isEmpty ? [attachment] : imageSiblings,
        index: imageIndex,
      );
    }
    if (attachment.isImage && attachment.needsPreviewConversion) {
      return _PreviewUnavailableAttachment(attachment: attachment);
    }
    if (attachment.isAudio) {
      return _AudioAttachment(api: api, attachment: attachment);
    }
    if (attachment.isVideo) {
      return _VideoAttachment(api: api, attachment: attachment);
    }
    if (attachment.isLocation) {
      return _LocationAttachment(api: api, attachment: attachment);
    }
    if (attachment.isLinkPreview) {
      return _LinkAttachment(attachment: attachment);
    }
    return _FileAttachment(attachment: attachment);
  }
}

class _LinkAttachment extends StatelessWidget {
  final AttachmentModel attachment;
  const _LinkAttachment({required this.attachment});

  @override
  Widget build(BuildContext context) {
    return UrlPreviewCard(url: attachment.displayName, compact: true);
  }
}

/// C37: an iMessage shared-location attachment. Apple stores it as a small
/// vlocation text payload carrying an Apple Maps URL; we fetch it, extract the
/// URL, and offer "Open in Maps". A clean card — never a raw/broken file card.
class _LocationAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _LocationAttachment({required this.api, required this.attachment});

  @override
  State<_LocationAttachment> createState() => _LocationAttachmentState();
}

class _LocationAttachmentState extends State<_LocationAttachment> {
  late final Future<Uri?> _future = _loadMapUrl();

  Future<Uri?> _loadMapUrl() async {
    try {
      final bytes = await widget.api.getAttachmentBytes(widget.attachment.guid);
      final text = utf8.decode(bytes, allowMalformed: true);
      // The vlocation body contains an Apple Maps URL (and/or a geo: URI).
      final match = RegExp(
        r'(?:https?:\/\/[^\s<>"]*maps[^\s<>"]+|geo:[-0-9.,?&=]+)',
        caseSensitive: false,
      ).firstMatch(text);
      if (match != null) {
        return Uri.tryParse(match.group(0)!.replaceAll(r'\', ''));
      }
    } catch (_) {
      // Fall through to a no-link card.
    }
    return null;
  }

  Future<void> _open(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* best-effort */
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Uri?>(
      future: _future,
      builder: (context, snap) {
        final url = snap.data;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: url == null ? null : () => _open(url),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          MicaLocalizations.of(context).t('chat.location'),
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        Text(
                          url == null
                              ? MicaLocalizations.of(context).t('chat.location')
                              : MicaLocalizations.of(
                                  context,
                                ).t('chat.openInMaps'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (url != null)
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// C24: a video attachment card — tapping opens the full-screen player. We keep
/// it a card (not an inline autoplaying player) so the scrolling list stays
/// light; the player is only created on demand in the viewer.
class _VideoAttachment extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _VideoAttachment({required this.api, required this.attachment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () =>
          FullscreenVideo.open(context, api: api, attachment: attachment),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_fill, color: scheme.primary, size: 30),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    attachment.totalBytes > 0
                        ? 'Video · ${_formatSize(attachment.totalBytes)}'
                        : 'Video · tap to play',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// C32: renders an iMessage sticker. Stickers are images (PNG/HEIC/GIF), so we
/// try to load + show the bitmap with sticker styling (transparent, no card,
/// tap to fade like BlueBubbles, long-press to enlarge). If the bytes can't be
/// fetched or decoded — common for third-party sticker packs in formats the
/// server can't preview — we show a clean "Sticker" chip instead of a broken
/// file card.
class _StickerAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _StickerAttachment({required this.api, required this.attachment});

  @override
  State<_StickerAttachment> createState() => _StickerAttachmentState();
}

class _StickerAttachmentState extends State<_StickerAttachment> {
  late final Future<Uint8List> _future = _load();
  bool _visible = true;

  Future<Uint8List> _load() async {
    final cacheKey = widget.attachment.previewUrl ?? widget.attachment.guid;
    final cached = imageByteCache[cacheKey];
    if (cached != null) return cached;
    final bytes = await widget.api.getAttachmentPreviewBytes(widget.attachment);
    imageByteCache[cacheKey] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            width: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
          return const _StickerPlaceholder();
        }
        return GestureDetector(
          onTap: () => setState(() => _visible = !_visible),
          onLongPress: () => MediaGalleryViewer.open(
            context,
            api: widget.api,
            images: [widget.attachment],
          ),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _visible ? 1 : 0.25,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160, maxWidth: 160),
              child: Image.memory(
                snap.data!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                cacheWidth: 320,
                filterQuality: FilterQuality.none,
                errorBuilder: (_, _, _) => const _StickerPlaceholder(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Clean fallback for an un-renderable sticker — a small labelled chip, never a
/// broken/empty file card.
class _StickerPlaceholder extends StatelessWidget {
  const _StickerPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            MicaLocalizations.of(context).t('chat.sticker'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _PreviewUnavailableAttachment extends StatelessWidget {
  final AttachmentModel attachment;
  const _PreviewUnavailableAttachment({required this.attachment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('TIFF image'),
                Text(
                  'Preview not available yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (attachment.displayName != 'Attachment')
                  Text(
                    attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (attachment.totalBytes > 0)
                  Text(
                    _formatSize(attachment.totalBytes),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final List<AttachmentModel> siblings;
  final int index;
  const _ImageAttachment({
    required this.api,
    required this.attachment,
    required this.siblings,
    required this.index,
  });

  @override
  State<_ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<_ImageAttachment> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadBytes();
  }

  Future<Uint8List> _loadBytes() async {
    final cacheKey = widget.attachment.previewUrl ?? widget.attachment.guid;
    final cached = imageByteCache[cacheKey];
    if (cached != null) return cached;
    final bytes = await widget.api.getAttachmentPreviewBytes(widget.attachment);
    imageByteCache[cacheKey] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError || snap.data == null) {
          return _FileAttachment(attachment: widget.attachment);
        }
        final bytes = snap.data!;
        return GestureDetector(
          onTap: () => MediaGalleryViewer.open(
            context,
            api: widget.api,
            images: widget.siblings,
            initialIndex: widget.index,
          ),
          // Bounded inline thumbnail: cap height and downscale the decode
          // (cacheWidth) so a large photo never decodes at full resolution in
          // the scrolling list. Full-size loading happens in the media viewer.
          child: ConstrainedBox(
            constraints: widget.attachment.isSticker
                ? const BoxConstraints(maxHeight: 180, maxWidth: 180)
                : const BoxConstraints(maxHeight: 260, maxWidth: 280),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                widget.attachment.isSticker ? 4 : 12,
              ),
              child: Image.memory(
                bytes,
                fit: widget.attachment.isSticker
                    ? BoxFit.contain
                    : BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 560,
                errorBuilder: (_, _, _) =>
                    _FileAttachment(attachment: widget.attachment),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AudioAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _AudioAttachment({required this.api, required this.attachment});

  @override
  State<_AudioAttachment> createState() => _AudioAttachmentState();
}

class _AudioAttachmentState extends State<_AudioAttachment> {
  final AudioPlayer _player = AudioPlayer();
  bool _loaded = false;
  bool _failed = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (!_loaded) {
        await _player.setUrl(
          widget.api.attachmentUrl(widget.attachment.guid),
          headers: widget.api.mediaAuthHeaders, // token in header, not URL
        );
        _loaded = true;
      }
      if (_player.playing) {
        await _player.pause();
      } else {
        // Restart if finished.
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.attachment.isVoiceMessage
        ? 'Voice message'
        : widget.attachment.displayName;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: StreamBuilder<PlayerState>(
        stream: _player.playerStateStream,
        builder: (context, snap) {
          final playing = snap.data?.playing ?? false;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: _failed ? null : _toggle,
                icon: Icon(
                  _failed
                      ? Icons.error_outline
                      : playing
                      ? Icons.pause_circle
                      : Icons.play_circle,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  _failed ? 'Audio unavailable' : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FileAttachment extends StatelessWidget {
  final AttachmentModel attachment;
  const _FileAttachment({required this.attachment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconFor(attachment), color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (attachment.totalBytes > 0)
                  Text(
                    _humanSize(attachment.totalBytes),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(AttachmentModel a) {
    if (a.isVideo) return Icons.movie_outlined;
    if (a.isSticker) return Icons.emoji_emotions_outlined;
    final mime = a.mimeType ?? '';
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _humanSize(int bytes) => _formatSize(bytes);
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
