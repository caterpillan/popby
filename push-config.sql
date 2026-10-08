-- Run this ONCE after deploying the send-push function.
-- 1. Replace PASTE_FUNCTION_URL with your function's URL, e.g. https://abcdefgh.supabase.co/functions/v1/send-push
-- 2. Replace PASTE_A_LONG_RANDOM_SECRET with any long random text (at least 20 letters/numbers).
--    Use the SAME text as the PUSH_SECRET you saved in the function's secrets.
insert into private.push_config (id, url, secret)
values (1, 'PASTE_FUNCTION_URL', 'PASTE_A_LONG_RANDOM_SECRET')
on conflict (id) do update set url = excluded.url, secret = excluded.secret;
