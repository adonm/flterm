import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KittyImageCache', () {
    Future<ui.Image> testImage() {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0xff, 0xff, 0xff, 0xff]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    }

    test('dispose clears ready entries and is idempotent', () async {
      final cache = KittyImageCache(onImageReady: () {});
      addTearDown(cache.dispose);
      final image = await testImage();

      cache.putReady(1, image);
      expect(cache.lookupById(1), isA<KittyImageReady>());

      cache.dispose();
      cache.dispose();

      expect(cache.lookupById(1), isNull);
    });

    testWidgets('same-size retransmission invalidates a reused image id', (
      tester,
    ) async {
      await tester.runAsync(() async {
        var ready = Completer<void>();
        final cache = KittyImageCache(
          onImageReady: () {
            if (!ready.isCompleted) ready.complete();
          },
        );
        addTearDown(cache.dispose);

        expect(
          cache.lookupRgba(
            imageId: 1,
            generation: 10,
            width: 1,
            height: 1,
            rgba: Uint8List.fromList([0xff, 0x00, 0x00, 0xff]),
          ),
          isA<KittyImagePending>(),
        );
        await ready.future;

        ready = Completer<void>();
        expect(
          cache.lookupRgba(
            imageId: 1,
            generation: 11,
            width: 1,
            height: 1,
            rgba: Uint8List.fromList([0x00, 0xff, 0x00, 0xff]),
          ),
          isA<KittyImagePending>(),
        );
        await ready.future;
        final entry = cache.lookupById(1) as KittyImageReady;
        final bytes = await entry.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(bytes!.buffer.asUint8List(), [0x00, 0xff, 0x00, 0xff]);
      });
    });
  });
}
