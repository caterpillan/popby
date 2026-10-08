// Pop-by: sends a push notification to the circle when a plan is posted or changed.
// Called by the database (see upgrade-4.sql). Needs these secrets: VAPID_PUBLIC, VAPID_PRIVATE,
// VAPID_SUBJECT (mailto:you@example.com) and PUSH_SECRET.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT")!,
  Deno.env.get("VAPID_PUBLIC")!,
  Deno.env.get("VAPID_PRIVATE")!,
);
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const TZ = "Europe/London";
const dayFmt = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, weekday: "short", day: "numeric", month: "short" });
const timeFmt = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "numeric", minute: "2-digit", hour12: true });
const ymd = (d: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(d);

function when(s: Date, e: Date) {
  const day = ymd(s) === ymd(new Date()) ? "Today" : dayFmt.format(s);
  return `${day}, ${timeFmt.format(s).replace(" ", "")}–${timeFmt.format(e).replace(" ", "")}`;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-push-secret") !== Deno.env.get("PUSH_SECRET")) {
    return new Response("Not allowed", { status: 401 });
  }
  const { plan_id, kind } = await req.json();
  const { data, error } = await sb.rpc("push_targets", { p_plan: plan_id });
  if (error) return new Response(error.message, { status: 500 });
  if (!data || !data.length) return new Response("nobody to notify");

  const p = data[0];
  const s = new Date(p.starts_at), e = new Date(p.ends_at);
  if (e < new Date()) return new Response("plan already ended");
  const payload = JSON.stringify({
    title: kind === "updated" ? "Plan changed" : "New pop-by",
    body: `${p.host_name}: ${p.title} · ${when(s, e)}`,
    tag: plan_id,
  });

  let sent = 0;
  await Promise.all(data.map(async (t: any) => {
    try {
      await webpush.sendNotification(
        { endpoint: t.endpoint, keys: { p256dh: t.p256dh, auth: t.auth } },
        payload,
        { TTL: 3600 },
      );
      sent++;
    } catch (err: any) {
      // The phone turned notifications off or uninstalled the app: forget it.
      if (err.statusCode === 404 || err.statusCode === 410) {
        await sb.from("push_subscriptions").delete().eq("endpoint", t.endpoint);
      }
    }
  }));
  return new Response(`sent ${sent}`);
});
