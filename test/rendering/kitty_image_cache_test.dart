import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KittyImageCache', () {
    Future<ui.Image> testImage([
      List<int> rgba = const [0xff, 0xff, 0xff, 0xff],
    ]) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList(rgba),
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

    testWidgets('same-size retransmission keeps the previous image drawable', (
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
        final previous = cache.lookupById(1) as KittyImageReady;
        final replacing = cache.lookupRgba(
          imageId: 1,
          generation: 11,
          width: 1,
          height: 1,
          rgba: Uint8List.fromList([0x00, 0xff, 0x00, 0xff]),
        );
        expect(replacing, same(previous));

        final previousBytes = await previous.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(previousBytes!.buffer.asUint8List(), [0xff, 0x00, 0x00, 0xff]);

        await ready.future;
        final entry = cache.lookupById(1) as KittyImageReady;
        expect(entry, isNot(same(previous)));
        final bytes = await entry.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(bytes!.buffer.asUint8List(), [0x00, 0xff, 0x00, 0xff]);
      });
    });

    testWidgets('coalesces rapid replacements to the newest queued frame', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final pending =
            <({Uint8List rgba, void Function(ui.Image image) complete})>[];
        var readyCount = 0;
        final cache = KittyImageCache(
          onImageReady: () => readyCount++,
          decoder: (rgba, width, height, complete) {
            pending.add((rgba: rgba, complete: complete));
          },
        );
        addTearDown(cache.dispose);

        cache.lookupRgba(
          imageId: 1,
          generation: 10,
          width: 1,
          height: 1,
          rgba: Uint8List.fromList([0xff, 0x00, 0x00, 0xff]),
        );
        cache.lookupRgba(
          imageId: 1,
          generation: 11,
          width: 1,
          height: 1,
          rgba: Uint8List.fromList([0x00, 0xff, 0x00, 0xff]),
        );
        cache.lookupRgba(
          imageId: 1,
          generation: 12,
          width: 1,
          height: 1,
          rgba: Uint8List.fromList([0x00, 0x00, 0xff, 0xff]),
        );

        expect(pending, hasLength(1));
        expect(pending.single.rgba, [0xff, 0x00, 0x00, 0xff]);

        pending.single.complete(await testImage([0xff, 0x00, 0x00, 0xff]));
        expect(readyCount, 1);
        expect(pending, hasLength(2));
        expect(pending.last.rgba, [0x00, 0x00, 0xff, 0xff]);

        pending.last.complete(await testImage([0x00, 0x00, 0xff, 0xff]));
        expect(readyCount, 2);

        final entry = cache.lookupById(1) as KittyImageReady;
        final bytes = await entry.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(bytes!.buffer.asUint8List(), [0x00, 0x00, 0xff, 0xff]);
      });
    });
  });
}
