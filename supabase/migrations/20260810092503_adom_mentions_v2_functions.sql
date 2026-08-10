-- ═══════════════════════════════════════════════════════════════
-- 멘션·알림 서버 함수 (전부 SECURITY DEFINER)
--   글(사람이 읽는 이름) 과 번호 목록(uuid[]) 을 함께 받아
--   메모 저장 · 멘션 기록 · 알림 생성을 한 트랜잭션에서 끝낸다.
--   누구에게 갔는지 / 누가 못 받았는지를 돌려주어 화면에서 알릴 수 있게 한다.
-- ═══════════════════════════════════════════════════════════════

-- ── @ 목록 — 이 화면을 볼 수 있는 사람만 ────────────────────────
create or replace function edu.adom_mention_directory()
returns table (user_id uuid, display_name text, email text, muted boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select v.user_id, v.display_name, v.email, coalesce(p.muted, false)
    from edu.adom_viewers v
    left join edu.adom_notification_prefs p on p.user_id = v.user_id
   where edu.adom_can_view(auth.uid())
   order by v.display_name;
$$;

-- ── 메모 남기기 ─────────────────────────────────────────────────
create or replace function edu.adom_post_memo(
  p_target_type   text,
  p_target_id     text,
  p_target_label  text,
  p_body          text,
  p_mentioned_ids uuid[] default '{}'::uuid[]
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

  select v.display_name into v_actor_name
    from edu.adom_viewers v where v.user_id = v_uid;
  v_actor_name := coalesce(v_actor_name, lower(auth.jwt() ->> 'email'), '알 수 없음');

  -- 작성자·작성시각은 BEFORE 트리거가 채운다 (여기서 보내지 않는다)
  insert into edu.adom_memos (target_type, target_id, body)
       values (p_target_type, p_target_id, p_body)
    returning id into v_memo_id;

  v_excerpt := left(btrim(p_body), 140);

  for v_id in
    select distinct t.x
      from unnest(coalesce(p_mentioned_ids, '{}'::uuid[])) as t(x)
     where t.x is not null
       and t.x <> v_uid                       -- 나 자신에게는 알림이 가지 않는다
  loop
    select v.display_name, v.email into v_name, v_email
      from edu.adom_viewers v where v.user_id = v_id;

    if v_name is null then                    -- 명단에서 빠진 사람도 이름은 알려 준다
      select lower(u.email) into v_name from auth.users u where u.id = v_id;
      v_name := coalesce(v_name, v_id::text);
    end if;

    v_can := edu.adom_can_view(v_id);

    select coalesce(p.muted, false) into v_mute
      from edu.adom_notification_prefs p where p.user_id = v_id;
    v_mute := coalesce(v_mute, false);

    -- 부른 사실 자체는 권한과 무관하게 기록에 남긴다
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
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

-- ── 답글 달기 ───────────────────────────────────────────────────
create or replace function edu.adom_post_reply(
  p_memo_id       bigint,
  p_target_label  text,
  p_body          text,
  p_mentioned_ids uuid[] default '{}'::uuid[]
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

  insert into edu.adom_memo_replies (memo_id, body)
       values (p_memo_id, p_body)
    returning id into v_reply_id;

  v_excerpt := left(btrim(p_body), 140);

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

  -- 메모 주인에게도 한 번 (본인 답글 제외, 멘션으로 이미 보냈으면 제외)
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
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

-- ── 명단 관리 (관리자 전용) ─────────────────────────────────────
create or replace function edu.adom_add_viewer(p_email text, p_display_name text)
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
  if not edu.adom_is_admin() then
    raise exception '관리자만 명단을 바꿀 수 있습니다.' using errcode = '42501';
  end if;

  select u.id into v_target from auth.users u
   where lower(u.email) = v_email and u.deleted_at is null;
  if v_target is null then
    raise exception '그런 계정이 없습니다: %', v_email using errcode = '22023';
  end if;

  if v_name = '' then v_name := split_part(v_email, '@', 1); end if;

  insert into edu.adom_viewers (user_id, email, display_name, added_by)
       values (v_target, v_email, v_name, auth.uid())
  on conflict (user_id) do update set display_name = excluded.display_name;

  return jsonb_build_object('user_id', v_target, 'email', v_email, 'display_name', v_name);
end
$$;

create or replace function edu.adom_remove_viewer(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  if not edu.adom_is_admin() then
    raise exception '관리자만 명단을 바꿀 수 있습니다.' using errcode = '42501';
  end if;

  select v.email into v_email from edu.adom_viewers v where v.user_id = p_user_id;
  if v_email is null then
    raise exception '명단에 없는 사람입니다.' using errcode = '22023';
  end if;
  if v_email = 'adom@pinkage.co.kr' then
    raise exception '관리자는 명단에서 뺄 수 없습니다.' using errcode = '42501';
  end if;

  delete from edu.adom_viewers where user_id = p_user_id;
  return jsonb_build_object('removed', p_user_id, 'email', v_email);
end
$$;

-- 명단에 추가할 후보 계정 (관리자에게만 응답)
create or replace function edu.adom_all_accounts()
returns table (user_id uuid, email text, in_roster boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, lower(u.email),
         exists (select 1 from edu.adom_viewers v where v.user_id = u.id)
    from auth.users u
   where edu.adom_is_admin()
     and u.email is not null
     and u.deleted_at is null
   order by 2;
$$;

-- ── 실행 권한 — anon 에는 아무것도 주지 않는다 ──────────────────
revoke all on function edu.adom_mention_directory()                     from public, anon;
revoke all on function edu.adom_post_memo(text, text, text, text, uuid[]) from public, anon;
revoke all on function edu.adom_post_reply(bigint, text, text, uuid[])    from public, anon;
revoke all on function edu.adom_add_viewer(text, text)                  from public, anon;
revoke all on function edu.adom_remove_viewer(uuid)                     from public, anon;
revoke all on function edu.adom_all_accounts()                          from public, anon;

grant execute on function edu.adom_mention_directory()                     to authenticated, service_role;
grant execute on function edu.adom_post_memo(text, text, text, text, uuid[]) to authenticated, service_role;
grant execute on function edu.adom_post_reply(bigint, text, text, uuid[])    to authenticated, service_role;
grant execute on function edu.adom_add_viewer(text, text)                  to authenticated, service_role;
grant execute on function edu.adom_remove_viewer(uuid)                     to authenticated, service_role;
grant execute on function edu.adom_all_accounts()                          to authenticated, service_role;

notify pgrst, 'reload schema';