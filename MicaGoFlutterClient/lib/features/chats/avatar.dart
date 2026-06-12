import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../contacts/contacts_service.dart';

/// A deterministic, colored contact avatar: a group icon for groups, otherwise
/// initials derived from the title on a stable per-contact color.
///
/// When [photo] bytes are supplied (a local contact thumbnail), the photo is
/// shown instead. Photos are loaded lazily/by-id (see [HandleAvatar]) —
/// `flutter_contacts` can't bulk-fetch thumbnails cheaply, so we never bulk
/// load; the initials remain the performant fallback.
class ContactAvatar extends StatelessWidget {
  final String title;
  final bool isGroup;
  final double radius;
  final Uint8List? photo;

  const ContactAvatar({
    super.key,
    required this.title,
    this.isGroup = false,
    this.radius = 20,
    this.photo,
  });

  @override
  Widget build(BuildContext context) {
    final base = _colorFor(title);
    final bg = base.withValues(alpha: 0.22);
    final fg = HSLColor.fromColor(base).withLightness(0.35).toColor();
    if (photo != null && photo!.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(photo!));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundColor: fg,
      child: isGroup
          ? Icon(Icons.group, size: radius)
          : Text(
              _initials(title),
              style: TextStyle(
                fontSize: radius * 0.7,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }

  static String _initials(String title) {
    final source = title.trim();
    if (source.isEmpty) return '#';
    if (RegExp(r'^[+\d][\d\s()\-]*$').hasMatch(source)) return '#';
    final words = source
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '#';
    String first(String w) =>
        w.isEmpty ? '' : String.fromCharCode(w.runes.first).toUpperCase();
    if (words.length == 1) return first(words.first);
    return first(words[0]) + first(words[1]);
  }

  /// Stable color from the title, chosen from a small Material palette.
  static Color _colorFor(String s) {
    const palette = [
      Color(0xFF3949AB), // indigo
      Color(0xFF00897B), // teal
      Color(0xFF6D4C41), // brown
      Color(0xFFD81B60), // pink
      Color(0xFF1E88E5), // blue
      Color(0xFF43A047), // green
      Color(0xFFF4511E), // deep orange
      Color(0xFF8E24AA), // purple
    ];
    var hash = 0;
    for (final c in s.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}

/// A [ContactAvatar] that lazily loads the matched contact's local thumbnail
/// for [handle] (cached in memory by [ContactsService]). Falls back to initials
/// while loading or when there is no photo / no match. For 1:1 chats only;
/// groups always show the group glyph.
class HandleAvatar extends StatelessWidget {
  final String title;
  final String? handle;
  final bool isGroup;
  final double radius;

  const HandleAvatar({
    super.key,
    required this.title,
    required this.handle,
    this.isGroup = false,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = ContactAvatar(
      title: title,
      isGroup: isGroup,
      radius: radius,
    );
    if (isGroup || handle == null || handle!.isEmpty) return fallback;
    final contacts = context.watch<ContactsService>();
    if (!contacts.isReady) return fallback;
    return FutureBuilder<Uint8List?>(
      future: contacts.thumbnailForHandle(handle),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return fallback;
        return ContactAvatar(
          title: title,
          isGroup: isGroup,
          radius: radius,
          photo: bytes,
        );
      },
    );
  }
}
