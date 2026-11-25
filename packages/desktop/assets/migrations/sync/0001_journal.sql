-- Before versions, the journal made its tables on every open: an existing
-- journal at version 0 has them already.
create table if not exists downloads (
  key text primary key,
  identity text not null
) strict;

create table if not exists ranges (
  key text not null references downloads (key) on delete cascade,
  start integer not null,
  sha256 text not null,
  primary key (key, start)
) strict;

create table if not exists skips (
  key text primary key,
  reason text not null,
  at integer not null
) strict;
