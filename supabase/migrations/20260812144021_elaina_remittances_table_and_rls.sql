-- ═══════════════════════════════════════════════════════════════
-- 송금 건별 표 — 주간회의 화면의 근거
--   설계: docs/superpowers/specs/2026-08-12-elaina-weekly-meeting-design.md
--
--   원본 월별 표에는 송금일이 없다 (remit_month 가 'YYYY-MM' 텍스트뿐이고
--   한 행이 월×업체 합계다). 주 단위로 보려면 건별로 쌓는 수밖에 없다.
--
--   주 배정은 생성 컬럼 한 줄이 정한다:
--     week_date = coalesce(paid_date, due_date)
--     보냈으면 보낸 날, 못 보냈으면 보내기로 했던 날.
--   DB 가 계산하므로 화면과 어긋날 수 없다.
-- ═══════════════════════════════════════════════════════════════

create table if not exists edu.elaina_remittances (
  id            bigint generated always as identity primary key,

  vendor_name   text    not null,
  currency      text    not null,
  amount        numeric not null,          -- 외화
  krw           numeric,                   -- paid 면 필수 (월별 표에 넣을 값)

  due_date      date    not null,          -- 예정 송금일
  paid_date     date,                      -- 실제 송금일 (unpaid 면 없음)

  status        text    not null default 'unpaid',

  -- 미송금일 때 회의에서 채우는 칸
  unpaid_reason text,
  expected_date date,

  note          text,

  -- 주 배정의 유일한 근거
  week_date     date generated always as (coalesce(paid_date, due_date)) stored,

  -- 트리거가 찍는다. 화면이 무엇을 보내도 덮어쓴다.
  created_by    uuid        references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_by    uuid        references auth.users(id),
  updated_at    timestamptz not null default now(),

  constraint elaina_remit_currency   check (currency in ('USD','CNY')),
  constraint elaina_remit_amount     check (amount > 0),
  constraint elaina_remit_status     check (status in ('paid','unpaid')),
  -- 보냈다면 보낸 날과 원화가 있어야 하고, 못 보냈다면 보낸 날이 없어야 한다
  constraint elaina_remit_shape      check (
    (status = 'paid'   and paid_date is not null and krw is not null and krw > 0) or
    (status = 'unpaid' and paid_date is null)
  ),
  constraint elaina_remit_vendor_len check (length(btrim(vendor_name)) between 1 and 100),
  constraint elaina_remit_reason_len check (unpaid_reason is null or length(unpaid_reason) <= 500),
  constraint elaina_remit_note_len   check (note is null or length(note) <= 500)
);

comment on table edu.elaina_remittances is
  '송금 건별 기록. 주간회의 화면의 근거이고, 트리거가 월별 표(기준선+건별합)를 다시 계산한다.';
comment on column edu.elaina_remittances.week_date is
  '주 배정의 유일한 근거 = coalesce(paid_date, due_date). DB 가 계산한다.';
comment on column edu.elaina_remittances.krw is
  'paid 면 필수. 월별 표의 「실제 송금액(원)」에 합산되는 값이다.';
comment on column edu.elaina_remittances.unpaid_reason is
  '미송금 사유. 회의에서 적는다.';
comment on column edu.elaina_remittances.expected_date is
  '예상 송금일. 회의에서 적는다.';

create index if not exists elaina_remit_week_idx   on edu.elaina_remittances (week_date desc);
create index if not exists elaina_remit_status_idx on edu.elaina_remittances (status, week_date desc);
-- 동기화가 (업체, 그 달) 로 훑는다. to_char 는 IMMUTABLE 이 아니라 색인에 못 쓰므로
-- 날짜 범위로 훑도록 (업체, 송금일) 로 건다.
create index if not exists elaina_remit_vendor_paid_idx
  on edu.elaina_remittances (vendor_name, paid_date);

-- ── 잠금 ───────────────────────────────────────────────────────
alter table edu.elaina_remittances enable row level security;

revoke all on edu.elaina_remittances from anon, authenticated, public;

-- DELETE 는 일부러 주지 않는다. 잘못 넣은 건은 관리자 함수로만 지운다.
grant select, insert, update on edu.elaina_remittances to authenticated;

-- 읽기·쓰기 모두 원본 표와 같은 줄을 쓴다. 요약이 원본보다 넓게 보이면 안 된다.
drop policy if exists elaina_remit_select on edu.elaina_remittances;
create policy elaina_remit_select on edu.elaina_remittances
  for select to authenticated
  using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@pinkage.co.kr');

drop policy if exists elaina_remit_insert on edu.elaina_remittances;
create policy elaina_remit_insert on edu.elaina_remittances
  for insert to authenticated
  with check (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@pinkage.co.kr');

drop policy if exists elaina_remit_update on edu.elaina_remittances;
create policy elaina_remit_update on edu.elaina_remittances
  for update to authenticated
  using      (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@pinkage.co.kr')
  with check (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@pinkage.co.kr');

-- ── 작성자·시각은 트리거가 찍는다 ──────────────────────────────
create or replace function edu.elaina_remit_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    new.created_by := v_uid;
    new.created_at := now();
    new.updated_by := v_uid;
    new.updated_at := now();
    return new;
  end if;

  -- 남긴 뒤에도 고칠 수 있지만(회의 중 사유를 적는다), 처음 기록은 남는다
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  new.updated_by := v_uid;
  new.updated_at := now();
  return new;
end
$$;

drop trigger if exists elaina_remit_stamp_trg on edu.elaina_remittances;
create trigger elaina_remit_stamp_trg
  before insert or update on edu.elaina_remittances
  for each row execute function edu.elaina_remit_stamp();

revoke all on function edu.elaina_remit_stamp() from public, anon, authenticated;

notify pgrst, 'reload schema';
