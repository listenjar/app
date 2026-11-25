// An episode's chapters, wherever they come from: the downloaded file's own
// metadata (media_chapters.dart) or, for a YouTube video, YouTube's player
// bar (youtube.dart), kept on the device once found (library.dart). The
// player keeps them in memory for the episode loaded, and Now Playing shows
// them the same either way. No widgets here.

/// A stretch of an episode that starts at [start].
typedef Chapter = ({Duration start, String title});

/// The index of the chapter playing at [position], or -1 before the first.
int chapterAt(List<Chapter> chapters, Duration position) {
  var at = -1;
  for (final (i, c) in chapters.indexed) {
    if (c.start > position) break;
    at = i;
  }
  return at;
}
