-- ═══════════════════════════════════════════════════════════════
-- 데일리 리포트 — 아침 9시의 숫자를 하루 한 줄로 쌓는다
--   설계: docs/superpowers/specs/2026-08-12-elaina-daily-report-design.md
--
--   화면은 이 표만 읽는다. 원본을 다시 집계하지 않는다 —
--   과거 날짜를 고르면 "그날 아침의 숫자" 가 그대로 나와야 하기 때문이다.
--
--   증감(차이·%)은 저장하지 않는다. 네 숫자만 두고 뺄셈은 화면이 한다.
--   저장된 차이와 보이는 차이가 어긋날 자리를 만들지 않는다.
-- ═══════════════════════════════════════════════════════════════

create table if not exists edu.elaina_daily_reports (
  report_date   date        primary key,
  generated_at  timestamptz not null default now(),

  cur_month     text        not null,
  prev_month    text        not null,

  cur_paid_krw  numeric     not null default 0,
  prev_paid_krw numeric     not null default 0,
  cur_uncl_krw  numeric     not null default 0,
  prev_uncl_krw numeric     not null default 0,

  -- 실패도 리포트다. 줄이 없는 것과 error 인 것은 다른 사고다.
  status        text        not null default 'ok',
  error_text    text,

  constraint elaina_daily_status_val check (status in ('ok','error')),
  constraint elaina_daily_month_fmt  check (cur_month  ~ '^\d{4}-\d{2}$'
                                        and prev_month ~ '^\d{4}-\d{2}$'),
  constraint elaina_daily_err_len    check (error_text is null or length(error_text) <= 1000)
);

comment on table edu.elaina_daily_reports is
  '데일리 리포트 스냅샷. 매일 09:00(KST) pg_cron 이 한 줄 쌓는다. 화면은 읽기만 한다.';
comment on column edu.elaina_daily_reports.report_date is
  '한국시간 기준 날짜. 하루 한 줄이라 PK 다 — 같은 날 다시 돌면 덮어쓴다.';
comment on column edu.elaina_daily_reports.generated_at is
  '실제로 만들어진 시각. 제목 옆에 이 값을 찍는다.';
comment on column edu.elaina_daily_reports.cur_month is
  '달력 기준 이번 달(YYYY-MM). 데이터에 그 달 행이 없으면 금액은 0 이다.';
comment on column edu.elaina_daily_reports.cur_paid_krw is
  '원본 paid_krw 합 = 화면의 「실제 송금액(원)」.';
comment on column edu.elaina_daily_reports.cur_uncl_krw is
  '원본 uncleared_paid_krw 합 = 화면의 「미통관 금액(원)」.';
comment on column edu.elaina_daily_reports.status is
  'ok 정상 · error 생성 중 예외. error 면 error_text 에 사유가 있다.';

-- ── 잠금 ───────────────────────────────────────────────────────
alter table edu.elaina_daily_reports enable row level security;

revoke all on edu.elaina_daily_reports from anon, authenticated, public;

-- insert/update/delete 는 일부러 주지 않는다. 쓰는 것은 생성 함수뿐이다.
grant select on edu.elaina_daily_reports to authenticated;

-- 읽기 규칙은 원본 표와 같은 줄을 쓴다. 요약이 원본보다 넓게 보이면 안 된다.
drop policy if exists elaina_daily_select on edu.elaina_daily_reports;
create policy elaina_daily_select on edu.elaina_daily_reports
  for select to authenticated
  using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@pinkage.co.kr');

notify pgrst, 'reload schema';
