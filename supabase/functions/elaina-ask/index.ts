// ═══════════════════════════════════════════════════════════════
// 데이터에 물어보기 — 자연어 한 줄을 받아 숫자로 답한다
//
//   네 가지 규칙을 프롬프트로 부탁하지 않는다. 코드 모양으로 지킨다.
//
//   (1) 읽기전용 — 이 파일에 insert·update·delete·upsert·rpc 가
//       없다. .select() 만 부른다. 쓰려고 해도 부를 것이 없다.
//
//   (2) 출처 — 답에는 늘 표 이름·줄 수·건 조건이 함께 나간다.
//       숫자만 따로 나가는 경로가 없다.
//
//   (3) 지어내지 않음 — 값은 조회 결과에서만 만들어진다. 못 알아들으면
//       unparsed, 줄이 없으면 none 으로 돌려보낸다. 그 사이는 없다.
//
//   (4) 권한 — service_role 을 쓰지 않는다. anon 열쇠에 직원의 JWT 를
//       실어 붙으므로 판정은 Postgres 의 RLS 가 한다. 그 위에 표
//       화이트리스트(parse.ts 의 TABLES)를 한 겹 더 겹친다. 명단을
//       서버에 두는 이유는, 화면에 두면 화면을 고쳐 우회할 수 있어서다.
//       edu 스키마에는 luka_returns 처럼 로그인만 하면 열리는 표도
//       있어서 RLS 하나만 믿으면 8일차 직원에게 남의 팀 자료가 샌다.
//
//   비밀값은 이 함수의 환경변수에만 둔다. 지금 쓰는 것은 런타임이
//   넣어 주는 SUPABASE_URL / SUPABASE_ANON_KEY 뿐이고, 사람이 따로
//   넣을 열쇠는 없다. (ELAINA_ANON_KEY 로 덮어쓸 수 있게만 열어 둔다)
// ═══════════════════════════════════════════════════════════════
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  COL_LABEL, COL_UNIT, TABLES,
  leftoverWords, readMetric, readPeriod, readTable, readVendor,
  shiftMonth, sumCol,
} from "./parse.ts";

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

