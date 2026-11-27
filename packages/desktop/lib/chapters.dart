// An episode's chapters, wherever they come from: the downloaded file's own
// metadata (media_chapters.dart), for a YouTube video YouTube's player bar
// (youtube.dart), kept on the device once found (library.dart), or the
// timestamped lines its show notes list ([notesChapters]). The player keeps
// them in memory for the episode loaded, and Now Playing shows them the same
// either way. No widgets here.
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

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

/// The chapters show notes list, as podcasts that embed none write them and
/// as Apple Podcasts reads them: lines that start with a time, `(00:39)
/// Title`, `00:39 - Title`, `[1:02:03] Title`, or end with one in brackets
/// or after a dash. Two or more, in order; else none, since times out of
/// order are something other than a table of contents.
List<Chapter> notesChapters(String notes) {
  final chapters = <Chapter>[];
  for (final line in _lines(notes)) {
    final m = _leading.firstMatch(line) ?? _trailing.firstMatch(line);
    if (m == null) continue;
    final start = _time(m.namedGroup('time')!);
    final title = m.namedGroup('title')!.trim();
    if (start == null || title.isEmpty) continue;
    if (chapters.isNotEmpty && start <= chapters.last.start) return const [];
    chapters.add((start: start, title: title));
  }
  return chapters.length < 2 ? const [] : chapters;
}

const _clock = r'(?<time>(?:\d{1,2}:)?\d{1,3}:\d{2})';

/// A list mark before it, if any: `-`, `•`, `*` or `1.`.
const _mark = r'^(?:(?:[-–•*]|\d+\.)\s+)?';

final _leading = RegExp('$_mark[(\\[]?$_clock[)\\]]?(?:\\s*[-–—:|•.]\\s*|\\s+)(?<title>\\S.*)\$');

final _trailing = RegExp('$_mark(?<title>\\S.*?)\\s*(?:[-–—|]\\s*[(\\[]?$_clock[)\\]]?|[(\\[]$_clock[)\\]])\$');

Duration? _time(String clock) {
  final parts = [for (final p in clock.split(':')) int.parse(p)];
  final (h, m, s) = parts.length == 3 ? (parts[0], parts[1], parts[2]) : (0, parts[0], parts[1]);
  if (s >= 60 || (parts.length == 3 && m >= 60)) return null;
  return Duration(hours: h, minutes: m, seconds: s);
}

/// [notes]' lines as read: HTML's blocks and breaks each end one.
Iterable<String> _lines(String notes) {
  if (!RegExp(r'<[a-zA-Z][^>]*>').hasMatch(notes)) return notes.split('\n').map((l) => l.trim());
  final out = StringBuffer();
  void walk(List<dom.Node> nodes) {
    for (final node in nodes) {
      switch (node) {
        case dom.Text():
          out.write(node.text.replaceAll(RegExp(r'\s+'), ' '));
        case dom.Element(localName: 'script' || 'style'):
          break;
        case dom.Element(localName: 'br'):
          out.write('\n');
        case dom.Element(localName: final name?):
          final block = _blocks.contains(name);
          if (block) out.write('\n');
          walk(node.nodes);
          if (block) out.write('\n');
        default:
          break;
      }
    }
  }

  walk(html.parseFragment(notes).nodes);
  return out.toString().split('\n').map((l) => l.trim());
}

const _blocks = {'p', 'div', 'li', 'ul', 'ol', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'section', 'tr', 'td', 'th'};
