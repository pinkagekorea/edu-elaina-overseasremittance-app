-- ═══════════════════════════════════════════════════════════════
-- 멘션(@호출) 3단계
--   · 글에는 이름만, 번호(uuid)는 따로 — 서버가 본문에서 다시 계산한다
--   · 못 보는 사람을 부르면 조용히 넘어가지 않고 그대로 알려 준다
--   · 사람마다 알림을 끌 수 있다
--   · 알림을 만드는 것은 SECURITY DEFINER 서버 함수뿐이다
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 알림 끄기 ───────────────────────────────────────────────
create table if not exists edu.elaina_notification_prefs (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  muted      boolean     not null default false,
  updated_at timestamptz not null default now()
);

comment on table edu.elaina_notification_prefs is
  '알림 수신 여부. 본인 것만 읽고 쓸 수 있다. 꺼도 호출 기록은 남는다.';

alter table edu.elaina_notification_prefs enable row level security;

revoke all on edu.elaina_notification_prefs from anon, authenticated, public;
grant select, insert, update on edu.elaina_notification_prefs to authenticated;

drop policy if exists elaina_prefs_select on edu.elaina_notification_prefs;
create policy elaina_prefs_select on edu.elaina_notification_prefs
  for select to authenticated using (user_id = auth.uid());

drop policy if exists elaina_prefs_insert on edu.elaina_notification_prefs;
create policy elaina_prefs_insert on edu.elaina_notification_prefs
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists elaina_prefs_update on edu.elaina_notification_prefs;
create policy elaina_prefs_update on edu.elaina_notification_prefs
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── 2. 본문에서 @토큰 뽑기 ─────────────────────────────────────
-- 지금까지는 position('@'||이름 in 본문) 으로 찾았다. 그러면 '@luka-team' 을
-- 쓸 때 'luka' 도 함께 걸린다(앞자리가 겹치므로). 토큰으로 잘라 정확히 맞춘다.
create or replace function edu.elaina_mention_tokens(p_body text)
returns table (token text)
language sql
immutable
set search_path = ''
as $$
  select distinct m[1]
    from regexp_matches(coalesce(p_body, ''),
                        '@([0-9A-Za-z가-힣_.-]{1,32})', 'g') as m;
$$;

comment on function edu.elaina_mention_tokens(text) is
  '본문에서 @뒤의 이름만 잘라낸다. 앞자리가 겹치는 이름끼리 헷갈리지 않게 토큰 단위로 자른다.';

-- ── 3. 이름 → 사람 (볼 수 있는 사람인지까지) ───────────────────
-- 명단에 있으면 표시 이름으로, 없으면 계정 이메일 앞부분으로 알아본다.
-- 명단 밖 사람도 '누구인지'는 알아내야 "이 사람은 못 받습니다" 를 말할 수 있다.
create or replace function edu.elaina_resolve_names(p_body text)
returns table (name text, user_id uuid, can_view boolean, muted boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select t.token,
         coalesce(v.user_id, u.id),
         v.user_id is not null,
         coalesce(p.muted, false)
    from edu.elaina_mention_tokens(p_body) t
    left join edu.elaina_viewers v
           on v.display_name = t.token
    left join auth.users u
           on u.deleted_at is null
          and u.email is not null
          and split_part(lower(u.email), '@', 1) = t.token
    left join edu.elaina_notification_prefs p
           on p.user_id = coalesce(v.user_id, u.id)
   where coalesce(v.user_id, u.id) is not null;
$$;

comment on function edu.elaina_resolve_names(text) is
  '본문의 @이름을 사람으로 바꾼다. 명단 밖 계정도 알아보되 can_view=false 로 표시한다.';

-- 저장용: 알림을 받을 수 있는 사람의 번호만
create or replace function edu.elaina_called_ids(p_body text)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(r.user_id order by r.name), '{}')
    from edu.elaina_resolve_names(p_body) r
   where r.can_view;
$$;

