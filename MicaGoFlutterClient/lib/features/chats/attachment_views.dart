import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/network/api_client.dart';
import 'models/message_model.dart';

/// Renders a single attachment in a message bubble, choosing the right view by
/// kind. Display-only — the server has no media-send endpoint (C2 gap).
class AttachmentView extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;

  const AttachmentView({super.key, required this.api, required this.attachment});

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage) {
      return _ImageAttachment(api: api, attachment: attachment);
    }
    if (attachment.isAudio) {
      return _AudioAttachment(api: api, attachment: attachment);
    }
    return _FileAttachment(attachment: attachment);
  }
}

/// Simple in-memory cache so re-scrolling doesn't refetch the same image bytes.
final Map<String, Uint8List> _imageCache = {};

class _ImageAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _ImageAttachment({required this.api, required this.attachment});

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
    final cached = _imageCache[widget.attachment.guid];
    if (cached != null) return cached;
    final bytes = await widget.api.getAttachmentBytes(widget.attachment.guid);
    _imageCache[widget.attachment.guid] = bytes;
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _FullScreenImage(bytes: bytes),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  _FileAttachment(attachment: widget.attachment),
            ),
          ),
        );
      },
    );
  }
}

class _FullScreenImage extends StatelessWidget {
  final Uint8List bytes;
  const _FullScreenImage({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.memory(bytes),
        ),
      ),
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
                icon: Icon(_failed
                    ? Icons.error_outline
                    : playing
                        ? Icons.pause_circle
                        : Icons.play_circle),
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
                Text(attachment.displayName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (attachment.totalBytes > 0)
                  Text(_humanSize(attachment.totalBytes),
                      style: Theme.of(context).textTheme.bodySmall),
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

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
