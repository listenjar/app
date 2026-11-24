/// YouTube.js (the listenbox/YouTube.js fork) in embedded QuickJS, with the
/// same API in Dart: `Innertube.create`, `innertube.getBasicInfo`,
/// `format.decipher(innertube.session.player)`. Its namespaces are libraries
/// of their own, imported with YouTube.js's names:
///
/// ```dart
/// import 'package:youtubei/youtubei.dart';
/// import 'package:youtubei/misc.dart' as Misc;
/// import 'package:youtubei/yt.dart' as YT;
/// import 'package:youtubei/yt_nodes.dart' as YTNodes;
/// ```
///
/// Where YouTube.js takes an AbortSignal, this takes a CancellationToken.
library;

export 'src/engine.dart' show YouTubeiLog;
export 'src/fetch.dart';
export 'src/innertube.dart';
export 'src/utils.dart' show InnertubeError, UniversalCache;
