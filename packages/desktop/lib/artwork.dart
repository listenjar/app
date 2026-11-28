// A podcast's artwork, made from whatever picture the listener picks: the
// square JPEG podcast apps ask for (Apple's spec: 1400 to 3000 pixels a side,
// RGB). The middle of the picture is kept, transparency goes on white, and
// the camera's orientation is applied. Runs off the UI thread. No widgets.
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Picture files the listener can pick from.
const artworkExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tif', 'tiff'];

const _smallest = 1400;
const _largest = 3000;

/// A picture this can't read.
final class UnreadablePicture implements Exception {
  const UnreadablePicture();
  @override
  String toString() => 'That file isn’t a picture Listenjar can read. Pick a JPEG or PNG.';
}

/// [picture] as podcast artwork: a square image/jpeg.
Future<Uint8List> podcastArtwork(Uint8List picture) => Isolate.run(() {
  final decoded = img.decodeImage(picture);
  if (decoded == null) throw const UnreadablePicture();
  final upright = img.bakeOrientation(decoded);
  final shorter = upright.width < upright.height ? upright.width : upright.height;
  final side = shorter.clamp(_smallest, _largest);
  final square = img.copyResizeCropSquare(upright, size: side, interpolation: img.Interpolation.cubic);
  final white = img.fill(
    img.Image(width: side, height: side),
    color: img.ColorRgb8(255, 255, 255),
  );
  return img.encodeJpg(img.compositeImage(white, square), quality: 88);
});
