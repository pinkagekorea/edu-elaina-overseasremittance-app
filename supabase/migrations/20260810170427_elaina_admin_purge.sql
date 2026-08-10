-- ═══════════════════════════════════════════════════════════════
-- 관리자만: 이미 지운 글을 완전히 치운다
--
--   지금까지 하드 삭제는 아무도 못 했다(authenticated 에 DELETE 권한 없음).
--   그래서 지운 메모가 '지워진 메모입니다' 비석으로 계속 쌓인다.
--   관리자에게만 치우는 길을 연다.
--
--   DELETE 권한은 여전히 아무에게도 주지 않는다. 이 함수가
--   SECURITY DEFINER 라 소유자 권한으로만 지운다 —
--   즉 REST 로 표를 직접 DELETE 하는 길은 그대로 막혀 있다.
--
--   안전장치 두 개:
--     · 관리자만 (edu.elaina_is_admin)
--     · 이미 소프트 삭제된 것만. 살아 있는 글은 못 지운다
--       → '지우기 → 확인 → 완전 삭제' 두 단계를 강제한다
--
--   답글·멘션·알림은 외래키 ON DELETE CASCADE 로 함께 사라진다.
--   캡처는 SQL 로 못 지우므로 경로를 돌려주고 화면이 Storage API 로 치운다.
-- ═══════════════════════════════════════════════════════════════

create or replace function edu.elaina_purge_memo(p_memo_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dead    timestamptz;
  v_paths   text[];
  v_replies int;
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 완전 삭제할 수 있습니다.' using errcode = '42501';
  end if;

  select m.deleted_at into v_dead from edu.elaina_memos m where m.id = p_memo_id;
  if not found then
    raise exception '그런 메모가 없습니다.' using errcode = '22023';
  end if;
  if v_dead is null then
    raise exception '먼저 지운 메모만 완전 삭제할 수 있습니다.' using errcode = '42501';
  end if;

  -- 메모와 딸린 답글에 붙은 캡처 경로를 한 번에 모은다
  select coalesce(array_agg(distinct t.p), '{}') into v_paths
    from (
      select unnest(m.image_paths) as p from edu.elaina_memos m where m.id = p_memo_id
      union all
      select unnest(r.image_paths)      from edu.elaina_memo_replies r where r.memo_id = p_memo_id
    ) t
   where t.p is not null;

  select count(*) into v_replies from edu.elaina_memo_replies where memo_id = p_memo_id;

  delete from edu.elaina_memos where id = p_memo_id;   -- 답글·멘션·알림 CASCADE

  return jsonb_build_object('memo_id', p_memo_id,
                            'replies', v_replies,
                            'paths',   to_jsonb(v_paths));
end
$$;

comment on function edu.elaina_purge_memo(bigint) is
  '관리자만. 이미 지운 메모를 답글·멘션·알림과 함께 완전히 치우고, 지워야 할 캡처 경로를 돌려준다.';

create or replace function edu.elaina_purge_reply(p_reply_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dead  timestamptz;
  v_paths text[];
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 완전 삭제할 수 있습니다.' using errcode = '42501';
  end if;

  select r.deleted_at, r.image_paths into v_dead, v_paths
    from edu.elaina_memo_replies r where r.id = p_reply_id;
  if not found then
    raise exception '그런 답글이 없습니다.' using errcode = '22023';
  end if;
  if v_dead is null then
    raise exception '먼저 지운 답글만 완전 삭제할 수 있습니다.' using errcode = '42501';
  end if;

  delete from edu.elaina_memo_replies where id = p_reply_id;

  return jsonb_build_object('reply_id', p_reply_id,
                            'paths',    to_jsonb(coalesce(v_paths, '{}'::text[])));
end
$$;

comment on function edu.elaina_purge_reply(bigint) is
  '관리자만. 이미 지운 답글을 완전히 치우고, 지워야 할 캡처 경로를 돌려준다.';

-- ── 실행 권한 — anon 에는 주지 않는다 ──────────────────────────
-- authenticated 에는 열어 두되 함수 안에서 관리자인지 검사한다.
revoke all on function edu.elaina_purge_memo(bigint)  from public, anon;
revoke all on function edu.elaina_purge_reply(bigint) from public, anon;

grant execute on function edu.elaina_purge_memo(bigint)  to authenticated, service_role;
grant execute on function edu.elaina_purge_reply(bigint) to authenticated, service_role;

notify pgrst, 'reload schema';