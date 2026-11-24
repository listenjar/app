import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

/// YouTube.js's `fetch` option: the transport its requests go through. The
/// token stands in for the request's AbortSignal.
typedef Fetch = Future<FetchResponse> Function(FetchRequest request, CancellationToken token);

/// One HTTP request YouTube.js makes through its `fetch`.
final class FetchRequest {
  const FetchRequest({required this.url, required this.method, required this.headers, this.body});
  final String url;
  final String method;
  final List<(String, String)> headers;
  final Uint8List? body;
}

final class FetchResponse {
  const FetchResponse({required this.url, required this.status, required this.headers, required this.body});
  final String url;
  final int status;
  final List<(String, String)> headers;
  final Uint8List body;
}

/// A [Fetch] over a dart:io [HttpClient]. Cancelling the token aborts the
/// request. Set `client.userAgent = null`: YouTube.js sends its own.
Fetch httpClientFetch(HttpClient client) => (request, token) async {
  token.throwIfCancelled();
  final outgoing = await client.openUrl(request.method, Uri.parse(request.url)).asCancellable(token);
  final done = CancellableCompleter<FetchResponse>(token, onCancel: () => outgoing.abort(token.exception));
  unawaited(() async {
    try {
      for (final (name, value) in request.headers) {
        outgoing.headers.add(name, value, preserveHeaderCase: true);
      }
      if (request.body case final body?) {
        outgoing.contentLength = body.length;
        outgoing.add(body);
      }
      final response = await outgoing.close();
      final body = BytesBuilder(copy: false);
      await response.forEach(body.add);
      final headers = <(String, String)>[];
      response.headers.forEach((name, values) => headers.addAll([for (final v in values) (name, v)]));
      final url = response.redirects.fold(Uri.parse(request.url), (url, r) => url.resolveUri(r.location));
      done.complete(FetchResponse(url: '$url', status: response.statusCode, headers: headers, body: body.takeBytes()));
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  }());
  return done.future;
};
