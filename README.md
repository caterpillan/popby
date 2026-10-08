# Pop-by

Parents share "we'll be here from X to Y, join if you're free" with the other parents in a circle (a class, a team, a street).

It is a web app that installs on a phone home screen. **You do not need your own server.** The app files are static, so GitHub Pages or GitLab Pages hosts them free. The database, logins and live updates run on a free Supabase project.

## What's in this folder

| File | What it does |
| --- | --- |
| `index.html` | The whole app |
| `config.js` | Your Supabase URL and anon key (the only file you edit) |
| `schema.sql` | Everything in the database, for a **brand-new** Supabase project only |
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
