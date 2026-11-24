// YouTube.js's YTNodes (src/parser/nodes.ts): the parsed pieces of a
// response. A node YouTube.js parsed into a class not listed here is a plain
// [YTNode] with its [YTNode.type]; listed ones carry the properties ListenJar
// reads so far. Add others by their upstream names.
// ignore_for_file: non_constant_identifier_names
import 'package:meta/meta.dart';

import 'json.dart';
import 'misc.dart';

class YTNode {
  const YTNode(this.type);

  /// The YouTube.js class's name: `Video`, `LockupView`…
  final String type;

  @internal
  static YTNode? fromJson(Object? raw) {
    final m = mapOrNull(raw);
    if (m == null) return null;
    final type = string(m['type']) ?? '';
    return switch (type) {
      'Video' => Video._(m),
      'Channel' => Channel._(m),
      'LockupView' => LockupView._(m),
      'LockupMetadataView' => LockupMetadataView._(m),
      'ContentMetadataView' => ContentMetadataView._(m),
      'AvatarStackView' => AvatarStackView._(m),
      'AvatarView' => AvatarView._(m),
      'DecoratedAvatarView' => DecoratedAvatarView._(m),
      'ThumbnailView' => ThumbnailView._(m),
      'CollectionThumbnailView' => CollectionThumbnailView._(m),
      'ThumbnailOverlayBadgeView' => ThumbnailOverlayBadgeView._(m),
      'ThumbnailBottomOverlayView' => ThumbnailBottomOverlayView._(m),
      'ThumbnailBadgeView' => ThumbnailBadgeView._(m),
      'PlaylistVideo' => PlaylistVideo._(m),
      'Alert' => Alert._(m),
      'AlertWithButton' => AlertWithButton._(m),
      'PlayerErrorMessage' => PlayerErrorMessage._(m),
      'PlayerMicroformat' => PlayerMicroformat._(m),
      'NavigationEndpoint' => NavigationEndpoint._(m),
      _ => YTNode(type),
    };
  }

  @internal
  static List<YTNode> listFromJson(Object? raw) => [for (final n in list(raw)) ?fromJson(n)];
}

T? _node<T extends YTNode>(Object? raw) => switch (YTNode.fromJson(raw)) {
  final T node => node,
  _ => null,
};

List<T> _nodes<T extends YTNode>(Object? raw) => YTNode.listFromJson(raw).whereType<T>().toList();

/// `{text, seconds}`, as Video and PlaylistVideo give a duration.
typedef VideoDuration = ({String text, num seconds});

VideoDuration? _duration(Object? raw) {
  final m = mapOrNull(raw);
  if (m == null) return null;
  return (text: string(m['text']) ?? '', seconds: number(m['seconds']) ?? double.nan);
}

final class Video extends YTNode {
  Video._(Json m)
    : video_id = string(m['video_id']) ?? '',
      title = Text.fromJson(m['title']) ?? const Text(null),
      thumbnails = Thumbnail.listFromJson(m['thumbnails']),
      author = Author.fromJson(m['author']),
      short_view_count = Text.fromJson(m['short_view_count']),
      view_count = Text.fromJson(m['view_count']),
      duration = _duration(m['duration']),
      is_live = boolean(m['is_live']) ?? false,
      is_upcoming = boolean(m['is_upcoming']),
      super('Video');
  final String video_id;
  final Text title;
  final List<Thumbnail> thumbnails;
  final Author? author;
  final Text? short_view_count;
  final Text? view_count;
  final VideoDuration? duration;
  final bool is_live;
  final bool? is_upcoming;
}

final class Channel extends YTNode {
  Channel._(Json m)
    : id = string(m['id']) ?? '',
      author = Author.fromJson(m['author']),
      subscriber_count = Text.fromJson(m['subscriber_count']),
      video_count = Text.fromJson(m['video_count']),
      super('Channel');
  final String id;
  final Author? author;
  final Text? subscriber_count;
  final Text? video_count;
}

final class LockupView extends YTNode {
  LockupView._(Json m)
    : content_image = YTNode.fromJson(m['content_image']),
      metadata = _node(m['metadata']),
      content_id = string(m['content_id']),
      content_type = string(m['content_type']) ?? '',
      super('LockupView');

  /// A CollectionThumbnailView or ThumbnailView; a channel's, a
  /// DecoratedAvatarView.
  final YTNode? content_image;
  final LockupMetadataView? metadata;
  final String? content_id;

  /// `VIDEO`, `CHANNEL`, `PLAYLIST`, `SHORT`…
  final String content_type;
}

final class LockupMetadataView extends YTNode {
  LockupMetadataView._(Json m)
    : title = Text.fromJson(m['title']),
      metadata = _node(m['metadata']),
      super('LockupMetadataView');
  final Text? title;
  final ContentMetadataView? metadata;
}

final class MetadataPart {
  const MetadataPart({required this.text, required this.avatar_stack});
  final Text? text;
  final AvatarStackView? avatar_stack;
}

