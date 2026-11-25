-- When each download finished, for removing the unused ones.
alter table episodes add column downloaded_at integer;
update episodes set downloaded_at = added_at where download_state = 'done';
