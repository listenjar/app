-- The library syncs the classic way, RSS shows only: what the base held of
-- YouTube shows and of the videos of podcasts of the listener's own goes, as
-- it went from the Cloud.
delete from sync_base where kind = 'listen' and show in (
  select show from sync_base where kind = 'show'
    and json_extract(data, '$.showKind') in ('youtube', 'youtubeFeed', 'own')
);
delete from sync_base where kind = 'video'
  or (kind = 'show' and json_extract(data, '$.showKind') in ('youtube', 'youtubeFeed', 'own'))
  or (kind = 'show' and data is null
    and (show like 'https://www.youtube.com/%' or show not like 'http%'));
