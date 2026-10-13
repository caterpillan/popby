# PopRound

Parents share "we'll be here from X to Y, join if you're free" with the other parents in a circle (a class, a team, a street).

It is a web app that installs on a phone home screen. **You do not need your own server.** The app files are static, so GitHub Pages or GitLab Pages hosts them free. The database, logins and live updates run on a free Supabase project.

## What's in this folder

| File | What it does |
| --- | --- |
| `index.html` | The whole app |
| `config.js` | Your Supabase URL and anon key (the only file you edit) |
| `schema.sql` | Everything in the database, for a **brand-new** Supabase project only |
| `upgrade-7.sql` | Circle colours and icons, starred circles, hiding one activity from chosen people. Run after upgrade-6 |
| `upgrade-9.sql` / `push-key.sql` | Lets the database send your public key when calling the push function (fixes "No API key"). Run after upgrade-8, then run push-key.sql once with your anon key |
| `upgrade-10.sql` | Private optional first and last name on your Profile. Run after upgrade-9 |
| `upgrade-8.sql` | Secret word check when joining, show-my-name choice on replies, leave-by alerts. Run after upgrade-7 |
| `upgrade-6.sql` | Optional end time, "I might pop by" / "See you there" replies, "Not for me". Run after upgrade-5 |
| `upgrade-5.sql` | Family members (children and adults), who is going, two-way blocking, reports. Run after upgrade-3 and upgrade-4 |
| `upgrade-4.sql`, `push-config.sql`, `supabase/functions/send-push/` | Push notifications. Follow `PUSH-SETUP.md` |
| `upgrade-3.sql` | Editing a plan after sharing it (adds the "Updated" badge). Needed if you set up before this was added |
| `upgrade-2.sql` | Only the newer features (circle end dates, member list, removal, nicknames, hide-from). Use this if you already ran the older schema |
| `manifest.webmanifest`, `sw.js`, `icon*.png`, `icon.svg`, `apple-touch-icon.png` | Make it installable on a phone |
| `.gitlab-ci.yml` | Only needed for GitLab Pages |

## 1. Set up Supabase (about 10 minutes)

1. Create a free account and a new project at supabase.com. Pick a region near you (London if you are in the UK).
2. Open **SQL Editor**, paste all of `schema.sql`, and press **Run**. It should finish without errors. (Already set up earlier? Paste only `upgrade-2.sql` instead. It is safe to run twice. Do not re-run `schema.sql`; it will say "already exists".)
3. Open **Authentication > Providers > Email** and turn **off** "Confirm email" while you test with family and friends. Turn it back on before real users.
4. Open **Project Settings > API**. Copy the **Project URL** and the **anon public** key.
5. Open `config.js` and replace `PASTE_YOUR_SUPABASE_URL` and `PASTE_YOUR_ANON_KEY` with those two values (keep the quote marks). Your keys live only in this file, so updating `index.html` later never erases them.

The anon key is meant to be public. The database rules in `schema.sql` are what protect the data. Never put the `service_role` key anywhere in this project.

## 2. Publish it

**GitHub Pages**

1. Create a new **public** repository and upload every file in this folder.
2. Open **Settings > Pages**, choose **Deploy from a branch**, pick `main` and `/ (root)`, and save.
3. After a minute your app is at `https://YOUR-USERNAME.github.io/YOUR-REPO/`.

**GitLab Pages**

1. Create a project and push every file, including `.gitlab-ci.yml`.
2. The pipeline publishes it. Find the address under **Deploy > Pages**.

Then, in Supabase, open **Authentication > URL Configuration** and set **Site URL** to your published address.

## 3. Put it on phones

- **iPhone:** open the address in Safari, tap Share, then **Add to Home Screen**.
- **Android:** open it in Chrome, tap the menu, then **Install app** (or Add to Home screen).

## 4. Test with your wife and friends

1. Everyone opens the app, creates an account, and adds their name and their children's first names.
2. One person taps **Circles > Create circle** and shares the 6-character code.
3. Others tap **Circles**, enter the code, and **Request to join**. The organiser sees them under "Waiting for your approval" and approves.
4. Post a Drop-in or a Party. Other members see it appear live and can reply.