-- ── 4. 쓰는 중 미리보기 (그 자리에서 경고하기 위해) ────────────
-- 사용자가 직접 친 이름만 되돌려 준다. 명단을 훑어볼 수는 없다.
create or replace function edu.elaina_preview_mentions(p_body text)
returns table (name text, can_view boolean, muted boolean, is_self boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select r.name, r.can_view, r.muted, r.user_id = auth.uid()
    from edu.elaina_resolve_names(p_body) r
   where edu.elaina_can_view(auth.uid())
   order by r.name;
$$;

comment on function edu.elaina_preview_mentions(text) is
  '입력 중인 본문의 @이름 판정. 친 이름만 돌려주므로 명단 열람에는 쓸 수 없다.';

-- ── 5. @ 자동완성 목록 — 볼 수 있는 사람만 ─────────────────────
create or replace function edu.elaina_mention_directory()
returns table (user_id uuid, display_name text, muted boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select v.user_id, v.display_name, coalesce(p.muted, false)
    from edu.elaina_viewers v
    left join edu.elaina_notification_prefs p on p.user_id = v.user_id
   where edu.elaina_can_view(auth.uid())
   order by v.display_name;
$$;

comment on function edu.elaina_mention_directory() is
  '@ 목록. 8일차 화면 권한(elaina_viewers)을 그대로 따른다. 이메일은 내보내지 않는다.';

-- ── 6. 알림 생성 — 끈 사람은 건너뛴다 ──────────────────────────
create or replace function edu.elaina_fanout()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_memo_id      bigint;
  v_reply_id     bigint;
  v_target_type  text;
  v_target_id    text;
  v_target_label text;
  v_memo_author  uuid;
  v_actor_name   text;
  v_excerpt      text;
  v_uid          uuid;
  v_name         text;
begin
  if tg_table_name = 'elaina_memos' then
    v_memo_id      := new.id;
    v_reply_id     := null;
    v_target_type  := new.target_type;
    v_target_id    := new.target_id;
    v_target_label := new.target_label;
  else
    v_memo_id  := new.memo_id;
    v_reply_id := new.id;
    select m.target_type, m.target_id, m.target_label, m.author_id
      into v_target_type, v_target_id, v_target_label, v_memo_author
      from edu.elaina_memos m
     where m.id = new.memo_id;
  end if;

  v_excerpt := left(btrim(new.body), 140);

  select v.display_name into v_actor_name
    from edu.elaina_viewers v where v.user_id = new.author_id;
  v_actor_name := coalesce(v_actor_name,
                           split_part(coalesce(new.author_email, ''), '@', 1),
                           '알 수 없음');

  foreach v_uid in array coalesce(new.mention_ids, '{}'::uuid[]) loop
    continue when v_uid = new.author_id;                  -- 나 자신에게는 안 간다

    select v.display_name into v_name
      from edu.elaina_viewers v where v.user_id = v_uid;

    -- 호출 기록은 알림을 껐어도 남긴다
    insert into edu.elaina_mentions
      (memo_id, reply_id, mentioned_id, mentioned_name, actor_id)
    values (v_memo_id, v_reply_id, v_uid, coalesce(v_name, '?'), new.author_id)
    on conflict do nothing;

    continue when exists (select 1 from edu.elaina_notification_prefs p
                           where p.user_id = v_uid and p.muted);

    insert into edu.elaina_notifications
      (recipient_id, actor_id, actor_name, kind, memo_id, reply_id,
       target_type, target_id, target_label, excerpt)
    values (v_uid, new.author_id, v_actor_name, 'mention', v_memo_id, v_reply_id,
            v_target_type, v_target_id, v_target_label, v_excerpt);
  end loop;

  -- 답글이면 메모 주인에게도 (본인 제외, 이미 불렸으면 제외, 껐으면 제외)
  if v_reply_id is not null
     and v_memo_author is not null
     and v_memo_author <> new.author_id
     and not (v_memo_author = any (coalesce(new.mention_ids, '{}'::uuid[])))
     and not exists (select 1 from edu.elaina_notification_prefs p
                      where p.user_id = v_memo_author and p.muted)
  then
    insert into edu.elaina_notifications
      (recipient_id, actor_id, actor_name, kind, memo_id, reply_id,
       target_type, target_id, target_label, excerpt)
    values (v_memo_author, new.author_id, v_actor_name, 'reply', v_memo_id, v_reply_id,
            v_target_type, v_target_id, v_target_label, v_excerpt);
  end if;

  return null;
end
$$;

-- ── 7. 남기기 — 누구에게 갔고 누가 못 받았는지 돌려준다 ────────
-- 알림 자체는 위 트리거(definer)가 만든다. 이 함수는 그 판정을 사람이
-- 읽을 수 있게 정리해서 돌려주는 창구다.
create or replace function edu.elaina_post_memo(
  p_target_type  text,
  p_target_id    text,
  p_target_label text,
  p_body         text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_memo_id  bigint;
  v_notified jsonb := '[]'::jsonb;
  v_blocked  jsonb := '[]'::jsonb;
  v_muted    jsonb := '[]'::jsonb;
  r          record;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.elaina_can_view(v_uid) then
    raise exception '이 화면에 메모를 남길 권한이 없습니다.' using errcode = '42501';
  end if;

  insert into edu.elaina_memos (target_type, target_id, target_label, body)
       values (p_target_type, p_target_id, nullif(btrim(coalesce(p_target_label,'')),''), p_body)
    returning id into v_memo_id;

  for r in select * from edu.elaina_resolve_names(p_body) loop
    continue when r.user_id = v_uid;
    if not r.can_view then
      v_blocked  := v_blocked  || jsonb_build_object('name', r.name);
    elsif r.muted then
      v_muted    := v_muted    || jsonb_build_object('name', r.name);
    else
      v_notified := v_notified || jsonb_build_object('name', r.name);
    end if;
  end loop;

  return jsonb_build_object('memo_id',  v_memo_id,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

create or replace function edu.elaina_post_reply(
  p_memo_id bigint,
  p_body    text
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
  v_notified jsonb := '[]'::jsonb;
  v_blocked  jsonb := '[]'::jsonb;
  v_muted    jsonb := '[]'::jsonb;
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

  insert into edu.elaina_memo_replies (memo_id, body)
       values (p_memo_id, p_body)
    returning id into v_reply_id;

  for r in select * from edu.elaina_resolve_names(p_body) loop
    continue when r.user_id = v_uid;
    if not r.can_view then
      v_blocked  := v_blocked  || jsonb_build_object('name', r.name);
    elsif r.muted then
      v_muted    := v_muted    || jsonb_build_object('name', r.name);
    else
      v_notified := v_notified || jsonb_build_object('name', r.name);
    end if;
  end loop;

  return jsonb_build_object('reply_id', v_reply_id,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

-- ── 8. 알림 켜고 끄기 (본인 것만) ──────────────────────────────
create or replace function edu.elaina_set_muted(p_muted boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  insert into edu.elaina_notification_prefs (user_id, muted, updated_at)
       values (v_uid, coalesce(p_muted, false), now())
  on conflict (user_id) do update
     set muted = excluded.muted, updated_at = now();
  return coalesce(p_muted, false);
end
$$;

-- ── 9. 실행 권한 — anon 에는 아무것도 주지 않는다 ──────────────
revoke all on function edu.elaina_mention_tokens(text)     from public, anon, authenticated;
revoke all on function edu.elaina_resolve_names(text)      from public, anon, authenticated;
revoke all on function edu.elaina_called_ids(text)         from public, anon, authenticated;
revoke all on function edu.elaina_fanout()                 from public, anon, authenticated;

revoke all on function edu.elaina_preview_mentions(text)               from public, anon;
revoke all on function edu.elaina_mention_directory()                  from public, anon;
revoke all on function edu.elaina_post_memo(text, text, text, text)    from public, anon;
revoke all on function edu.elaina_post_reply(bigint, text)             from public, anon;
revoke all on function edu.elaina_set_muted(boolean)                   from public, anon;

grant execute on function edu.elaina_preview_mentions(text)            to authenticated, service_role;
grant execute on function edu.elaina_mention_directory()               to authenticated, service_role;
grant execute on function edu.elaina_post_memo(text, text, text, text) to authenticated, service_role;
grant execute on function edu.elaina_post_reply(bigint, text)          to authenticated, service_role;
grant execute on function edu.elaina_set_muted(boolean)                to authenticated, service_role;

notify pgrst, 'reload schema';