-- Where the listener was in a YouTube playlist or channel moved to ListenJar
-- Cloud, by video, until its uploads arrived. Moving is gone; the table stays
-- so later versions number on.
create table if not exists carried (
  feed_id text not null,
  video_id text not null,
  position_ms integer not null,
  played integer not null,
  primary key (feed_id, video_id)
) strict;
