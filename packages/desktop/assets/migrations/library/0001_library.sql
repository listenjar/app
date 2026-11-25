create table podcasts (
  id integer primary key,
  feed_url text not null unique,
  kind text not null default 'rss',
  title text not null,
  author text not null default '',
  description text not null default '',
  artwork_url text,
  link text,
  subscribed_at integer not null,
  refreshed_at integer,
  refresh_error text,
  etag text,
  last_modified text,
  cloud_feed_id text,
  auto_download integer not null default 0,
  followed integer not null default 1
) strict;

create table episodes (
  id integer primary key,
  podcast_id integer not null references podcasts (id) on delete cascade,
  guid text not null,
  title text not null,
  description text not null default '',
  published_at integer,
  duration_ms integer,
  audio_url text,
  audio_type text,
  audio_bytes integer,
  artwork_url text,
  link text,
  youtube_id text,
  season integer,
  number integer,
  position_ms integer not null default 0,
  played integer not null default 0,
  played_at integer,
  download_path text,
  download_state text not null default 'none',
  download_progress real not null default 0,
  download_error text,
  added_at integer not null,
  unique (podcast_id, guid)
) strict;

create index episodes_by_date on episodes (podcast_id, published_at desc);
create index episodes_new on episodes (played, published_at desc);

create table queue (
  episode_id integer primary key references episodes (id) on delete cascade,
  position real not null
) strict;

create table settings (
  key text primary key,
  value text not null
) strict;
