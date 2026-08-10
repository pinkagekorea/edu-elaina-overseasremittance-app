-- ═══════════════════════════════════════════════════════════════
-- 서랍 — 화면이 부르는 함수들 + 명단 초기값
-- ═══════════════════════════════════════════════════════════════

-- ── @ 자동완성 목록 ────────────────────────────────────────────
-- 명단 표는 아무에게도 열지 않는다. 이름은 이 함수로만 나간다.
-- 이메일은 돌려주지 않는다 — 계정 목록이 새면 안 된다.
create or replace function edu.elaina_mention_list()
returns table (user_id uuid, display_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select v.user_id, v.display_name
    from edu.elaina_viewers v
   where edu.elaina_can_view(auth.uid())     -- 명단 밖 사람에게는 빈 결과
   order by v.display_name;
$$;

comment on function edu.elaina_mention_list() is
  '@ 자동완성용 이름 목록. 명단에 있는 사람에게만 응답하고 이메일은 내보내지 않는다.';

-- ── 배지 건수 (여러 대상을 한 번에) ────────────────────────────
-- security invoker → RLS 가 그대로 적용된다. 못 보는 사람은 0건을 본다.
create or replace function edu.elaina_memo_counts(
  p_target_type text,
  p_target_ids  text[]
)
returns table (target_id text, memo_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select m.target_id, count(*)
    from edu.elaina_memos m
   where m.deleted_at is null
     and m.target_type = p_target_type
     and m.target_id = any(p_target_ids)
   group by m.target_id;
$$;

comment on function edu.elaina_memo_counts(text, text[]) is
  '서랍 배지에 쓸 살아 있는 메모 건수. 대상 여러 개를 한 번에 센다.';

-- ── 명단 관리 (관리자 전용) ────────────────────────────────────
create or replace function edu.elaina_set_viewer(p_email text, p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid;
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_name   text := btrim(coalesce(p_display_name, ''));
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 명단을 바꿀 수 있습니다.' using errcode = '42501';
  end if;

  select u.id into v_target from auth.users u
   where lower(u.email) = v_email and u.deleted_at is null;
  if v_target is null then
    raise exception '그런 계정이 없습니다: %', v_email using errcode = '22023';
  end if;

  if v_name = '' then v_name := split_part(v_email, '@', 1); end if;

  insert into edu.elaina_viewers (user_id, email, display_name, added_by)
       values (v_target, v_email, v_name, auth.uid())
  on conflict (user_id) do update set display_name = excluded.display_name;

  return jsonb_build_object('user_id', v_target, 'email', v_email, 'display_name', v_name);
end
$$;

create or replace function edu.elaina_remove_viewer(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 명단을 바꿀 수 있습니다.' using errcode = '42501';
  end if;

  select v.email into v_email from edu.elaina_viewers v where v.user_id = p_user_id;
  if v_email is null then
    raise exception '명단에 없는 사람입니다.' using errcode = '22023';
  end if;
  if v_email = 'elaina@pinkage.co.kr' then
    raise exception '관리자는 명단에서 뺄 수 없습니다.' using errcode = '42501';
  end if;

  delete from edu.elaina_viewers where user_id = p_user_id;
  return jsonb_build_object('removed', p_user_id, 'email', v_email);
end
$$;

-- ── 실행 권한 — anon 에는 아무것도 주지 않는다 ─────────────────
revoke all on function edu.elaina_mention_list()                 from public, anon;
revoke all on function edu.elaina_memo_counts(text, text[])      from public, anon;
revoke all on function edu.elaina_set_viewer(text, text)         from public, anon;
revoke all on function edu.elaina_remove_viewer(uuid)            from public, anon;

grant execute on function edu.elaina_mention_list()              to authenticated, service_role;
grant execute on function edu.elaina_memo_counts(text, text[])   to authenticated, service_role;
grant execute on function edu.elaina_set_viewer(text, text)      to authenticated, service_role;
grant execute on function edu.elaina_remove_viewer(uuid)         to authenticated, service_role;

-- ── 명단 초기값 ────────────────────────────────────────────────
-- 활성 계정을 전부 넣는다. 교육용 공용 프로젝트라 아무도 잠기지 않게 한다.
-- 표시 이름은 이메일 앞부분. 겹치는 사람은 건너뛴다.
-- 관리자는 elaina_remove_viewer() 로 언제든 뺄 수 있다.
insert into edu.elaina_viewers (user_id, email, display_name, added_by)
select u.id,
       lower(u.email),
       split_part(lower(u.email), '@', 1),
       (select u2.id from auth.users u2 where lower(u2.email) = 'elaina@pinkage.co.kr')
  from auth.users u
 where u.deleted_at is null
   and u.email is not null
   and not exists (select 1 from edu.elaina_viewers v where v.user_id = u.id)
   and not exists (select 1 from edu.elaina_viewers v2
                    where v2.display_name = split_part(lower(u.email), '@', 1))
on conflict do nothing;

notify pgrst, 'reload schema';