final class MetadataRow {
  const MetadataRow({required this.metadata_parts});
  final List<MetadataPart>? metadata_parts;
}

final class ContentMetadataView extends YTNode {
  ContentMetadataView._(Json m)
    : metadata_rows = [
        for (final r in list(m['metadata_rows']))
          MetadataRow(
            metadata_parts: switch (map(r)['metadata_parts']) {
              final List parts => [
                for (final p in parts) MetadataPart(text: Text.fromJson(map(p)['text']), avatar_stack: _node(map(p)['avatar_stack'])),
              ],
              _ => null,
            },
          ),
      ],
      delimiter = string(m['delimiter']) ?? '',
      super('ContentMetadataView');
  final List<MetadataRow> metadata_rows;
  final String delimiter;
}

final class AvatarStackView extends YTNode {
  AvatarStackView._(Json m) : text = Text.fromJson(m['text']), super('AvatarStackView');
  final Text? text;
}

final class AvatarView extends YTNode {
  AvatarView._(Json m) : image = Thumbnail.listFromJson(m['image']), super('AvatarView');
  final List<Thumbnail> image;
}

final class DecoratedAvatarView extends YTNode {
  DecoratedAvatarView._(Json m) : avatar = _node(m['avatar']), super('DecoratedAvatarView');
  final AvatarView? avatar;
}

final class ThumbnailView extends YTNode {
  ThumbnailView._(Json m)
    : image = Thumbnail.listFromJson(m['image']),
      overlays = YTNode.listFromJson(m['overlays']),
      super('ThumbnailView');
  final List<Thumbnail> image;
  final List<YTNode> overlays;
}

final class CollectionThumbnailView extends YTNode {
  CollectionThumbnailView._(Json m) : primary_thumbnail = _node(m['primary_thumbnail']), super('CollectionThumbnailView');
  final ThumbnailView? primary_thumbnail;
}

final class ThumbnailOverlayBadgeView extends YTNode {
  ThumbnailOverlayBadgeView._(Json m) : badges = _nodes(m['badges']), super('ThumbnailOverlayBadgeView');
  final List<ThumbnailBadgeView> badges;
}

final class ThumbnailBottomOverlayView extends YTNode {
  ThumbnailBottomOverlayView._(Json m) : badges = _nodes(m['badges']), super('ThumbnailBottomOverlayView');
  final List<ThumbnailBadgeView> badges;
}

final class ThumbnailBadgeView extends YTNode {
  ThumbnailBadgeView._(Json m) : text = string(m['text']) ?? '', super('ThumbnailBadgeView');
  final String text;
}

final class PlaylistVideo extends YTNode {
  PlaylistVideo._(Json m)
    : id = string(m['id']) ?? '',
      title = Text.fromJson(m['title']) ?? const Text(null),
      author = Author.fromJson(m['author']),
      thumbnails = Thumbnail.listFromJson(m['thumbnails']),
      is_playable = boolean(m['is_playable']) ?? false,
      upcoming = date(m['upcoming']),
      duration = _duration(m['duration']) ?? (text: '', seconds: double.nan),
      is_live = boolean(m['is_live']) ?? false,
      is_upcoming = boolean(m['is_upcoming']) ?? false,
      super('PlaylistVideo');
  final String id;
  final Text title;
  final Author? author;
  final List<Thumbnail> thumbnails;
  final bool is_playable;
  final DateTime? upcoming;
  final VideoDuration duration;
  final bool is_live;
  final bool is_upcoming;
}

final class Alert extends YTNode {
  Alert._(Json m) : text = Text.fromJson(m['text']), alert_type = string(m['alert_type']) ?? '', super('Alert');
  final Text? text;

  /// `INFO`, `WARNING`, `ERROR`…
  final String alert_type;
}

final class AlertWithButton extends YTNode {
  AlertWithButton._(Json m) : text = Text.fromJson(m['text']), alert_type = string(m['alert_type']) ?? '', super('AlertWithButton');
  final Text? text;
  final String alert_type;
}

final class PlayerErrorMessage extends YTNode {
  PlayerErrorMessage._(Json m)
    : subreason = Text.fromJson(m['subreason']) ?? const Text(null),
      reason = Text.fromJson(m['reason']) ?? const Text(null),
      super('PlayerErrorMessage');
  final Text subreason;
  final Text reason;
}

final class PlayerMicroformat extends YTNode {
  PlayerMicroformat._(Json m)
    : publish_date = string(m['publish_date']) ?? '',
      upload_date = string(m['upload_date']) ?? '',
      super('PlayerMicroformat');
  final String publish_date;
  final String upload_date;
}

final class NavigationEndpoint extends YTNode {
  NavigationEndpoint._(Json m)
    : name = string(m['name']),
      payload = m['payload'],
      metadata = map(m['metadata']),
      super('NavigationEndpoint');
  final String? name;

  /// The endpoint's payload as YouTube sent it (`browseId`, `videoId`…).
  final Object? payload;
  final Map<String, Object?> metadata;
}