const MAX_ROWS = 500;          // 여기 걸리면 답에 그 사실을 적는다

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST 만 받습니다." }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = (Deno.env.get("ELAINA_ANON_KEY") ??
                Deno.env.get("SUPABASE_ANON_KEY") ??
                Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "").trim();
  if (!url || !anon) return json({ error: "서버 설정이 없습니다." }, 500);

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "로그인이 필요합니다." }, 401);

  let body: { q?: string };
  try { body = await req.json(); } catch { return json({ error: "잘못된 요청입니다." }, 400); }

  const q = String(body.q ?? "").trim().slice(0, 200);
  if (!q) return json({ error: "물어볼 말이 비어 있습니다." }, 400);

  /* 직원의 JWT 를 그대로 실어 붙는다. service_role 이 아니므로 이 아래
     모든 조회는 그 사람의 RLS 판정을 그대로 받는다 — 규칙 (4). */
  const db = createClient(url, anon, {
    db: { schema: "edu" },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const who = await db.auth.getUser(jwt);
  if (who.error || !who.data?.user) return json({ error: "로그인이 필요합니다." }, 401);

  /* 자료에 있는 달과 거래처를 먼저 읽는다. 못 읽으면(권한 없음) 그
     사실이 그대로 답이 된다 — 규칙 (4). */
  const dict = await db.from(TABLES.monthly)
    .select("remit_month, vendor_name").limit(MAX_ROWS);
  if (dict.error) {
    return json({ ok: false, kind: "denied",
      message: "이 데이터를 볼 권한이 없습니다.",
      source: { table: "edu." + TABLES.monthly, rows: 0, filters: [] } });
  }

  const dictRows = (dict.data ?? []) as Array<{ remit_month: string; vendor_name: string }>;
  const months  = [...new Set(dictRows.map((r) => r.remit_month))].sort();
  const vendors = [...new Set(dictRows.map((r) => r.vendor_name))].sort();
  const known = { months: months.slice(-6), vendors };

  if (!dictRows.length) {
    return json({ ok: false, kind: "none",
      message: "볼 수 있는 송금 자료가 없습니다.",
      source: { table: "edu." + TABLES.monthly, rows: 0, filters: [] } });
  }

  /* ── 말을 조건으로 ──────────────────────────────────────────── */
  const table = readTable(q);

  const period = readPeriod(q, months);
  if (!period) {
    return json({ ok: false, kind: "unparsed",
      message: "언제인지 알려주세요.",
      hint: "예: 「7월 JH 송금액」 · 「지난달 미통관」 · 「2026-08 성창 건수」",
      known });
  }

  const met = readMetric(q);

  const ven = readVendor(q, vendors);
  if (ven.hit.length > 1) {
    return json({ ok: false, kind: "unparsed",
      message: `거래처가 여럿 걸립니다 — ${ven.hit.join(" · ")}`,
      hint: "하나만 골라 다시 물어봐 주세요.", known });
  }

  /* 남은 말 검사는 거래처를 못 찾았을 때만 한다. 찾았으면 「스타위그」
     처럼 줄여 부른 토막이 남는데, 그건 이미 설명된 말이다. */
  if (!ven.hit.length) {
    const rest = leftoverWords(q, [period.said, met.said]);
    if (rest.length) {
      return json({ ok: false, kind: "none",
        message: `‘${rest[0]}’ 를 거래처에서 찾지 못했습니다.`,
        known,
        source: { table: "edu." + TABLES.monthly, rows: 0, filters: [] } });
    }
  }

  /* ── 읽는다 — 어느 갈래든 .select() 하나뿐 ──────────────────── */
  const filters: string[] = [];
  const notes: string[] = [];
  let rows: Record<string, unknown>[] = [];
  let cols: string[] = met.metric.cols;
  let title = "";

  if (table === TABLES.daily) {
    let sel = db.from(TABLES.daily).select("*").limit(MAX_ROWS);
    if (period.kind === "date") {
      sel = sel.eq("report_date", period.value);
      filters.push(`report_date = ${period.value}`);
    } else {
      sel = sel.order("report_date", { ascending: false }).limit(1);
      notes.push("날짜를 말씀 안 하셔서 가장 최근 리포트를 봤습니다.");
    }
    const res = await sel;
    if (res.error) {
      return json({ ok: false, kind: "denied", message: "이 표를 볼 권한이 없습니다.",
        source: { table: "edu." + TABLES.daily, rows: 0, filters } });
    }
    rows = (res.data ?? []) as Record<string, unknown>[];
    cols = met.metric.key === "uncl"
      ? ["cur_uncl_krw", "prev_uncl_krw"]
      : ["cur_paid_krw", "prev_paid_krw"];
    title = `${rows[0]?.report_date ?? period.value} · 데일리 리포트`;

  } else if (table === TABLES.each) {
    let sel = db.from(TABLES.each).select("*").limit(MAX_ROWS);
    if (period.kind === "month") {
      const from = period.value + "-01";
      const to = shiftMonth(period.value, 1) + "-01";
      sel = sel.gte("week_date", from).lt("week_date", to);
      filters.push(`week_date ≥ ${from}`, `week_date < ${to}`);
    } else {
      sel = sel.eq("week_date", period.value);
      filters.push(`week_date = ${period.value}`);
    }
    if (ven.used) { sel = sel.eq("vendor_name", ven.used); filters.push(`vendor_name = ${ven.used}`); }
    const res = await sel;
    if (res.error) {
      return json({ ok: false, kind: "denied", message: "이 표를 볼 권한이 없습니다.",
        source: { table: "edu." + TABLES.each, rows: 0, filters } });
    }
    rows = (res.data ?? []) as Record<string, unknown>[];
    cols = ["krw"];
    title = [period.said, ven.used, "건별 송금"].filter(Boolean).join(" · ");

  } else {
    /* 월별 실적 · 기준선 — 칸 이름이 같아 한 갈래로 다룬다 */
    if (period.kind !== "month") {
      return json({ ok: false, kind: "unparsed",
        message: "이 표는 달 단위로만 볼 수 있습니다.",
        hint: "예: 「7월 JH 송금액」", known,
        source: { table: "edu." + table, rows: 0, filters } });
    }
    let sel = db.from(table).select("*").eq("remit_month", period.value).limit(MAX_ROWS);
    filters.push(`remit_month = ${period.value}`);
    if (ven.used) { sel = sel.eq("vendor_name", ven.used); filters.push(`vendor_name = ${ven.used}`); }
    const res = await sel;
    if (res.error) {
      return json({ ok: false, kind: "denied", message: "이 표를 볼 권한이 없습니다.",
        source: { table: "edu." + table, rows: 0, filters } });
    }
    rows = (res.data ?? []) as Record<string, unknown>[];
    title = [period.value, ven.used || "전체 거래처", met.metric.label].join(" · ");
    if (!ven.used)   notes.push("거래처를 말씀 안 하셔서 그 달 전체를 더했습니다.");
    if (!met.given)  notes.push("항목을 말씀 안 하셔서 실제 송금액으로 봤습니다.");
  }

  /* ── 줄이 없으면 없다고 한다. 여기서 0 을 만들어 내지 않는다 ── */
  if (!rows.length) {
    return json({ ok: false, kind: "none",
      message: "데이터 없음",
      detail: `${filters.join(", ") || "조건 없음"} 로 맞는 줄이 없습니다.`,
      known,
      source: { table: "edu." + table, rows: 0, filters } });
  }

  const lines = cols
    .map((c) => ({
      label: COL_LABEL[c] ?? c,
      col: c,
      value: sumCol(rows, c),
      unit: COL_UNIT[c] ?? "",
    }))
    .filter((l) => l.value !== null);

  if (!lines.length) {
    return json({ ok: false, kind: "none",
      message: "데이터 없음",
      detail: `${cols.join(", ")} 칸이 비어 있습니다.`,
      source: { table: "edu." + table, rows: rows.length, filters } });
  }

  if (rows.length >= MAX_ROWS) {
    notes.push(`${MAX_ROWS}줄까지만 읽었습니다 — 합계가 모자랄 수 있습니다.`);
  }

  return json({
    ok: true,
    title,
    lines,
    notes,
    source: { table: "edu." + table, rows: rows.length, filters },
  });
});
