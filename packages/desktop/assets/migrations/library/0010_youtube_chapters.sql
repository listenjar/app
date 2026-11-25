-- A YouTube video's chapters, kept the first time YouTube answers for it and
-- never asked for again: [[start ms, title], …], `[]` for a video without
-- any. Keyed by the video, not an episode, so every episode of it (a show of
-- one, a playlist's, a ListenJar feed's) shares them, and a download has them
-- offline.
create table if not exists youtube_chapters (
  video_id text primary key,
  chapters text not null
) strict;
