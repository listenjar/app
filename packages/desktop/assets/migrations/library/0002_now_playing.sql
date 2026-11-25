create table if not exists now_playing (
  id integer primary key check (id = 1),
  episode_id integer references episodes (id) on delete set null
) strict;
