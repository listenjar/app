-- A serial show lists its episodes in order of their numbers, not their
-- dates: a feed that says so (`<itunes:type>serial</itunes:type>`, as
-- Listenjar's feed of a YouTube playlist does), or a playlist followed on
-- this device, numbered in the playlist's order.
alter table podcasts add column serial integer not null default 0;
