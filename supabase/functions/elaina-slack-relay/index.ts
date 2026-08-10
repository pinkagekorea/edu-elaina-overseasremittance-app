// ═══════════════════════════════════════════════════════════════
// 호출 알림을 슬랙으로 — 판정과 발송은 여기서만 한다
//
//   비밀값은 코드에도 index.html 에도 넣지 않는다. 이 함수의
//   환경변수에만 둔다:
//     ELAINA_SLACK_BOT_TOKEN    (선택) 있으면 개인 DM 을 시도한다
//     ELAINA_SLACK_WEBHOOK_URL  (선택) 있으면 채널 heads-up 을 보낸다
//     ELAINA_APP_BASE_URL       (선택) 딥링크 앞에 붙는 배포 주소
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 는 런타임이 넣어 준다.
//
//   등급:
//     dm      짝 맞춤표에 있고 봇 토큰도 있을 때 → 개인 DM
//     channel 그렇지 않고 웹훅이 있을 때        → 채널로만
//     bell    둘 다 없을 때                     → 아무 것도 안 보냄
//
//   나 자신을 부른 경우는 인앱 벨이 울리지 않는다(설계). 대신 채널
//   heads-up 만 보낸다 — 웹훅이 살아 있는지 확인하는 통로다. 짝이
//   맞아 있어도 DM 으로는 보내지 않는다.
//
//   화면이 보낸 내용을 그대로 쏘지 않는다. 메모 번호만 받고 본문·
//   받는 사람은 DB 에서 다시 읽는다. 그래서 남의 이름으로 보내거나
//   내용을 바꿔치기할 수 없다.
// ═══════════════════════════════════════════════════════════════
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST 만 받습니다." }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!url || !svc) return json({ error: "서버 설정이 없습니다." }, 500);

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "로그인이 필요합니다." }, 401);

  const db = createClient(url, svc, { db: { schema: "edu" } });

  const { data: who, error: whoErr } = await db.auth.getUser(jwt);
  const me = who?.user;
  if (whoErr || !me) return json({ error: "로그인이 필요합니다." }, 401);

  let body: { memo_id?: number; reply_id?: number };
  try { body = await req.json(); } catch { return json({ error: "잘못된 요청입니다." }, 400); }

  const memoId = body.memo_id ?? null;
  const replyId = body.reply_id ?? null;
  if (memoId == null && replyId == null) {
    return json({ error: "memo_id 또는 reply_id 가 필요합니다." }, 400);
  }

  // 이 글을 쓴 사람만 자기 호출을 내보낼 수 있다
  const src = replyId != null
    ? await db.from("elaina_memo_replies")
        .select("id, author_id, memo_id, body, mention_ids").eq("id", replyId).maybeSingle()
    : await db.from("elaina_memos")
        .select("id, author_id, body, mention_ids, target_type, target_id, target_label")
        .eq("id", memoId).maybeSingle();
  if (src.error || !src.data) return json({ error: "그런 글이 없습니다." }, 404);
  if (src.data.author_id !== me.id) return json({ error: "본인이 쓴 글만 보낼 수 있습니다." }, 403);

  // 답글이면 대상 정보는 부모 메모에서 가져온다
  let target = {
    type: (src.data as Record<string, string>).target_type ?? "",
    id: (src.data as Record<string, string>).target_id ?? "",
    label: (src.data as Record<string, string>).target_label ?? "",
    memoId: replyId != null ? (src.data as Record<string, number>).memo_id : memoId,
  };
  if (replyId != null) {
    const parent = await db.from("elaina_memos")
      .select("target_type, target_id, target_label").eq("id", target.memoId).maybeSingle();
    target = { ...target,
      type: parent.data?.target_type ?? "",
      id: parent.data?.target_id ?? "",
      label: parent.data?.target_label ?? "" };
  }

  const token = (Deno.env.get("ELAINA_SLACK_BOT_TOKEN") ?? "").trim();
  const hook = (Deno.env.get("ELAINA_SLACK_WEBHOOK_URL") ?? "").trim();
  let base = (Deno.env.get("ELAINA_APP_BASE_URL") ?? "").trim();
  if (base && !/^https?:\/\/[^/]+\//.test(base)) base += "/";

  function deepLink() {
    return base
      ? `\n<${base}?t=${encodeURIComponent(target.type)}&id=${encodeURIComponent(target.id)}&drawer=1&memo=${target.memoId}|→ 그 메모 열기>`
      : "";
  }
  async function toChannel(text: string) {
    const r = await fetch(hook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    return r.ok ? null : `채널 실패: ${r.status}`;
  }

  const results: Array<{ name: string; tier: string; detail?: string }> = [];

  // ── 남을 부른 경우 — 알림 행이 대상이다 ─────────────────────
  const q = db.from("elaina_notifications").select("*").eq("actor_id", me.id);
  const notes = replyId != null ? await q.eq("reply_id", replyId) : await q.eq("memo_id", memoId).is("reply_id", null);
  if (notes.error) return json({ error: notes.error.message }, 500);

  for (const n of notes.data ?? []) {
    // 이미 내보낸 건은 건너뛴다 (두 번 눌러도 두 번 가지 않는다)
    const seen = await db.from("elaina_slack_deliveries")
      .select("id").eq("notification_id", n.id).maybeSingle();
    if (seen.data) continue;

    const to = await db.from("elaina_viewers")
      .select("display_name").eq("user_id", n.recipient_id).maybeSingle();
    const name = to.data?.display_name ?? "알 수 없음";

    const head = n.kind === "reply"
      ? `*${n.actor_name ?? "누군가"}* 님이 *${name}* 님의 메모에 답글을 남겼습니다`
      : `*${n.actor_name ?? "누군가"}* 님이 *${name}* 님을 불렀습니다`;
    const text = `🗄 서랍 · ${n.target_label ?? n.target_id}\n${head}\n>${(n.excerpt ?? "").replace(/\n/g, "\n>")}${deepLink()}`;

    const slack = await db.from("elaina_slack_links")
      .select("slack_user_id").eq("user_id", n.recipient_id).maybeSingle();

    let tier = "bell";
    let detail = "";

    try {
      if (slack.data?.slack_user_id && token) {
        const r = await fetch("https://slack.com/api/chat.postMessage", {
          method: "POST",
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({ channel: slack.data.slack_user_id, text }),
        });
        const out = await r.json().catch(() => ({}));
        if (out?.ok) { tier = "dm"; }
        else {
          detail = `DM 실패: ${out?.error ?? r.status}`;
          if (hook) {                                  // DM 이 안 되면 채널로 내린다
            const bad = await toChannel(text);
            tier = bad ? "bell" : "channel";
            if (bad) detail += ` / ${bad}`;
          }
        }
      } else if (hook) {
        const bad = await toChannel(text);
        tier = bad ? "bell" : "channel";
        if (bad) detail = bad;
        else detail = token ? "짝 맞춤표에 없어 채널로만" : "봇 토큰이 없어 채널로만";
      } else {
        detail = token ? "짝 맞춤표에 없고 웹훅도 없음" : "봇 토큰도 웹훅도 없음";
      }
    } catch (e) {
      // 슬랙 때문에 메모가 깨지면 안 된다. 등급만 bell 로 남기고 넘어간다.
      tier = "bell";
      detail = `보내다 실패: ${e instanceof Error ? e.message : String(e)}`;
    }

    await db.from("elaina_slack_deliveries").insert({
      notification_id: n.id,
      memo_id: n.memo_id,
      reply_id: n.reply_id,
      actor_id: me.id,
      recipient_id: n.recipient_id,
      recipient_name: name,
      tier,
      detail: detail || null,
    });

    results.push({ name, tier, detail: detail || undefined });
  }

  // ── 나 자신을 부른 경우 — 채널 heads-up 만 (DM 은 시도하지 않는다) ──
  const mentions: string[] = (src.data as { mention_ids?: string[] }).mention_ids ?? [];
  if (mentions.includes(me.id)) {
    const dupe = await db.from("elaina_slack_deliveries")
      .select("id")
      .is("notification_id", null)
      .eq("recipient_id", me.id)
      .eq(replyId != null ? "reply_id" : "memo_id", replyId ?? memoId)
      .maybeSingle();

    if (!dupe.data) {
      const mine = await db.from("elaina_viewers")
        .select("display_name").eq("user_id", me.id).maybeSingle();
      const myName = mine.data?.display_name ?? "나";
      const excerpt = String((src.data as { body?: string }).body ?? "").trim().slice(0, 140);
      const text = `🗄 서랍 · ${target.label || target.id}\n*${myName}* 님이 자기 자신을 불렀습니다 (웹훅 점검)\n>${excerpt.replace(/\n/g, "\n>")}${deepLink()}`;

      let tier = "bell";
      let detail = "나 자신 호출 — 인앱 벨은 울리지 않습니다";
      try {
        if (hook) {
          const bad = await toChannel(text);
          tier = bad ? "bell" : "channel";
          detail = bad ? `${detail} / ${bad}` : `${detail}, 채널로만 보냈습니다`;
        } else {
          detail = `${detail} / 웹훅이 없어 아무 것도 보내지 않았습니다`;
        }
      } catch (e) {
        tier = "bell";
        detail = `보내다 실패: ${e instanceof Error ? e.message : String(e)}`;
      }

      await db.from("elaina_slack_deliveries").insert({
        notification_id: null,
        memo_id: target.memoId,
        reply_id: replyId,
        actor_id: me.id,
        recipient_id: me.id,
        recipient_name: myName,
        tier,
        detail,
      });

      results.push({ name: `${myName}(나 자신)`, tier, detail });
    }
  }

  return json({
    results,
    has_token: !!token,
    has_webhook: !!hook,
  });
});
