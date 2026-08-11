-- ═══════════════════════════════════════════════════════════════
-- 수정요청 서버함수 — 전부 SECURITY DEFINER, search_path 는 비운다
--
--   남기기  : 누구나(명단에 있는 사람) · 본인 이름으로만
--   상태변경: 관리자만
--   삭제    : 관리자만 · 붙은 캡처 경로를 돌려준다(Storage 는 SQL 로 못 지운다)
-- ═══════════════════════════════════════════════════════════════

-- ── 남기기 ─────────────────────────────────────────────────────
create or replace function edu.elaina_post_fix_request(
  p_body        text,
  p_image_paths text[] default '{}',
  p_page_url    text   default '',
  p_page_label  text   default null,
  p_viewport    text   default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid   := auth.uid();
  v_body text   := btrim(coalesce(p_body, ''));
  v_url  text   := btrim(coalesce(p_page_url, ''));
  v_id   bigint;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.elaina_can_view(v_uid) then
    raise exception '이 화면을 볼 수 있는 사람만 수정요청을 남길 수 있습니다.' using errcode = '42501';
  end if;
  if v_body = '' then
    raise exception '무엇이 문제인지 한 줄이라도 적어 주세요.' using errcode = '22023';
  end if;
  if length(v_body) > 2000 then
    raise exception '본문은 2000자까지입니다. (지금 %자)', length(v_body) using errcode = '22023';
  end if;

  -- 본인이 방금 올린 캡처만 붙을 수 있다. 10장 제한도 여기서 걸린다. (기존 함수 재사용)
  perform edu.elaina_check_images(v_uid, coalesce(p_image_paths, '{}'));

  insert into edu.elaina_fix_requests
         (author_id, body, image_paths, page_url, page_label, viewport)
  values (v_uid,
          v_body,
          coalesce(p_image_paths, '{}'),
          left(coalesce(nullif(v_url, ''), '(주소를 알 수 없음)'), 2048),
          nullif(btrim(coalesce(p_page_label, '')), ''),
          nullif(btrim(coalesce(p_viewport,  '')), ''))
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end
$$;

comment on function edu.elaina_post_fix_request(text, text[], text, text, text) is
  '수정요청을 남긴다. 작성자·시각·상태는 트리거가 찍으므로 인자로 받지 않는다.';

-- ── 상태 변경 (관리자만) ───────────────────────────────────────
create or replace function edu.elaina_set_fix_status(
  p_id     bigint,
  p_status text,
  p_note   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_row    edu.elaina_fix_requests;
begin
  if not edu.elaina_is_admin() then
    raise exception '상태는 관리자만 바꿀 수 있습니다.' using errcode = '42501';
  end if;
  if v_status not in ('open', 'doing', 'done', 'rejected') then
    raise exception '그런 상태는 없습니다: %', p_status using errcode = '22023';
  end if;
  if p_note is not null and length(btrim(p_note)) > 500 then
    raise exception '메모는 500자까지입니다.' using errcode = '22023';
  end if;

  -- status_by · status_at 은 트리거가 찍는다
  update edu.elaina_fix_requests
     set status      = v_status,
         status_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception '그런 수정요청이 없습니다: %', p_id using errcode = '22023';
  end if;

  return jsonb_build_object('id', v_row.id, 'status', v_row.status,
                            'status_note', v_row.status_note,
                            'status_at', v_row.status_at);
end
$$;

comment on function edu.elaina_set_fix_status(bigint, text, text) is
  '수정요청 상태를 바꾼다. 관리자만. 값은 open/doing/done/rejected 넷뿐이다.';

-- ── 삭제 (관리자만) ────────────────────────────────────────────
create or replace function edu.elaina_delete_fix_request(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paths text[];
begin
  if not edu.elaina_is_admin() then
    raise exception '수정요청 삭제는 관리자만 할 수 있습니다.' using errcode = '42501';
  end if;

  delete from edu.elaina_fix_requests where id = p_id
  returning image_paths into v_paths;

  if v_paths is null then          -- image_paths 는 not null 이므로 null = 그런 행이 없었다
    raise exception '그런 수정요청이 없습니다: %', p_id using errcode = '22023';
  end if;

  -- SQL 로는 Storage 를 지울 수 없다. 경로를 돌려주고 화면이 버킷에서 치운다.
  return jsonb_build_object('id', p_id, 'paths', to_jsonb(v_paths));
end
$$;

comment on function edu.elaina_delete_fix_request(bigint) is
  '수정요청을 지운다. 관리자만. 붙어 있던 캡처 경로를 돌려주므로 화면이 버킷에서 치운다.';

-- ── 실행 권한 — anon 에는 아무것도 주지 않는다 ─────────────────
revoke all on function edu.elaina_post_fix_request(text, text[], text, text, text) from public, anon;
revoke all on function edu.elaina_set_fix_status(bigint, text, text)               from public, anon;
revoke all on function edu.elaina_delete_fix_request(bigint)                       from public, anon;

grant execute on function edu.elaina_post_fix_request(text, text[], text, text, text) to authenticated, service_role;
grant execute on function edu.elaina_set_fix_status(bigint, text, text)               to authenticated, service_role;
grant execute on function edu.elaina_delete_fix_request(bigint)                       to authenticated, service_role;

notify pgrst, 'reload schema';
