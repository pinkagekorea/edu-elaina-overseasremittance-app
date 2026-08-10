-- ═══════════════════════════════════════════════════════════════
-- 나 자신을 @로 부른 경우
--   · 인앱 벨은 그대로 울리지 않는다 (앞서 정한 "나에게는 알림 없음" 유지)
--   · 대신 슬랙 채널 heads-up 만 보낸다 → 웹훅 점검용 통로
--   · is_self 인 줄은 짝이 맞아 있어도 DM 으로 보내지 않고 항상 채널로 간다
-- ═══════════════════════════════════════════════════════════════

alter table edu.adom_slack_outbox
  add column is_self boolean not null default false;

comment on column edu.adom_slack_outbox.is_self is
  '자기 자신을 부른 줄. 인앱 알림 없이 채널 heads-up 만 보낸다(점검용).';

create or replace function edu.adom_post_memo(
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
  v_notif_id   bigint;
  v_actor_name text;
  v_self_email text;
  v_excerpt    text;
  v_imgs       int   := coalesce(array_length(p_image_paths, 1), 0);
  v_label      text  := coalesce(nullif(btrim(p_target_label), ''), p_target_id);
  v_notified   jsonb := '[]'::jsonb;
  v_blocked    jsonb := '[]'::jsonb;
  v_muted      jsonb := '[]'::jsonb;
  v_self       jsonb := null;
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

  select v.display_name, v.email into v_actor_name, v_self_email
    from edu.adom_viewers v where v.user_id = v_uid;
  v_actor_name := coalesce(v_actor_name, lower(auth.jwt() ->> 'email'), '알 수 없음');

  insert into edu.adom_memos (target_type, target_id, body, image_paths)
       values (p_target_type, p_target_id, p_body, coalesce(p_image_paths, '{}'))
    returning id into v_memo_id;

  v_excerpt := left(btrim(p_body), 140);
  if v_excerpt = '' then v_excerpt := '(이미지 ' || v_imgs || '장)'; end if;

  -- ── 남을 부른 경우 ────────────────────────────────────────────
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
      v_blocked := v_blocked || jsonb_build_object('id', v_id, 'name', v_name);
    elsif v_mute then
      v_muted   := v_muted   || jsonb_build_object('id', v_id, 'name', v_name);
    else
      insert into edu.adom_notifications
        (recipient_id, actor_id, kind, memo_id, reply_id,
         target_type, target_id, target_label, actor_name, excerpt)
      values (v_id, v_uid, 'mention', v_memo_id, null,
              p_target_type, p_target_id, v_label, v_actor_name, v_excerpt)
      returning id into v_notif_id;

      insert into edu.adom_slack_outbox
        (notification_id, actor_id, recipient_id, recipient_name, memo_id, reply_id,
         target_type, target_id, target_label, actor_name, excerpt)
      values (v_notif_id, v_uid, v_id, v_name, v_memo_id, null,
              p_target_type, p_target_id, v_label, v_actor_name, v_excerpt);

      v_notified := v_notified || jsonb_build_object('id', v_id, 'name', v_name);
    end if;
  end loop;

  -- ── 나 자신을 부른 경우 — 벨은 안 울리고 채널 heads-up 만 ────
  if v_uid = any (coalesce(p_mentioned_ids, '{}'::uuid[])) then
    insert into edu.adom_mentions
      (memo_id, reply_id, mentioned_id, mentioned_email, mentioned_name, actor_id)
    values (v_memo_id, null, v_uid, v_self_email, v_actor_name, v_uid)
    on conflict do nothing;

    insert into edu.adom_slack_outbox
      (notification_id, actor_id, recipient_id, recipient_name, memo_id, reply_id,
       target_type, target_id, target_label, actor_name, excerpt, is_self)
    values (null, v_uid, v_uid, v_actor_name, v_memo_id, null,
            p_target_type, p_target_id, v_label, v_actor_name, v_excerpt, true);

    v_self := jsonb_build_object('id', v_uid, 'name', v_actor_name);
  end if;

  return jsonb_build_object('memo_id',  v_memo_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted,
                            'self',     v_self);
end
$$;

create or replace function edu.adom_post_reply(
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
  v_notif_id   bigint;
  v_type       text;
  v_target     text;
  v_memo_owner uuid;
  v_owner_name text;
  v_actor_name text;
  v_self_email text;
  v_excerpt    text;
  v_imgs       int := coalesce(array_length(p_image_paths, 1), 0);
  v_label      text;
  v_notified   jsonb := '[]'::jsonb;
  v_blocked    jsonb := '[]'::jsonb;
  v_muted      jsonb := '[]'::jsonb;
  v_self       jsonb := null;
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

  select v.display_name, v.email into v_actor_name, v_self_email
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
              v_type, v_target, v_label, v_actor_name, v_excerpt)
      returning id into v_notif_id;

      insert into edu.adom_slack_outbox
        (notification_id, actor_id, recipient_id, recipient_name, memo_id, reply_id,
         target_type, target_id, target_label, actor_name, excerpt)
      values (v_notif_id, v_uid, v_id, v_name, p_memo_id, v_reply_id,
              v_type, v_target, v_label, v_actor_name, v_excerpt);

      v_notified := v_notified || jsonb_build_object('id', v_id, 'name', v_name);
      v_done := v_done || v_id;
    end if;
  end loop;

  if v_uid = any (coalesce(p_mentioned_ids, '{}'::uuid[])) then
    insert into edu.adom_mentions
      (memo_id, reply_id, mentioned_id, mentioned_email, mentioned_name, actor_id)
    values (null, v_reply_id, v_uid, v_self_email, v_actor_name, v_uid)
    on conflict do nothing;

    insert into edu.adom_slack_outbox
      (notification_id, actor_id, recipient_id, recipient_name, memo_id, reply_id,
       target_type, target_id, target_label, actor_name, excerpt, is_self)
    values (null, v_uid, v_uid, v_actor_name, p_memo_id, v_reply_id,
            v_type, v_target, v_label, v_actor_name, v_excerpt, true);

    v_self := jsonb_build_object('id', v_uid, 'name', v_actor_name);
  end if;

  if v_memo_owner is not null
     and v_memo_owner <> v_uid
     and not (v_memo_owner = any (v_done))
     and edu.adom_can_view(v_memo_owner)
     and not coalesce((select p.muted from edu.adom_notification_prefs p
                        where p.user_id = v_memo_owner), false)
  then
    select v.display_name into v_owner_name
      from edu.adom_viewers v where v.user_id = v_memo_owner;

    insert into edu.adom_notifications
      (recipient_id, actor_id, kind, memo_id, reply_id,
       target_type, target_id, target_label, actor_name, excerpt)
    values (v_memo_owner, v_uid, 'reply', p_memo_id, v_reply_id,
            v_type, v_target, v_label, v_actor_name, v_excerpt)
    returning id into v_notif_id;

    insert into edu.adom_slack_outbox
      (notification_id, actor_id, recipient_id, recipient_name, memo_id, reply_id,
       target_type, target_id, target_label, actor_name, excerpt)
    values (v_notif_id, v_uid, v_memo_owner, coalesce(v_owner_name, '메모 작성자'),
            p_memo_id, v_reply_id, v_type, v_target, v_label, v_actor_name, v_excerpt);

    v_notified := v_notified || jsonb_build_object('id', v_memo_owner,
                                                   'name', coalesce(v_owner_name, '메모 작성자'));
  end if;

  return jsonb_build_object('reply_id', v_reply_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted,
                            'self',     v_self);
end
$$;

notify pgrst, 'reload schema';