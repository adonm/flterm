import 'dart:typed_data';
import 'dart:ui';

import 'package:libghostty/libghostty.dart';
import 'package:meta/meta.dart';

typedef KittyImageDecoder =
    void Function(
      Uint8List rgba,
      int width,
      int height,
      void Function(Image image) onDecoded,
    );

void _decodeKittyImage(
  Uint8List rgba,
  int width,
  int height,
  void Function(Image image) onDecoded,
) =>
    decodeImageFromPixels(rgba, width, height, PixelFormat.rgba8888, onDecoded);

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
  final KittyImageDecoder _decoder;
  final Map<int, KittyImageCacheEntry> _entries = {};
  final Map<int, ({int generation, int width, int height})> _fingerprints = {};
  final Map<int, _KittyDecodeRequest> _activeDecodes = {};
  final Map<int, _KittyDecodeRequest> _queuedDecodes = {};

  /// [onImageReady] fires when a pending decode completes; typically
  /// wired to a render box's `markNeedsPaint`.
  KittyImageCache({
    required VoidCallback onImageReady,
    @visibleForTesting KittyImageDecoder decoder = _decodeKittyImage,
  }) : this._(onImageReady, decoder);

  KittyImageCache._(this._onImageReady, this._decoder);

  /// Releases every cached entry. Call before discarding the cache.
  void dispose() {
    for (final entry in _entries.values) {
      if (entry is KittyImageReady) entry.image.dispose();
    }
    _entries.clear();
    _fingerprints.clear();
    _activeDecodes.clear();
    _queuedDecodes.clear();
  }

  /// Releases any cached entries whose id is not in [live].
  void evict(Set<int> live) {
    _entries.removeWhere((id, entry) {
      if (live.contains(id)) return false;
      if (entry is KittyImageReady) entry.image.dispose();
      _fingerprints.remove(id);
      _activeDecodes.remove(id);
      _queuedDecodes.remove(id);
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
    final previousFingerprint = _fingerprints[imageId];
    if (existing != null && previousFingerprint == fingerprint) {
      return existing;
    }

    // Reused image ids are common for video-like Kitty graphics. Keep the
    // previous texture drawable while Flutter uploads a same-size replacement;
    // unrelated repaints (cursor blink, hover, selection) must not expose a
    // blank frame during that asynchronous gap.
    final retainExisting =
        existing is KittyImageReady &&
        previousFingerprint?.width == width &&
        previousFingerprint?.height == height;
    if (!retainExisting) {
      if (existing is KittyImageReady) existing.image.dispose();
      _entries[imageId] = KittyImagePending();
    }
    _fingerprints[imageId] = fingerprint;
    _beginDecode(imageId: imageId, fingerprint: fingerprint, rgba: rgba());
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
    _activeDecodes.remove(imageId);
    _queuedDecodes.remove(imageId);
  }

  void _beginDecode({
    required int imageId,
    required ({int generation, int width, int height}) fingerprint,
    required Uint8List? rgba,
  }) {
    if (rgba == null) {
      final existing = _entries[imageId];
      if (existing is KittyImageReady) existing.image.dispose();
      _entries[imageId] = KittyImageUnsupported();
      _activeDecodes.remove(imageId);
      _queuedDecodes.remove(imageId);
      return;
    }
    final request = _KittyDecodeRequest(
      imageId: imageId,
      fingerprint: fingerprint,
      rgba: rgba,
    );
    if (_activeDecodes.containsKey(imageId)) {
      // Upload pressure should not grow with the producer frame rate. Keep only
      // the newest complete frame waiting behind the active GPU upload.
      _queuedDecodes[imageId] = request;
      return;
    }
    _startDecode(request);
  }

  void _startDecode(_KittyDecodeRequest request) {
    _activeDecodes[request.imageId] = request;
    _decoder(
      request.rgba,
      request.fingerprint.width,
      request.fingerprint.height,
      (decoded) => _finishDecode(request, decoded),
    );
  }

  void _finishDecode(_KittyDecodeRequest request, Image decoded) {
    final imageId = request.imageId;
    if (!identical(_activeDecodes[imageId], request)) {
      decoded.dispose();
      return;
    }
    _activeDecodes.remove(imageId);

    final queued = _queuedDecodes.remove(imageId);
    final desired = _fingerprints[imageId];
    final isLatest = desired == request.fingerprint;
    final isUsefulIntermediate =
        queued != null &&
        desired == queued.fingerprint &&
        queued.fingerprint.width == request.fingerprint.width &&
        queued.fingerprint.height == request.fingerprint.height;

    var published = false;
    if (isLatest || isUsefulIntermediate) {
      final existing = _entries[imageId];
      _entries[imageId] = KittyImageReady(decoded);
      if (existing is KittyImageReady) existing.image.dispose();
      published = true;
    } else {
      decoded.dispose();
    }

    if (queued != null &&
        _fingerprints[imageId] == queued.fingerprint &&
        _entries.containsKey(imageId)) {
      _startDecode(queued);
    }
    if (published) _onImageReady();
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

final class _KittyDecodeRequest {
  final int imageId;
  final ({int generation, int width, int height}) fingerprint;
  final Uint8List rgba;

  const _KittyDecodeRequest({
    required this.imageId,
    required this.fingerprint,
    required this.rgba,
  });
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
