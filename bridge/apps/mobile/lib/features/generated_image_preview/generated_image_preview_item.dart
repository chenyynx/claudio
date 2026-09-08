import 'dart:typed_data';

/// One generated image and the generation metadata shown in its preview.
class GeneratedImagePreviewItem {
  final String id;
  final String? url;
  final String? thumbnailUrl;
  final Uint8List? bytes;
  final String? cacheKey;
  final String mimeType;
  final String prompt;
  final String? status;
  final String? savedPath;
  final String? details;

  const GeneratedImagePreviewItem({
    required this.id,
    this.url,
    this.thumbnailUrl,
    this.bytes,
    this.cacheKey,
    required this.mimeType,
    required this.prompt,
    this.status,
    this.savedPath,
    this.details,
  }) : assert(bytes != null || (url != null && url != ''));

  bool get hasDetails =>
      status?.isNotEmpty == true ||
      savedPath?.isNotEmpty == true ||
      details?.isNotEmpty == true;

  /// Uses Bridge's compact variant when advertised, otherwise the original.
  String? get chatImageUrl => thumbnailUrl ?? url;

  String? get thumbnailCacheKey {
    final value = cacheKey;
    if (value == null || thumbnailUrl == null) return value;
    return '$value-thumbnail-v1';
  }
}
