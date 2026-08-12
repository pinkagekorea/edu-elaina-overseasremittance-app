-- ═══════════════════════════════════════════════════════════════
-- 두 표를 맞춘다 — 월별표(월,업체) = 기준선(월,업체) + Σ 건별(paid)
--
--   식이 항상 같은 값을 낸다 (멱등). 그래서 트리거가 몇 번 돌아도,
--   같은 건을 여러 번 고쳐도 값이 불어나지 않는다.
--
--   미송금 건은 넣지 않는다 — 「실제 송금액」은 실제로 나간 돈이다.
--   미통관(uncleared_*)·미송금(unpaid_*)은 건별 표에 정보가 없으므로
--   기준선 값을 그대로 둔다. 없는 값을 지어내지 않는다.
-- ═══════════════════════════════════════════════════════════════

create or replace function edu.elaina_sync_month(p_month text, p_vendor text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start date;
  v_end   date;

  v_b_tx    integer := 0;  v_b_usd numeric := 0;  v_b_cny numeric := 0;  v_b_krw numeric := 0;
  v_b_uusd  numeric := 0;  v_b_ucny numeric := 0; v_b_ukrw numeric := 0;
  v_b_nusd  numeric := 0;  v_b_ncny numeric := 0;
  v_has_baseline boolean := false;

  v_s_tx  integer := 0;  v_s_usd numeric := 0;  v_s_cny numeric := 0;  v_s_krw numeric := 0;
begin
  if p_month is null or p_vendor is null then return; end if;
  if p_month !~ '^\d{4}-\d{2}$' then return; end if;

  v_start := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_end   := (v_start + interval '1 month')::date;

  -- 건별 합계 (보낸 것만). 날짜 범위로 훑어야 색인을 탄다.
  select count(*),
         coalesce(sum(r.amount) filter (where r.currency = 'USD'), 0),
         coalesce(sum(r.amount) filter (where r.currency = 'CNY'), 0),
         coalesce(sum(r.krw), 0)
    into v_s_tx, v_s_usd, v_s_cny, v_s_krw
    from edu.elaina_remittances r
   where r.status = 'paid'
     and r.vendor_name = p_vendor
     and r.paid_date >= v_start
     and r.paid_date <  v_end;

  -- 기준선
  select true, b.tx_count, b.usd_amount, b.cny_amount, b.paid_krw,
         b.uncleared_usd_amount, b.uncleared_cny_amount, b.uncleared_paid_krw,
         b.unpaid_usd_amount, b.unpaid_cny_amount
    into v_has_baseline, v_b_tx, v_b_usd, v_b_cny, v_b_krw,
         v_b_uusd, v_b_ucny, v_b_ukrw, v_b_nusd, v_b_ncny
    from edu.elaina_monthly_baseline b
   where b.remit_month = p_month and b.vendor_name = p_vendor;

  if not found then
    v_has_baseline := false;
    v_b_tx := 0; v_b_usd := 0; v_b_cny := 0; v_b_krw := 0;
    v_b_uusd := 0; v_b_ucny := 0; v_b_ukrw := 0; v_b_nusd := 0; v_b_ncny := 0;
  end if;

  -- 기준선에도 없고 건별도 없다 = 원래 없던 행이다. 남겨 둘 이유가 없다.
  if not v_has_baseline and v_s_tx = 0 then
    delete from edu.edu_elaina_overseasremittance
     where remit_month = p_month and vendor_name = p_vendor;
    return;
  end if;

  insert into edu.edu_elaina_overseasremittance as t (
    remit_month, vendor_name, tx_count, usd_amount, cny_amount, paid_krw,
    uncleared_usd_amount, uncleared_cny_amount, uncleared_paid_krw,
    unpaid_usd_amount, unpaid_cny_amount, updated_at
  ) values (
    p_month, p_vendor,
    v_b_tx  + v_s_tx,
    v_b_usd + v_s_usd,
    v_b_cny + v_s_cny,
    v_b_krw + v_s_krw,
    v_b_uusd, v_b_ucny, v_b_ukrw, v_b_nusd, v_b_ncny, now()
  )
  on conflict (remit_month, vendor_name) do update set
    tx_count             = excluded.tx_count,
    usd_amount           = excluded.usd_amount,
    cny_amount           = excluded.cny_amount,
    paid_krw             = excluded.paid_krw,
    uncleared_usd_amount = excluded.uncleared_usd_amount,
    uncleared_cny_amount = excluded.uncleared_cny_amount,
    uncleared_paid_krw   = excluded.uncleared_paid_krw,
    unpaid_usd_amount    = excluded.unpaid_usd_amount,
    unpaid_cny_amount    = excluded.unpaid_cny_amount,
    updated_at           = now();
end
$$;

comment on function edu.elaina_sync_month(text, text) is
  '월별 표의 (월,업체) 한 칸을 「기준선 + 건별합(paid)」 으로 다시 계산한다. 멱등.';

-- ── 트리거 — 옛 조합과 새 조합을 둘 다 다시 계산한다 ───────────
create or replace function edu.elaina_remit_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 업체나 송금일을 고쳤을 수 있다. 떠난 칸도 다시 계산해야 한다.
  if tg_op in ('UPDATE','DELETE') and old.paid_date is not null then
    perform edu.elaina_sync_month(to_char(old.paid_date, 'YYYY-MM'), old.vendor_name);
  end if;

  if tg_op in ('INSERT','UPDATE') and new.paid_date is not null then
    perform edu.elaina_sync_month(to_char(new.paid_date, 'YYYY-MM'), new.vendor_name);
  end if;

  return null;    -- AFTER 트리거
end
$$;

drop trigger if exists elaina_remit_sync_trg on edu.elaina_remittances;
create trigger elaina_remit_sync_trg
  after insert or update or delete on edu.elaina_remittances
  for each row execute function edu.elaina_remit_sync();

-- ── 잘못 넣은 건 지우기 — 관리자만 ─────────────────────────────
--    표에 DELETE 권한을 주지 않았으므로 지우는 길은 이 함수뿐이다.
--    지우면 위 트리거가 월별 표를 다시 계산한다.
create or replace function edu.elaina_delete_remittance(p_id bigint)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_n integer;
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 송금 기록을 지울 수 있습니다.' using errcode = '42501';
  end if;
  delete from edu.elaina_remittances where id = p_id;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

revoke all on function edu.elaina_delete_remittance(bigint) from public, anon;
grant execute on function edu.elaina_delete_remittance(bigint) to authenticated;

-- ── 되돌리기 — 월별 표를 기준선 그대로 복원 ────────────────────
--    비상용이다. 화면에서 부를 일이 없으므로 아무에게도 실행권을 주지 않는다
--    (postgres / service_role 만 부를 수 있다).
create or replace function edu.elaina_restore_monthly_from_baseline()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_n integer;
begin
  delete from edu.edu_elaina_overseasremittance t
   where not exists (
     select 1 from edu.elaina_monthly_baseline b
      where b.remit_month = t.remit_month and b.vendor_name = t.vendor_name);

  insert into edu.edu_elaina_overseasremittance as t (
    remit_month, vendor_name, tx_count, usd_amount, cny_amount, paid_krw,
    uncleared_usd_amount, uncleared_cny_amount, uncleared_paid_krw,
    unpaid_usd_amount, unpaid_cny_amount, updated_at
  )
  select b.remit_month, b.vendor_name, b.tx_count, b.usd_amount, b.cny_amount, b.paid_krw,
         b.uncleared_usd_amount, b.uncleared_cny_amount, b.uncleared_paid_krw,
         b.unpaid_usd_amount, b.unpaid_cny_amount, now()
    from edu.elaina_monthly_baseline b
  on conflict (remit_month, vendor_name) do update set
    tx_count             = excluded.tx_count,
    usd_amount           = excluded.usd_amount,
    cny_amount           = excluded.cny_amount,
    paid_krw             = excluded.paid_krw,
    uncleared_usd_amount = excluded.uncleared_usd_amount,
    uncleared_cny_amount = excluded.uncleared_cny_amount,
    uncleared_paid_krw   = excluded.uncleared_paid_krw,
    unpaid_usd_amount    = excluded.unpaid_usd_amount,
    unpaid_cny_amount    = excluded.unpaid_cny_amount,
    updated_at           = now();

  get diagnostics v_n = row_count;
  return v_n;
end
$$;

comment on function edu.elaina_restore_monthly_from_baseline() is
  '비상용. 월별 표를 기준선 사본 그대로 되돌린다. postgres/service_role 만 부를 수 있다.';

revoke all on function edu.elaina_restore_monthly_from_baseline() from public, anon, authenticated;
revoke all on function edu.elaina_sync_month(text, text) from public, anon, authenticated;
revoke all on function edu.elaina_remit_sync() from public, anon, authenticated;

notify pgrst, 'reload schema';
