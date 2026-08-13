// ═══════════════════════════════════════════════════════════════
// 말을 조건으로 옮기는 곳 — DB 도 네트워크도 모른다
//
//   여기에는 조회가 없다. 질문 한 줄과 「자료에 있는 달·거래처」를
//   받아서 기간·항목·거래처를 돌려줄 뿐이다. 그래서 이 파일만 따로
//   떼어 시험할 수 있다 (scripts 없이 node 로 바로 돌아간다).
//
//   못 알아들으면 null 을 준다. 여기서 오늘 날짜나 전체 합계로 슬쩍
//   메우지 않는다 — 메우는 순간 틀린 숫자가 맞는 척 나간다.
// ═══════════════════════════════════════════════════════════════

export type Period =
  | { kind: "month"; value: string; said: string }
  | { kind: "date";  value: string; said: string };

export type Metric = { key: string; label: string; cols: string[]; unit: string };

/* ── 시간 — 표시도 판정도 한국시간 ──────────────────────────────── */
export function kstToday(): string {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}
export function kstMonth(): string {
  return kstToday().slice(0, 7);
}
export function shiftMonth(ym: string, by: number): string {
  const y = Number(ym.slice(0, 4));
  const m = Number(ym.slice(5, 7)) - 1 + by;
  return new Date(Date.UTC(y, m, 1)).toISOString().slice(0, 7);
}
export function shiftDay(iso: string, by: number): string {
  return new Date(Date.parse(iso + "T00:00:00Z") + by * 86400000)
    .toISOString().slice(0, 10);
}

/* ── 항목 — 말과 칸을 잇는 표 ────────────────────────────────────
   순서가 규칙이다. 긴 말이 먼저 와야 한다.
   · 「건수」가 맨 앞 — 「미송금 건수」를 미송금으로 읽으면 안 된다.
     세는 칸은 tx_count 하나뿐이라 헷갈릴 여지가 없다.
   · 「미송금」이 「송금」보다 앞 — 뒤에 두면 미송금이 송금으로 읽힌다. */
export const MONTHLY_METRICS: Array<{ words: string[]; metric: Metric }> = [
  { words: ["건수", "몇건", "횟수"],
    metric: { key: "cnt", label: "송금 건수", cols: ["tx_count"], unit: "건" } },
  { words: ["미통관달러", "미통관usd"],
    metric: { key: "uncl_usd", label: "미통관 달러", cols: ["uncleared_usd_amount"], unit: "USD" } },
  { words: ["미통관위안", "미통관cny", "미통관인민폐"],
    metric: { key: "uncl_cny", label: "미통관 위안", cols: ["uncleared_cny_amount"], unit: "CNY" } },
  { words: ["미통관"],
    metric: { key: "uncl", label: "미통관 금액", cols: ["uncleared_paid_krw"], unit: "원" } },
  { words: ["미송금달러", "미송금usd"],
    metric: { key: "unpaid_usd", label: "미송금 달러", cols: ["unpaid_usd_amount"], unit: "USD" } },
  { words: ["미송금위안", "미송금cny", "미송금인민폐"],
    metric: { key: "unpaid_cny", label: "미송금 위안", cols: ["unpaid_cny_amount"], unit: "CNY" } },
  /* 미송금은 원화 칸이 없다. 달러·위안 두 줄로 답한다. */
  { words: ["미송금"],
    metric: { key: "unpaid", label: "미송금", cols: ["unpaid_usd_amount", "unpaid_cny_amount"], unit: "" } },
  { words: ["달러", "usd"],
    metric: { key: "usd", label: "달러", cols: ["usd_amount"], unit: "USD" } },
  { words: ["위안", "cny", "인민폐"],
    metric: { key: "cny", label: "위안", cols: ["cny_amount"], unit: "CNY" } },
  { words: ["송금액", "송금", "지급액", "지급", "실제송금", "얼마"],
    metric: { key: "paid", label: "실제 송금액", cols: ["paid_krw"], unit: "원" } },
];

export const DEFAULT_MONTHLY: Metric =
  { key: "paid", label: "실제 송금액", cols: ["paid_krw"], unit: "원" };

