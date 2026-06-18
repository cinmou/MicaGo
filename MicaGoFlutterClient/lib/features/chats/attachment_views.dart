import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/network/api_client.dart';
import 'media_viewer.dart';
import 'models/message_model.dart';

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
    return _FileAttachment(attachment: attachment);
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
