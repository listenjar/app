// Telling a network that isn't there from a server that said no.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Whether [error] says the server couldn't be reached at all: no network,
/// a lookup that failed, a connection dropped or timed out. Nothing is wrong
/// with what was asked for; it works again once the network is back.
bool unreachable(Object? error) => switch (error) {
  SocketException() || HttpException() || TimeoutException() || http.ClientException() => true,
  _ => false,
};
