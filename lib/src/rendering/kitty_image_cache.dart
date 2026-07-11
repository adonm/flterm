import 'dart:typed_data';
import 'dart:ui';

import 'package:libghostty/libghostty.dart';
import 'package:meta/meta.dart';

/// Async decoder cache that maps Kitty image ids to drawable [Image]s.
///
/// PNG payloads are already decoded to RGBA by libghostty via the
/// decoder installed with [LibGhostty.setPngDecoder], so only RGB and
/// RGBA formats reach this cache; anything else is stored as
/// [KittyImageUnsupported] so subsequent paints do not retry.
///
/// Re-transmissions under the same id are detected by libghostty's monotonic
/// image generation, including byte-level overwrites with unchanged dimensions.
class KittyImageCache {
  final VoidCallback _onImageReady;
  final Map<int, KittyImageCacheEntry> _entries = {};
  final Map<int, ({int generation, int width, int height})> _fingerprints = {};

  /// [onImageReady] fires when a pending decode completes; typically
  /// wired to a render box's `markNeedsPaint`.
  KittyImageCache({required this._onImageReady});

  /// Releases every cached entry. Call before discarding the cache.
  void dispose() {
    for (final entry in _entries.values) {
      if (entry is KittyImageReady) entry.image.dispose();
    }
    _entries.clear();
    _fingerprints.clear();
  }

  /// Releases any cached entries whose id is not in [live].
  void evict(Set<int> live) {
    _entries.removeWhere((id, entry) {
      if (live.contains(id)) return false;
      if (entry is KittyImageReady) entry.image.dispose();
      _fingerprints.remove(id);
      return true;
    });
  }

  /// Returns the entry for [image], starting a decode on first lookup
  /// or when its content generation has changed. Never blocks.
  KittyImageCacheEntry lookup(KittyImage image) {
    return _lookup(
      imageId: image.id,
      generation: image.generation,
      width: image.width,
      height: image.height,
      rgba: () => _ensureRgba(image),
    );
  }

  @visibleForTesting
  KittyImageCacheEntry lookupRgba({
    required int imageId,
    required int generation,
    required int width,
    required int height,
    required Uint8List rgba,
  }) => _lookup(
    imageId: imageId,
    generation: generation,
    width: width,
    height: height,
    rgba: () => rgba,
  );

  KittyImageCacheEntry _lookup({
    required int imageId,
    required int generation,
    required int width,
    required int height,
    required Uint8List? Function() rgba,
  }) {
    final fingerprint = (generation: generation, width: width, height: height);
    final existing = _entries[imageId];
    if (existing != null && _fingerprints[imageId] == fingerprint) {
      return existing;
    }
    if (existing is KittyImageReady) existing.image.dispose();
    _entries[imageId] = KittyImagePending();
    _fingerprints[imageId] = fingerprint;
    _beginDecode(imageId: imageId, width: width, height: height, rgba: rgba());
    return _entries[imageId]!;
  }

  /// Returns the cached entry for [imageId], or null if none. Unlike
  /// [lookup], does not start a decode so it is safe to call from paint.
  KittyImageCacheEntry? lookupById(int imageId) => _entries[imageId];

  /// Inserts a pre-decoded [image] under [imageId].
  @visibleForTesting
  void putReady(int imageId, Image image, {int generation = 0}) {
    final existing = _entries[imageId];
    if (existing is KittyImageReady) existing.image.dispose();
    _entries[imageId] = KittyImageReady(image);
    _fingerprints[imageId] = (
      generation: generation,
      width: image.width,
      height: image.height,
    );
  }

  void _beginDecode({
    required int imageId,
    required int width,
    required int height,
    required Uint8List? rgba,
  }) {
    final fingerprint = _fingerprints[imageId];
    if (rgba == null) {
      _entries[imageId] = KittyImageUnsupported();
      return;
    }
    decodeImageFromPixels(rgba, width, height, PixelFormat.rgba8888, (decoded) {
      if (_fingerprints[imageId] != fingerprint ||
          _entries[imageId] is! KittyImagePending) {
        decoded.dispose();
        return;
      }
      _entries[imageId] = KittyImageReady(decoded);
      _onImageReady();
    });
  }

  Uint8List? _ensureRgba(KittyImage image) {
    if (image.compression != .none) return null;
    switch (image.format) {
      case KittyImageFormat.rgba:
        return image.pixelData;
      case KittyImageFormat.rgb:
        final src = image.pixelData;
        final pixelCount = image.width * image.height;
        if (src.length < pixelCount * 3) return null;
        final out = Uint8List(pixelCount * 4);
        for (var i = 0; i < pixelCount; i++) {
          out[i * 4 + 0] = src[i * 3 + 0];
          out[i * 4 + 1] = src[i * 3 + 1];
          out[i * 4 + 2] = src[i * 3 + 2];
          out[i * 4 + 3] = 0xff;
        }
        return out;
      case KittyImageFormat.png:
      case KittyImageFormat.grayAlpha:
      case KittyImageFormat.gray:
        return null;
    }
  }
}

/// Result of a cache lookup for a decoded image.
sealed class KittyImageCacheEntry {}

/// A decode is in flight. A later repaint will see a [KittyImageReady].
final class KittyImagePending extends KittyImageCacheEntry {}

/// The image is decoded and ready to draw.
final class KittyImageReady extends KittyImageCacheEntry {
  final Image image;

  KittyImageReady(this.image);
}

/// The image was rejected due to an unsupported format or compression.
final class KittyImageUnsupported extends KittyImageCacheEntry {}
