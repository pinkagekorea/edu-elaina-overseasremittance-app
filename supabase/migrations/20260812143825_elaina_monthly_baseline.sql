-- ═══════════════════════════════════════════════════════════════
-- 기준선 — 지금 월별 표의 사본. 딱 한 번 찍는다.
--   설계: docs/superpowers/specs/2026-08-12-elaina-weekly-meeting-design.md
--
--   왜 필요한가: 건별 표는 비어 있는 채로 시작하는데 월별 표에는 이미
--   8개월치가 있다. 모집단이 다르다.
--     · 월별표를 건별합으로 덮으면 → 과거가 0 이 된다
--     · 건별합을 월별표에 더하면  → 트리거가 두 번 돌 때마다 불어난다
--   기준선을 두면 「기준선 + 건별합」이 언제나 같은 값을 낸다 (멱등).
--
--   되돌리기의 근거이기도 하다. 문제가 생기면 이 표를 월별 표에 되쓴다.
-- ═══════════════════════════════════════════════════════════════

create table if not exists edu.elaina_monthly_baseline (
  remit_month          text        not null,
  vendor_name          text        not null,

  tx_count             integer     not null default 0,
  usd_amount           numeric     not null default 0,
  cny_amount           numeric     not null default 0,
  paid_krw             numeric     not null default 0,

  -- 건별 표에 통관 정보가 없어 트리거가 손대지 않는 칸들. 사본으로만 둔다.
  uncleared_usd_amount numeric     not null default 0,
  uncleared_cny_amount numeric     not null default 0,
  uncleared_paid_krw   numeric     not null default 0,
  unpaid_usd_amount    numeric     not null default 0,
  unpaid_cny_amount    numeric     not null default 0,

  captured_at          timestamptz not null default now(),

  primary key (remit_month, vendor_name)
);

comment on table edu.elaina_monthly_baseline is
  '월별 표를 건별 표와 맞추기 위한 기준선(사본). 월별표 = 기준선 + 건별합(paid).';

-- 한 번만 찍는다. 이미 있으면 그대로 둔다 — 다시 찍으면 이미 합산된 값을
-- 기준선으로 삼아 버려서 이중 계상이 된다.
insert into edu.elaina_monthly_baseline (
  remit_month, vendor_name, tx_count, usd_amount, cny_amount, paid_krw,
  uncleared_usd_amount, uncleared_cny_amount, uncleared_paid_krw,
  unpaid_usd_amount, unpaid_cny_amount
)
select t.remit_month, t.vendor_name,
       coalesce(t.tx_count, 0), coalesce(t.usd_amount, 0),
       coalesce(t.cny_amount, 0), coalesce(t.paid_krw, 0),
       coalesce(t.uncleared_usd_amount, 0), coalesce(t.uncleared_cny_amount, 0),
       coalesce(t.uncleared_paid_krw, 0),
       coalesce(t.unpaid_usd_amount, 0), coalesce(t.unpaid_cny_amount, 0)
  from edu.edu_elaina_overseasremittance t
 where t.remit_month is not null and t.vendor_name is not null
on conflict (remit_month, vendor_name) do nothing;

-- ── 잠금 ───────────────────────────────────────────────────────
alter table edu.elaina_monthly_baseline enable row level security;
revoke all on edu.elaina_monthly_baseline from anon, authenticated, public;

-- 화면은 기준선을 볼 일이 없다. 트리거(postgres)만 쓴다.
-- 정책을 하나도 만들지 않으므로 RLS 가 authenticated 의 모든 접근을 막는다.

notify pgrst, 'reload schema';
