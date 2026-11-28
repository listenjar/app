-- The library as Listenjar Cloud last agreed on it, by record
-- (library_sync.dart): what changed here since is what differs from it, and
-- `pending` marks what the Cloud changed that isn't here yet.
create table if not exists sync_base (
  kind text not null,
  show text not null,
  item text not null,
  updated_at integer not null,
  data text,
  pending integer not null default 0,
  primary key (kind, show, item)
) strict, without rowid;