export const COL_UNIT: Record<string, string> = {
  paid_krw: "원", uncleared_paid_krw: "원", krw: "원",
  usd_amount: "USD", uncleared_usd_amount: "USD", unpaid_usd_amount: "USD",
  cny_amount: "CNY", uncleared_cny_amount: "CNY", unpaid_cny_amount: "CNY",
  tx_count: "건",
  cur_paid_krw: "원", prev_paid_krw: "원", cur_uncl_krw: "원", prev_uncl_krw: "원",
};

export const COL_LABEL: Record<string, string> = {
  paid_krw: "실제 송금액", uncleared_paid_krw: "미통관 금액",
  usd_amount: "달러", cny_amount: "위안",
  uncleared_usd_amount: "미통관 달러", uncleared_cny_amount: "미통관 위안",
  unpaid_usd_amount: "미송금 달러", unpaid_cny_amount: "미송금 위안",
  tx_count: "송금 건수", krw: "원화",
  cur_paid_krw: "이번 달 송금액", prev_paid_krw: "전달 송금액",
  cur_uncl_krw: "이번 달 미통관", prev_uncl_krw: "전달 미통관",
};

export function readMetric(q: string): { metric: Metric; said: string; given: boolean } {
  const flat = q.replace(/\s+/g, "").toLowerCase();
  for (const row of MONTHLY_METRICS) {
    const w = row.words.find((x) => flat.includes(x));
    if (w) return { metric: row.metric, said: w, given: true };
  }
  return { metric: DEFAULT_MONTHLY, said: "", given: false };
}

/* ── 기간 ────────────────────────────────────────────────────────
   「7월」처럼 연도가 없으면 그 달이 실제로 있는 해 중 가장 나중 것을
   고른다. 올해를 붙여 버리면 자료에 없는 달을 물어본 셈이 된다. */
export function readPeriod(q: string, monthsInData: string[]): Period | null {
  const t = q.replace(/\s+/g, "");

  let m = t.match(/(20\d{2})[-./](\d{1,2})[-./](\d{1,2})/);
  if (m) {
    return { kind: "date", said: m[0],
      value: `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}` };
  }

  m = t.match(/(20\d{2})년?[-./]?(\d{1,2})월(\d{1,2})일/);
  if (m) {
    return { kind: "date", said: m[0],
      value: `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}` };
  }

  if (/오늘|금일/.test(t)) return { kind: "date", value: kstToday(), said: "오늘" };
  if (/어제|전일/.test(t)) return { kind: "date", value: shiftDay(kstToday(), -1), said: "어제" };

  m = t.match(/(20\d{2})[-./](\d{1,2})(?!\d)/);
  if (m) return { kind: "month", value: `${m[1]}-${m[2].padStart(2, "0")}`, said: m[0] };

  m = t.match(/(20\d{2})년?(\d{1,2})월/);
  if (m) return { kind: "month", value: `${m[1]}-${m[2].padStart(2, "0")}`, said: m[0] };

  if (/지난달|저번달|전달|지난월/.test(t))
    return { kind: "month", value: shiftMonth(kstMonth(), -1), said: "지난달" };
  if (/이번달|이달|금월|당월/.test(t))
    return { kind: "month", value: kstMonth(), said: "이번 달" };

  m = t.match(/(?:^|[^0-9])(\d{1,2})월/);
  if (m) {
    const mm = m[1].padStart(2, "0");
    const hit = monthsInData.filter((x) => x.slice(5, 7) === mm).sort();
    return { kind: "month", said: `${m[1]}월`,
      value: hit.length ? hit[hit.length - 1] : `${kstMonth().slice(0, 4)}-${mm}` };
  }

  return null;
}

/* ── 거래처 — 실제로 표에 있는 이름하고만 맞춘다 ──────────────────
   「스타위그-스퀘어」는 앞으로도 뒤로도 불리고, 「관리용품(공장)」은
   「관리용품」으로 불린다. 그래서 토막을 전부 후보로 둔다.
   둘 이상 걸리면 고르지 않고 되묻는다 — 아무거나 고르면 틀린
   거래처의 숫자가 맞는 척 나간다. */
