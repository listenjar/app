// Uploads: the one way the app stores a file with ListenJar, whatever the
// file and whichever R2 bucket keeps it (public.yaml, "Uploads"). It asks
// the API for an upload with the file's type and exact size (NewUpload),
// gets a presigned PUT and the headers to send with it (PresignedUpload),
// sends the bytes straight to the bucket, and confirms, which is when the
// API makes the file live. An episode's audio (sync.dart) and a podcast's
// artwork (feeds.dart) both come through here.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'backend/api.dart';
import 'transfer.dart';

/// A file to upload: its type, its exact size, and its bytes, read afresh
/// each time an upload starts.
final class UploadFile {
  UploadFile.file(File file, this.contentType, this.byteLength) : _open = file.openRead;

  UploadFile.bytes(Uint8List bytes, this.contentType)
    : byteLength = bytes.length,
      _open = (() => Stream.value(bytes));

  static Future<UploadFile> fromFile(File file, String contentType) async =>
    UploadFile.file(file, contentType, await file.length());

  final String contentType;
  final int byteLength;
  final Stream<List<int>> Function() _open;

  NewUpload get request => NewUpload(contentType: NewUploadContentType.fromJson(contentType), byteLength: byteLength);
}

/// Uploads [file]: [presign] asks the API where to (its createUpload or
/// createImageUpload), the bytes go there, and [complete] confirms them (its
/// completeEpisode or completeImage) and is what this returns. [presign]
/// answers null when there is nothing to upload any more (someone else
/// uploaded it first), and then this does too.
Future<T?> uploadThrough<T>(
  HttpClient http,
  UploadFile file, {
  required Future<PresignedUpload?> Function(NewUpload) presign,
  required Future<T> Function() complete,
  required CancellationToken token,
  Progress? progress,
}) async {
  final put = await presign(file.request).asCancellable(token);
  if (put == null) return null;
  await _put(http, file, put, progress ?? (_, _) {}, token);
  return complete().asCancellable(token);
}

/// Sends [file] to the presigned [put], with its headers exactly.
Future<void> _put(HttpClient http, UploadFile file, PresignedUpload put, Progress progress, CancellationToken token) async {
  final request = await http.openUrl(put.method.value, Uri.parse(put.url)).asCancellable(token);
  final done = CancellableCompleter<void>(token, onCancel: () => request.abort(token.exception));
  unawaited(() async {
    try {
      put.headers.forEach((name, value) => request.headers.set(name, '$value'));
      request.contentLength = file.byteLength;
      var sent = 0;
      await request.addStream(file._open().map((chunk) {
        sent += chunk.length;
        progress(sent, file.byteLength);
        return chunk;
      }));
      final response = await request.close();
      final body = await response.fold<List<int>>([], (all, chunk) {
        if (all.length < 4096) all.addAll(chunk.take(4096 - all.length));
        return all;
      });
      if (response.statusCode ~/ 100 != 2) {
        throw TransferStatusException('upload (${String.fromCharCodes(body)})', response.statusCode);
      }
      done.complete();
    } catch (error, stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    }
  }());
  await done.future;
}
