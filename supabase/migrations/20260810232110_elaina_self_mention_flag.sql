-- ═══════════════════════════════════════════════════════════════
-- 나 자신을 @로 부른 경우
--
--   인앱 벨은 그대로 울리지 않는다("나 자신에게는 알림이 가지 않게").
--   대신 슬랙 채널 heads-up 만 보낸다 → 웹훅이 살아 있는지 확인하는 통로.
--
--   여기서는 '내가 나를 불렀다'는 사실만 돌려준다. 실제 발송 판정은
--   Edge Function 이 한다(비밀값이 거기에만 있으므로).
--
--   시그니처는 그대로라 create or replace 로 교체된다 (DROP 없음).
-- ═══════════════════════════════════════════════════════════════

create or replace function edu.elaina_post_memo(
  p_target_type  text,
  p_target_id    text,
  p_target_label text,
  p_body         text,
  p_image_paths  text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_memo_id  bigint;
  v_imgs     int   := coalesce(array_length(p_image_paths, 1), 0);
  v_notified jsonb := '[]'::jsonb;
  v_blocked  jsonb := '[]'::jsonb;
  v_muted    jsonb := '[]'::jsonb;
  v_self     boolean := false;
  r          record;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.elaina_can_view(v_uid) then
    raise exception '이 화면에 메모를 남길 권한이 없습니다.' using errcode = '42501';
  end if;

  perform edu.elaina_check_images(v_uid, p_image_paths);

  insert into edu.elaina_memos (target_type, target_id, target_label, body, image_paths)
       values (p_target_type, p_target_id,
               nullif(btrim(coalesce(p_target_label,'')),''),
               p_body, coalesce(p_image_paths, '{}'))
    returning id into v_memo_id;

  for r in select * from edu.elaina_resolve_names(p_body) loop
    if r.user_id = v_uid then
      v_self := true;                         -- 벨은 안 울리고 채널 heads-up 만
      continue;
    end if;
    if not r.can_view then
      v_blocked  := v_blocked  || jsonb_build_object('name', r.name);
    elsif r.muted then
      v_muted    := v_muted    || jsonb_build_object('name', r.name);
    else
      v_notified := v_notified || jsonb_build_object('name', r.name);
    end if;
  end loop;

  return jsonb_build_object('memo_id',  v_memo_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted,
                            'self',     v_self);
end
$$;

create or replace function edu.elaina_post_reply(
  p_memo_id     bigint,
  p_body        text,
  p_image_paths text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_reply_id bigint;
  v_dead     timestamptz;
  v_imgs     int   := coalesce(array_length(p_image_paths, 1), 0);
  v_notified jsonb := '[]'::jsonb;
  v_blocked  jsonb := '[]'::jsonb;
  v_muted    jsonb := '[]'::jsonb;
  v_self     boolean := false;
  r          record;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.elaina_can_view(v_uid) then
    raise exception '이 화면에 답글을 달 권한이 없습니다.' using errcode = '42501';
  end if;

  select m.deleted_at into v_dead from edu.elaina_memos m where m.id = p_memo_id;
  if not found then
    raise exception '그런 메모가 없습니다.' using errcode = '22023';
  end if;
  if v_dead is not null then
    raise exception '지워진 메모에는 답글을 달 수 없습니다.' using errcode = '42501';
  end if;

  perform edu.elaina_check_images(v_uid, p_image_paths);

  insert into edu.elaina_memo_replies (memo_id, body, image_paths)
       values (p_memo_id, p_body, coalesce(p_image_paths, '{}'))
    returning id into v_reply_id;

  for r in select * from edu.elaina_resolve_names(p_body) loop
    if r.user_id = v_uid then
      v_self := true;
      continue;
    end if;
    if not r.can_view then
      v_blocked  := v_blocked  || jsonb_build_object('name', r.name);
    elsif r.muted then
      v_muted    := v_muted    || jsonb_build_object('name', r.name);
    else
      v_notified := v_notified || jsonb_build_object('name', r.name);
    end if;
  end loop;

  return jsonb_build_object('reply_id', v_reply_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted,
                            'self',     v_self);
end
$$;

notify pgrst, 'reload schema';