-- Department is no longer collected at sign-up. The column was empty for every profile when dropped
-- (checked 2026-09-24); no view, function or policy references it. The website and the Flutter app
-- both read profiles without naming this column, so they keep working.
alter table public.profiles drop column if exists department;
