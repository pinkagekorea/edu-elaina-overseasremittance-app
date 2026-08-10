-- ═══════════════════════════════════════════════════════════════
-- 지울 때 캡처까지 정리한다
--
--   지금까지는 메모를 지워도(deleted_at) 버킷의 원본이 그대로 남아
--   아무도 안 보는 파일이 쌓였다.
--
--   Storage 삭제는 SQL 로 할 수 없다(storage.protect_delete 가 막는다).
--   그래서 두 단계로 나눈다:
--     1) 이 서버 함수가 '지울 자격'을 검사하고 소프트 삭제한 뒤
--        지워야 할 경로 목록을 돌려준다
--     2) 화면이 그 경로만 Storage API 로 제거한다
--
--   자격 검사가 화면이 아니라 서버 한 곳에 있다는 점이 핵심이다.
--   image_paths 는 지운 뒤에도 행에 남긴다 — 무엇이 붙어 있었는지는
--   기록이고, 트리거가 이미 수정을 막고 있다.
-- ═══════════════════════════════════════════════════════════════

create or replace function edu.elaina_delete_memo(p_memo_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_paths text[];
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;

  -- 자격 검사(본인 또는 관리자)와 시각 찍기는 elaina_stamp 트리거가 한다.
  -- 자격이 없으면 여기서 예외가 올라온다.
  update edu.elaina_memos
     set deleted_at = now()
   where id = p_memo_id
  returning image_paths into v_paths;

  if not found then
    raise exception '그런 메모가 없거나 이미 지워졌습니다.' using errcode = '22023';
  end if;

  return jsonb_build_object('memo_id', p_memo_id,
                            'paths',   to_jsonb(coalesce(v_paths, '{}'::text[])));
end
$$;

comment on function edu.elaina_delete_memo(bigint) is
  '메모를 소프트 삭제하고, 화면이 지워야 할 캡처 경로를 돌려준다.';

create or replace function edu.elaina_delete_reply(p_reply_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_paths text[];
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;

  update edu.elaina_memo_replies
     set deleted_at = now()
   where id = p_reply_id
  returning image_paths into v_paths;

  if not found then
    raise exception '그런 답글이 없거나 이미 지워졌습니다.' using errcode = '22023';
  end if;

  return jsonb_build_object('reply_id', p_reply_id,
                            'paths',    to_jsonb(coalesce(v_paths, '{}'::text[])));
end
$$;

comment on function edu.elaina_delete_reply(bigint) is
  '답글을 소프트 삭제하고, 화면이 지워야 할 캡처 경로를 돌려준다.';

-- ── 관리자도 캡처를 치울 수 있어야 한다 ────────────────────────
-- 관리자는 남의 메모를 지울 수 있는데, 지금 정책은 owner 만 파일을 지울 수
-- 있어서 관리자가 지운 메모의 캡처는 영영 남는다. ALTER 로 넓힌다(DROP 없음).
alter policy elaina_memo_delete on storage.objects
  using (
    bucket_id = 'elaina-memo'
    and (owner = auth.uid() or edu.elaina_is_admin())
    and edu.elaina_can_view(auth.uid())
  );

-- ── 실행 권한 — anon 에는 주지 않는다 ──────────────────────────
revoke all on function edu.elaina_delete_memo(bigint)  from public, anon;
revoke all on function edu.elaina_delete_reply(bigint) from public, anon;

grant execute on function edu.elaina_delete_memo(bigint)  to authenticated, service_role;
grant execute on function edu.elaina_delete_reply(bigint) to authenticated, service_role;

notify pgrst, 'reload schema';