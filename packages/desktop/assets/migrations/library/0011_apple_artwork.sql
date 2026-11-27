-- Apple's copy of each episode's artwork. Apple's podcast directory serves
-- every show's and episode's picture from its own image servers, which load
-- where a feed's image host doesn't answer, at a few hundred pixels rather
-- than the 3000 px originals feeds link. A show's Apple id is found once, by
-- its feed URL: null until then, 0 when Apple lists no show at that feed.
-- apple_checked_at is when Apple was last asked about it.
alter table podcasts add column apple_id integer;
alter table podcasts add column apple_checked_at integer;
alter table episodes add column apple_artwork_url text;
