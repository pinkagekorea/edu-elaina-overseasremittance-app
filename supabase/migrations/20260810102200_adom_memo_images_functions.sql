-- ═══════════════════════════════════════════════════════════════
-- 이미지 첨부를 받는 저장 함수
--   · 본문 없이 이미지만 있는 메모도 허용한다
--   · 붙일 수 있는 이미지는 "본인이 adom-memo 에 올린 것" 뿐이다
--     → 남이 올린 파일 경로를 적어 넣어 훔쳐보는 것을 막는다
-- (표는 모두 0건이라 제약 교체·함수 교체로 잃는 데이터가 없다)
-- ═══════════════════════════════════════════════════════════════

-- ── 본문 제약: 글이 비어도 이미지가 있으면 통과 ─────────────────
alter table edu.adom_memos drop constraint adom_memos_body_check;
alter table edu.adom_memos add constraint adom_memos_body_check
  check (length(body) <= 4000
         and (length(btrim(body)) >= 1 or coalesce(array_length(image_paths, 1), 0) >= 1));

alter table edu.adom_memo_replies drop constraint adom_memo_replies_body_check;
alter table edu.adom_memo_replies add constraint adom_memo_replies_body_check
  check (length(body) <= 4000
         and (length(btrim(body)) >= 1 or coalesce(array_length(image_paths, 1), 0) >= 1));

