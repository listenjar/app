-- An episode of a show made of sources (a YouTube video, playlist or channel,
-- a podcast of the listener's own, or the ListenJar feed of one) is its
-- source, once: the canonical URL of what it was made from
-- (canonical_source_url, links.dart). Of several made from one source, one
-- stays: the copy its ListenJar feed has, else the one downloaded, playing,
-- in Up Next or listened to, else the oldest. It takes where the listener
-- last was, Up Next and Now Playing; the others' downloads go to the trash.
alter table episodes add column source_url text;

create temp table sourced as
select e.id, e.podcast_id, e.played, e.position_ms, e.played_at, e.download_path,
  coalesce('https://www.youtube.com/watch?v=' || e.youtube_id, canonical_source_url(e.link)) as source,
  (e.audio_url is not null) * 16
    + (e.download_state = 'done') * 8
    + (e.id in (select episode_id from now_playing where episode_id is not null)) * 4
    + (e.id in (select episode_id from queue)) * 2
    + (e.position_ms > 0 or e.played = 1) as rank
from episodes e join podcasts p on p.id = e.podcast_id
where (p.kind != 'rss' or p.cloud_feed_id is not null)
  and (e.youtube_id is not null or e.link is not null);

create temp table ranked as
select *,
  first_value(id) over same_by_rank as keep,
  row_number() over same_by_recency as recency,
  max(played) over same as any_played,
  count(*) over same as copies
from sourced
where source is not null
window same as (partition by podcast_id, source),
  same_by_rank as (same order by rank desc, id),
  same_by_recency as (same order by coalesce(played_at, 0) desc, rank desc, id);

update episodes set
  played = r.any_played,
  position_ms = iif(r.any_played, 0, r.position_ms),
  played_at = r.played_at
from ranked r
where episodes.id = r.keep and r.recency = 1 and r.copies > 1;

update or ignore queue set episode_id = r.keep
from ranked r
where queue.episode_id = r.id and r.id != r.keep;

update now_playing set episode_id = r.keep
from ranked r
where now_playing.episode_id = r.id and r.id != r.keep;

insert into temp.trash (path)
select r.download_path
from ranked r join episodes k on k.id = r.keep
where r.id != r.keep and r.download_path is not null and r.download_path is not k.download_path;

delete from episodes where id in (select id from ranked where id != keep);

update episodes set source_url = r.source
from ranked r
where episodes.id = r.id and r.id = r.keep;

drop table temp.ranked;
drop table temp.sourced;

-- Every show's episodes are unique by source; most have none.
create unique index episodes_source on episodes (podcast_id, source_url) where source_url is not null;