## Circle features

- **End date (optional):** the organiser can set one when creating a circle. Everyone sees it before they join. After it passes, the circle and its plans disappear for everyone and are deleted 30 days later.
- **Members and organisers:** tap Circles > Open to see who is in a circle. Organisers can make others organisers or remove people. A sole organiser must hand over before leaving.
- **Silent removal:** the removed person is not told. They simply lose the circle, and their plans in it are deleted. They are blocked from rejoining until the organiser taps **Allow back**.
- **Private nicknames:** rename a circle on your own phone only.
- **Circles row:** your circles appear as round bubbles across the top, with the icon and name inside and a number showing what is coming up. Tap one to see only that circle. Swipe sideways for more. Star a circle in its settings to keep it first. The + bubble opens Circles (find a circle, create a new one).
- **Circle look:** the organiser picks a colour and icon when creating a circle, and can change them later. Everyone in the circle sees them. There are no photos.
- **Hide one activity from some people:** when you share or edit an activity, open "Hide from specific people" and tick names. They are not told.
- **Replies:** other members choose I might pop by (maybe), See you there (definitely going) or Not for me (hides the activity from their own screen, host not told; undo in Settings > Hidden activities). The host sees both counts and names. Other members see the totals, and see a name only if that person turned on "Show my name" for that circle (off by default).
- **End time is optional:** leave Until empty if it ends when it ends. An end time earlier than the start (11pm to 2am) is read as the next day.
- **Family members:** each person in your family can be marked child or adult. When you share an activity you tick who is going, including yourself.
- **Block, unblock, report:** blocking works both ways and nobody is told. Blocked people are managed in Settings. Reports are saved for you to review in Supabase (Table Editor > `reports`).
- **Edit an activity:** (plans are called activities in the app)
- **Edit a plan:** the person who posted it taps Edit to change the title, place, time, day or note. The plan shows an Updated badge, and circle members with the app open see an "Updated" notice. Replies are kept.
- **Hide my plans from:** in Profile, pick people who must not see your plans or who replied to them. They are not told.

## What it does not do yet

- **Push notifications need one-time setup** (see `PUSH-SETUP.md`). Until then, alerts only appear while the app is open. Alert times use UK time.
- **Locations are typed text,** not a map pin or live tracking. That is deliberate for privacy.
- **No block or report buttons in the screens yet.** The database tables for them exist.
- **Email and password only.** Add a magic link or Apple/Google sign-in later.
- **Privacy basics for real use:** before you invite people outside your circle of friends, write a privacy policy and review the UK ICO Children's Code.

## Changing the app

Upload the new `index.html` over the old one (Add file > Upload files, same name) and refresh. `config.js` keeps your keys. If a phone still shows the old version, close and reopen the app once.

## Round 3 features
- **Secret word check:** an organiser can set a secret word and 2 to 3 decoys (when creating a circle, or later in the circle's settings). Joiners pick from the mixed-up list and get one try. A wrong pick quietly puts them on the organiser's Removed list until the organiser taps Allow back. PopRound never sends the word anywhere; the organiser tells people themselves.
- **Show my name on replies:** chosen when joining a circle and changeable in the circle's settings. Off by default: only the person who posted the activity sees your name; everyone sees the totals.
- **Leave-by alerts:** after replying, tap "Set a leave-by alert" on the activity and pick a time. A phone notification arrives then. Needs push notifications set up (PUSH-SETUP.md) and pg_cron switched on (Supabase > Database > Extensions), then run upgrade-8.sql again if it was off the first time. Redeploy the send-push function with the newest `send-push-code.txt`.

- **Back arrows, Saved buttons, Change reply:** Settings and Circles have a back arrow. Save buttons grey out with Saved when done. After you reply, tap Change on the card to switch your reply, set or change a leave-by alert, take your reply back, or hide it. Hidden activities are listed under Hidden on the home screen.
- **Header and Profile:** a round Circles button on the left, the PopRound name and logo in the middle, a cog for Settings on the right. Settings has collapsible sections; Profile (username, optional private first and last name, family members) is its own page inside Settings. A circle's settings are also collapsible.