-- ── 붙일 수 있는 이미지인지 확인 ────────────────────────────────
create or replace function edu.adom_check_images(p_uid uuid, p_paths text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int := coalesce(array_length(p_paths, 1), 0);
begin
  if v_n = 0 then return; end if;
  if v_n > 10 then
    raise exception '이미지는 한 번에 10장까지만 붙일 수 있습니다.' using errcode = '22023';
  end if;

  if exists (
    select 1
      from unnest(p_paths) as t(path)
     where not exists (
       select 1 from storage.objects o
        where o.bucket_id = 'adom-memo'
          and o.name      = t.path
          and o.owner     = p_uid        -- 본인이 올린 것만
     )
  ) then
    raise exception '본인이 방금 올린 이미지만 붙일 수 있습니다.' using errcode = '42501';
  end if;
end
$$;

-- ── 메모 남기기 (이미지 포함) ───────────────────────────────────
drop function if exists edu.adom_post_memo(text, text, text, text, uuid[]);

create function edu.adom_post_memo(
  p_target_type   text,
  p_target_id     text,
  p_target_label  text,
  p_body          text,
  p_mentioned_ids uuid[] default '{}'::uuid[],
  p_image_paths   text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_memo_id    bigint;
  v_actor_name text;
  v_excerpt    text;
  v_imgs       int   := coalesce(array_length(p_image_paths, 1), 0);
  v_label      text  := coalesce(nullif(btrim(p_target_label), ''), p_target_id);
  v_notified   jsonb := '[]'::jsonb;
  v_blocked    jsonb := '[]'::jsonb;
  v_muted      jsonb := '[]'::jsonb;
  v_id         uuid;
  v_name       text;
  v_email      text;
  v_can        boolean;
  v_mute       boolean;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.adom_can_view(v_uid) then
    raise exception '이 화면에 메모를 남길 권한이 없습니다.' using errcode = '42501';
  end if;

  perform edu.adom_check_images(v_uid, p_image_paths);

  select v.display_name into v_actor_name
    from edu.adom_viewers v where v.user_id = v_uid;
  v_actor_name := coalesce(v_actor_name, lower(auth.jwt() ->> 'email'), '알 수 없음');

  insert into edu.adom_memos (target_type, target_id, body, image_paths)
       values (p_target_type, p_target_id, p_body, coalesce(p_image_paths, '{}'))
    returning id into v_memo_id;

  v_excerpt := left(btrim(p_body), 140);
  if v_excerpt = '' then v_excerpt := '(이미지 ' || v_imgs || '장)'; end if;

  for v_id in
    select distinct t.x
      from unnest(coalesce(p_mentioned_ids, '{}'::uuid[])) as t(x)
     where t.x is not null and t.x <> v_uid
  loop
    select v.display_name, v.email into v_name, v_email
      from edu.adom_viewers v where v.user_id = v_id;
    if v_name is null then
      select lower(u.email) into v_name from auth.users u where u.id = v_id;
      v_name := coalesce(v_name, v_id::text);
    end if;

    v_can := edu.adom_can_view(v_id);
    select coalesce(p.muted, false) into v_mute
      from edu.adom_notification_prefs p where p.user_id = v_id;
    v_mute := coalesce(v_mute, false);

    insert into edu.adom_mentions
      (memo_id, reply_id, mentioned_id, mentioned_email, mentioned_name, actor_id)
    values (v_memo_id, null, v_id, v_email, v_name, v_uid)
    on conflict do nothing;

    if not v_can then
      v_blocked  := v_blocked  || jsonb_build_object('id', v_id, 'name', v_name);
    elsif v_mute then
      v_muted    := v_muted    || jsonb_build_object('id', v_id, 'name', v_name);
    else
      insert into edu.adom_notifications
        (recipient_id, actor_id, kind, memo_id, reply_id,
         target_type, target_id, target_label, actor_name, excerpt)
      values (v_id, v_uid, 'mention', v_memo_id, null,
              p_target_type, p_target_id, v_label, v_actor_name, v_excerpt);
      v_notified := v_notified || jsonb_build_object('id', v_id, 'name', v_name);
    end if;
  end loop;

  return jsonb_build_object('memo_id',  v_memo_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

-- ── 답글 달기 (이미지 포함) ─────────────────────────────────────
drop function if exists edu.adom_post_reply(bigint, text, text, uuid[]);

create function edu.adom_post_reply(
  p_memo_id       bigint,
  p_target_label  text,
  p_body          text,
  p_mentioned_ids uuid[] default '{}'::uuid[],
  p_image_paths   text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_reply_id   bigint;
  v_type       text;
  v_target     text;
  v_memo_owner uuid;
  v_actor_name text;
  v_excerpt    text;
  v_imgs       int := coalesce(array_length(p_image_paths, 1), 0);
  v_label      text;
  v_notified   jsonb := '[]'::jsonb;
  v_blocked    jsonb := '[]'::jsonb;
  v_muted      jsonb := '[]'::jsonb;
  v_done       uuid[] := '{}'::uuid[];
  v_id         uuid;
  v_name       text;
  v_email      text;
  v_can        boolean;
  v_mute       boolean;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.adom_can_view(v_uid) then
    raise exception '이 화면에 답글을 달 권한이 없습니다.' using errcode = '42501';
  end if;

  perform edu.adom_check_images(v_uid, p_image_paths);

  select m.target_type, m.target_id, m.author_id
    into v_type, v_target, v_memo_owner
    from edu.adom_memos m where m.id = p_memo_id;
  if v_type is null then
    raise exception '그런 메모가 없습니다.' using errcode = '22023';
  end if;

  v_label := coalesce(nullif(btrim(p_target_label), ''), v_target);

  select v.display_name into v_actor_name
    from edu.adom_viewers v where v.user_id = v_uid;
  v_actor_name := coalesce(v_actor_name, lower(auth.jwt() ->> 'email'), '알 수 없음');

  insert into edu.adom_memo_replies (memo_id, body, image_paths)
       values (p_memo_id, p_body, coalesce(p_image_paths, '{}'))
    returning id into v_reply_id;

  v_excerpt := left(btrim(p_body), 140);
  if v_excerpt = '' then v_excerpt := '(이미지 ' || v_imgs || '장)'; end if;

  for v_id in
    select distinct t.x
      from unnest(coalesce(p_mentioned_ids, '{}'::uuid[])) as t(x)
     where t.x is not null and t.x <> v_uid
  loop
    select v.display_name, v.email into v_name, v_email
      from edu.adom_viewers v where v.user_id = v_id;
    if v_name is null then
      select lower(u.email) into v_name from auth.users u where u.id = v_id;
      v_name := coalesce(v_name, v_id::text);
    end if;

    v_can := edu.adom_can_view(v_id);
    select coalesce(p.muted, false) into v_mute
      from edu.adom_notification_prefs p where p.user_id = v_id;
    v_mute := coalesce(v_mute, false);

    insert into edu.adom_mentions
      (memo_id, reply_id, mentioned_id, mentioned_email, mentioned_name, actor_id)
    values (null, v_reply_id, v_id, v_email, v_name, v_uid)
    on conflict do nothing;

    if not v_can then
      v_blocked := v_blocked || jsonb_build_object('id', v_id, 'name', v_name);
    elsif v_mute then
      v_muted   := v_muted   || jsonb_build_object('id', v_id, 'name', v_name);
    else
      insert into edu.adom_notifications
        (recipient_id, actor_id, kind, memo_id, reply_id,
         target_type, target_id, target_label, actor_name, excerpt)
      values (v_id, v_uid, 'mention', p_memo_id, v_reply_id,
              v_type, v_target, v_label, v_actor_name, v_excerpt);
      v_notified := v_notified || jsonb_build_object('id', v_id, 'name', v_name);
      v_done := v_done || v_id;
    end if;
  end loop;

  if v_memo_owner is not null
     and v_memo_owner <> v_uid
     and not (v_memo_owner = any (v_done))
     and edu.adom_can_view(v_memo_owner)
     and not coalesce((select p.muted from edu.adom_notification_prefs p
                        where p.user_id = v_memo_owner), false)
  then
    insert into edu.adom_notifications
      (recipient_id, actor_id, kind, memo_id, reply_id,
       target_type, target_id, target_label, actor_name, excerpt)
    values (v_memo_owner, v_uid, 'reply', p_memo_id, v_reply_id,
            v_type, v_target, v_label, v_actor_name, v_excerpt);
  end if;

  return jsonb_build_object('reply_id', v_reply_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

revoke all on function edu.adom_check_images(uuid, text[])                        from public, anon;
revoke all on function edu.adom_post_memo(text, text, text, text, uuid[], text[])  from public, anon;
revoke all on function edu.adom_post_reply(bigint, text, text, uuid[], text[])     from public, anon;

grant execute on function edu.adom_post_memo(text, text, text, text, uuid[], text[]) to authenticated, service_role;
grant execute on function edu.adom_post_reply(bigint, text, text, uuid[], text[])    to authenticated, service_role;

notify pgrst, 'reload schema';