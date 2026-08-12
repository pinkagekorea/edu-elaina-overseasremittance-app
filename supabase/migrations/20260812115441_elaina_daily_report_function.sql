-- ═══════════════════════════════════════════════════════════════
-- 데일리 리포트 — 하루치 한 줄을 만든다
--
--   규칙만 있다. 합계와 뺄셈뿐이고 판단하는 자리는 없다.
--     이번 달 = p_date 가 속한 달 (달력 기준)
--     전달    = 그 한 달 전
--   그 달 행이 원본에 없으면 0 이다 — 0 도 사실이다.
--
--   무엇이 터지든 exception 이 받아 status='error' 한 줄을 남긴다.
--   실패도 리포트다. 줄이 없는 것(= cron 이 아예 안 돎)과 구분되어야 한다.
-- ═══════════════════════════════════════════════════════════════

create or replace function edu.elaina_build_daily_report(
  p_date date default (now() at time zone 'Asia/Seoul')::date
)
returns edu.elaina_daily_reports
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cur       text := to_char(p_date, 'YYYY-MM');
  v_prev      text := to_char((p_date - interval '1 month')::date, 'YYYY-MM');
  v_cur_paid  numeric := 0;
  v_prev_paid numeric := 0;
  v_cur_uncl  numeric := 0;
  v_prev_uncl numeric := 0;
  v_row       edu.elaina_daily_reports;
begin
  begin
    select coalesce(sum(t.paid_krw)           filter (where t.remit_month = v_cur),  0),
           coalesce(sum(t.paid_krw)           filter (where t.remit_month = v_prev), 0),
           coalesce(sum(t.uncleared_paid_krw) filter (where t.remit_month = v_cur),  0),
           coalesce(sum(t.uncleared_paid_krw) filter (where t.remit_month = v_prev), 0)
      into v_cur_paid, v_prev_paid, v_cur_uncl, v_prev_uncl
      from edu.edu_elaina_overseasremittance t
     where t.remit_month in (v_cur, v_prev);

    insert into edu.elaina_daily_reports as d (
      report_date, generated_at, cur_month, prev_month,
      cur_paid_krw, prev_paid_krw, cur_uncl_krw, prev_uncl_krw,
      status, error_text
    )
    values (
      p_date, now(), v_cur, v_prev,
      v_cur_paid, v_prev_paid, v_cur_uncl, v_prev_uncl,
      'ok', null
    )
    on conflict (report_date) do update set
      generated_at  = excluded.generated_at,
      cur_month     = excluded.cur_month,
      prev_month    = excluded.prev_month,
      cur_paid_krw  = excluded.cur_paid_krw,
      prev_paid_krw = excluded.prev_paid_krw,
      cur_uncl_krw  = excluded.cur_uncl_krw,
      prev_uncl_krw = excluded.prev_uncl_krw,
      status        = 'ok',
      error_text    = null
    returning d.* into v_row;

  exception when others then
    -- 여기 오면 위 블록의 변경은 이미 되돌아가 있다. 실패 자체를 한 줄로 남긴다.
    insert into edu.elaina_daily_reports as d (
      report_date, generated_at, cur_month, prev_month, status, error_text
    )
    values (
      p_date, now(), v_cur, v_prev, 'error',
      left(coalesce(nullif(sqlerrm, ''), '알 수 없는 오류') || ' (' || sqlstate || ')', 1000)
    )
    on conflict (report_date) do update set
      generated_at = excluded.generated_at,
      status       = 'error',
      error_text   = excluded.error_text
    returning d.* into v_row;
  end;

  return v_row;
end
$$;

comment on function edu.elaina_build_daily_report(date) is
  '하루치 데일리 리포트 한 줄을 만든다(있으면 덮어쓴다). 매일 09:00 KST 에 pg_cron 이 부른다.';

-- 사람이 부를 일이 없다. cron(postgres) 만 부른다.
revoke all on function edu.elaina_build_daily_report(date) from public, anon, authenticated;

notify pgrst, 'reload schema';