export const norm = (s: string): string =>
  s.replace(/[\s\-_()]/g, "").toLowerCase();

export function partsOf(v: string): string[] {
  return v.split(/[-_/()]/).map(norm).filter((s) => s.length >= 2);
}

export function readVendor(q: string, vendors: string[]): { hit: string[]; used: string } {
  const t = norm(q);

  const full = vendors.filter((v) => norm(v).length >= 2 && t.includes(norm(v)));
  if (full.length === 1) return { hit: full, used: full[0] };
  if (full.length > 1) return { hit: full, used: "" };

  const part = vendors.filter((v) => partsOf(v).some((p) => t.includes(p)));
  if (part.length === 1) return { hit: part, used: part[0] };
  return { hit: part, used: "" };      // 0 이면 못 찾음, 2 이상이면 되묻는다
}

/* ── 남은 말 ─────────────────────────────────────────────────────
   기간·항목으로 설명되지 않고 남은 말이 있는지 본다. 남았는데
   거래처를 못 찾았으면, 그 달 전체 합계를 주는 대신 모른다고 한다.
   합계를 주면 「7월 없는거래처 송금액」이 그 달 총액으로 답한다. */
const STOP = new Set([
  "얼마", "얼마야", "얼마인가요", "인가", "인가요", "이야", "나요", "인지",
  "알려줘", "알려", "보여줘", "보여", "말해줘", "궁금", "구해줘", "계산",
  "데이터", "숫자", "리포트", "데일리", "일일", "기준선", "베이스라인",
  "건별", "사유", "예정일", "우리", "회사", "그리고", "얼마나",
  "총액", "합계", "전체", "모두", "다해서", "까지", "부터", "정도",
  /* 기간을 가리키는 말 — 붙여 쓰든 띄어 쓰든 여기서 걸러진다 */
  "이번달", "이달", "금월", "당월", "지난달", "저번달", "전달", "지난월",
  "오늘", "금일", "어제", "전일", "이번", "지난", "저번",
]);

export function leftoverWords(q: string, eaten: string[]): string[] {
  let t = " " + q + " ";

  /* 날짜 꼴을 먼저 지운다. 「이번 달」처럼 띄어 쓴 말은 STOP 이 맡는다. */
  t = t.replace(/20\d{2}\s*[년\-./]\s*\d{1,2}\s*[월\-./]?\s*(\d{1,2}\s*일?)?/g, " ");
  t = t.replace(/\d{1,2}\s*월/g, " ").replace(/\d{1,2}\s*일/g, " ");

  for (const e of eaten) {
    if (!e) continue;
    t = t.split(e).join(" ");
  }

  return t
    .split(/[^0-9A-Za-z가-힣]+/)
    .map((w) => w.trim())
    .filter((w) => w.length >= 2 && !/^\d+$/.test(w) && !STOP.has(w));
}

/* ── 어느 표에 물어볼지 ──────────────────────────────────────────
   여기 없는 이름은 어떤 질문으로도 닿지 않는다. */
export const TABLES = {
  monthly:  "edu_elaina_overseasremittance",
  baseline: "elaina_monthly_baseline",
  daily:    "elaina_daily_reports",
  each:     "elaina_remittances",
} as const;

export function readTable(q: string): string {
  const flat = q.replace(/\s+/g, "");
  if (/기준선|베이스라인|baseline/i.test(flat)) return TABLES.baseline;
  if (/건별|사유|예정일/.test(flat)) return TABLES.each;
  if (/리포트|데일리|일일/.test(flat)) return TABLES.daily;
  return TABLES.monthly;
}

/* ── 합계 — 줄이 없거나 칸이 비면 null. 0 으로 바꾸지 않는다 ────── */
export function sumCol(rows: Record<string, unknown>[], col: string): number | null {
  let any = false;
  let s = 0;
  for (const r of rows) {
    const v = r[col];
    if (v === null || v === undefined) continue;
    const n = Number(v);
    if (!isFinite(n)) continue;
    any = true;
    s += n;
  }
  return any ? s : null;
}
