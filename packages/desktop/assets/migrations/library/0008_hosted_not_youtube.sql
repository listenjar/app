-- An episode a Listenjar feed took over from a video streaming here kept the
-- video's id beside the feed's audio, so it played from YouTube, which can
-- refuse it, instead of the feed. With audio of its own it isn't a video to
-- look up; its link still names the video for artwork and chapters.
update episodes set youtube_id = null where youtube_id is not null and audio_url is not null;
