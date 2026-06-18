import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

/// One attachment staged for sending (selected but not yet sent). [sourceId] is
/// the gallery asset id when picked from the media grid, so the grid can show a
/// selected check and toggle it off; null for camera/file picks.
class StagedAttachment {
  final Uint8List bytes;
  final String filename;
  final String? sourceId;
  const StagedAttachment({
    required this.bytes,
    required this.filename,
    this.sourceId,
  });

  bool get isImage {
    final n = filename.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.heic') ||
        n.endsWith('.webp');
  }
}

/// BlueBubbles-style attachment panel (adapted from
/// `text_field_attachment_picker.dart`): the **+** opens this in-composer panel
/// showing a horizontal grid of **recent gallery media** (via photo_manager)
/// preceded by Camera / Files action tiles. Tapping a thumbnail toggles
/// it into the staged selection (check overlay), matching BB's multi-select.
/// Permission states (granted / limited / denied / permanently denied) are
/// handled; the generic file picker is always available as a fallback.
class AttachmentPanel extends StatefulWidget {
  /// Currently-staged asset ids (to render check overlays).
  final Set<String> selectedAssetIds;

  /// Toggle a gallery asset in/out of the staged selection.
  final Future<void> Function(AssetEntity asset) onToggleAsset;

  /// Files / camera picks (already-loaded bytes).
  final void Function(List<StagedAttachment>) onPicked;

  /// Surface a permission/error message to the user.
  final void Function(String message) onError;

  const AttachmentPanel({
    super.key,
    required this.selectedAssetIds,
    required this.onToggleAsset,
    required this.onPicked,
    required this.onError,
  });

  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  List<AssetEntity> _recent = const [];
  PermissionState? _permission;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    // Like BB: request extended permission (covers iOS limited library) and
    // load the most recent gallery items for the grid.
    final ps = await PhotoManager.requestPermissionExtend();
    _permission = ps;
    if (!ps.hasAccess) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common, // images + videos
        filterOption: FilterOptionGroup(
          orders: const [
            OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (albums.isNotEmpty) {
        _recent = await albums.first.getAssetListRange(start: 0, end: 30);
      }
    } catch (e) {
      widget.onError('Could not load recent media: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickCamera() async {
    try {
      final XFile? file = await ImagePicker().pickImage(
        source: ImageSource.camera,
      );
      if (file == null) return;
      widget.onPicked([
        StagedAttachment(bytes: await file.readAsBytes(), filename: file.name),
      ]);
    } catch (e) {
      widget.onError('Camera unavailable or permission denied: $e');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      final picked = <StagedAttachment>[];
      for (final f in result?.files ?? const <PlatformFile>[]) {
        final bytes = f.bytes;
        if (bytes != null) {
          picked.add(StagedAttachment(bytes: bytes, filename: f.name));
        }
      }
      if (picked.isNotEmpty) widget.onPicked(picked);
    } catch (e) {
      widget.onError('Could not open Files: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.all(8),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              scrollDirection: Axis.horizontal,
              slivers: [
                // Leading action tiles (always available).
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  delegate: SliverChildListDelegate([
                    // C21: Camera + Files only. The standalone "Video" tile was
                    // removed — recent videos are pickable straight from the
                    // grid below (they carry a play badge and send like any
                    // other attachment).
                    _ActionTile(
                      icon: Icons.photo_camera_outlined,
                      label: 'Camera',
                      onTap: _pickCamera,
                    ),
                    _ActionTile(
                      icon: Icons.folder_open_outlined,
                      label: 'Files',
                      onTap: _pickFiles,
                    ),
                    if (_permission == PermissionState.limited)
                      _ActionTile(
                        icon: Icons.add_photo_alternate_outlined,
                        label: 'More photos',
                        onTap: () => PhotoManager.presentLimited(),
                      ),
                  ]),
                ),
                const SliverPadding(padding: EdgeInsets.only(left: 8)),
                // Recent gallery media grid (the BlueBubbles hallmark).
                if (_permission?.hasAccess ?? false)
                  SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _MediaTile(
                        asset: _recent[i],
                        selected: widget.selectedAssetIds.contains(
                          _recent[i].id,
                        ),
                        onTap: () => widget.onToggleAsset(_recent[i]),
                      ),
                      childCount: _recent.length,
                    ),
                  )
                else
                  SliverToBoxAdapter(
                    child: _PermissionPrompt(state: _permission),
                  ),
              ],
            ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaTile extends StatefulWidget {
  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;
  const _MediaTile({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(200)).then((
      data,
    ) {
      if (mounted) setState(() => _thumb = data);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _thumb != null
                  ? Image.memory(_thumb!, fit: BoxFit.cover)
                  : Container(color: scheme.surface),
            ),
            // Video badge.
            if (widget.asset.type == AssetType.video && !widget.selected)
              const Positioned(
                right: 4,
                bottom: 4,
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            // Selected check overlay (BB-style).
            if (widget.selected)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: scheme.primary.withValues(alpha: 0.35),
                ),
                alignment: Alignment.topRight,
                padding: const EdgeInsets.all(4),
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.primary,
                  child: Icon(Icons.check, size: 14, color: scheme.onPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PermissionPrompt extends StatelessWidget {
  final PermissionState? state;
  const _PermissionPrompt({required this.state});

  @override
  Widget build(BuildContext context) {
    final denied =
        state == PermissionState.denied || state == PermissionState.restricted;
    return SizedBox(
      width: 220,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library_outlined, size: 28),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                denied
                    ? 'Photo access is off. Use Files, or enable photo access in Settings.'
                    : 'Grant photo access to pick from your gallery.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => PhotoManager.openSetting(),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal preview strip of staged attachments with per-item remove.
class StagedAttachmentStrip extends StatelessWidget {
  final List<StagedAttachment> items;
  final void Function(int index) onRemove;
  const StagedAttachmentStrip({
    super.key,
    required this.items,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final item = items[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: item.isImage
                    ? Image.memory(
                        item.bytes,
                        width: 60,
                        height: 60,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 60,
                        height: 60,
                        color: scheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const Icon(Icons.insert_drive_file_outlined),
                      ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.cancel),
                  color: scheme.onSurfaceVariant,
                  onPressed: () => onRemove(i),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
