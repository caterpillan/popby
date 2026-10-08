# Turning on push notifications (about 15 minutes, one time)

Push notifications reach phones even when Pop-by is closed. You need to do the steps below once.
You will use the file **push-secrets-DO-NOT-UPLOAD.txt** (it is NOT in the app folder, on purpose: never upload it to GitHub).

## 1. Run the database upgrade
Supabase > **SQL Editor** > paste all of `upgrade-4.sql` > **Run**. (Also run `upgrade-3.sql` first if you haven't yet.)

## 2. Create the sender function
1. Supabase > **Edge Functions** > **Deploy a new function** > **Via Editor**.
2. Name it exactly `send-push`.
3. Delete the sample code, paste in everything from `supabase/functions/send-push/index.ts`, and **Deploy**.
4. Open the function's settings and turn **off** "Verify JWT" / "Enforce JWT verification" (the database calls it with its own secret instead). Save.

## 3. Add the four secrets
Supabase > **Edge Functions** > **Secrets** (or Project Settings > Edge Functions > Secrets). Add these, copying the values from `push-secrets-DO-NOT-UPLOAD.txt`:

| Name | Value |
| --- | --- |
| `VAPID_PUBLIC` | the public key |
| `VAPID_PRIVATE` | the private key |
| `VAPID_SUBJECT` | `mailto:` plus your email, e.g. `mailto:you@example.com` |
| `PUSH_SECRET` | the secret text from the file |

## 4. Connect the database to the function
1. Open `push-config.sql`. Replace `PASTE_FUNCTION_URL` with `https://YOUR-PROJECT-REF.supabase.co/functions/v1/send-push` (same start as your Project URL).
2. Replace `PASTE_A_LONG_RANDOM_SECRET` with the same secret text you used for `PUSH_SECRET`.
3. Paste it into the SQL Editor and **Run**.

## 5. Turn it on in the app
Upload the new `index.html` and `sw.js` to GitHub. On each phone: open Pop-by > **Profile** > **Turn on notifications** > Allow.
On iPhone this only works once Pop-by is added to the Home Screen (Share > Add to Home Screen) and opened from there.

## Check it works
Post a plan from one phone. Phones of other circle members (not the poster) should buzz. If nothing arrives, look at Supabase > Edge Functions > send-push > **Logs**.

## Who gets alerts
Approved members of a running circle, except the poster. Not people the poster hides from, not people who blocked the poster, and not anyone who was removed.
