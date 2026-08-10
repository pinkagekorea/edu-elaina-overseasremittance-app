-- 과제 보강 1 : 글자(본문)와 번호(아이디 목록)를 나눠서 같이 저장한다.
--   본문에는 '@데이지' 라는 글자만, mention_ids 에는 그 사람의 번호(uuid)만.
alter table edu.hani_memos        add column if not exists mention_ids uuid[] not null default '{}';
alter table edu.hani_memo_replies add column if not exists mention_ids uuid[] not null default '{}';

comment on column edu.hani_memos.mention_ids is '이 글에서 부른 사람들의 번호. 알림 보낼 때 쓰는 쪽. 본문에는 이름만 남는다.';

-- 본문에서 부른 사람의 번호만 뽑아 준다.
-- 명단(hani_viewers)은 아무에게도 열려 있지 않으므로 security definer 로 대신 읽는다.
create or replace function edu.hani_called_ids(p_body text)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(v.user_id order by v.display_name), '{}')
    from edu.hani_viewers v
   where position('@' || v.display_name in coalesce(p_body, '')) > 0
$$;

revoke all on function edu.hani_called_ids(text) from public, anon;
grant execute on function edu.hani_called_ids(text) to authenticated;

-- 과제 보강 2 : 사람마다 알림을 끌 수 있게
create table if not exists edu.hani_notification_prefs (
  user_id    uuid primary key references auth.users(id),
  muted      boolean not null default false,
  updated_at timestamptz not null default now()
);
comment on table edu.hani_notification_prefs is '알림 수신 여부. 본인 것만 읽고 쓸 수 있다.';

alter table edu.hani_notification_prefs enable row level security;
revoke all on edu.hani_notification_prefs from anon, public;
grant select, insert, update on edu.hani_notification_prefs to authenticated;

drop policy if exists hani_prefs_select on edu.hani_notification_prefs;
create policy hani_prefs_select on edu.hani_notification_prefs
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists hani_prefs_insert on edu.hani_notification_prefs;
create policy hani_prefs_insert on edu.hani_notification_prefs
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists hani_prefs_update on edu.hani_notification_prefs;
create policy hani_prefs_update on edu.hani_notification_prefs
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- 저장할 때 번호 목록을 같이 넣는다 (사람이 보낸 값은 무시하고 서버가 다시 계산)
create or replace function edu.hani_stamp_author()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.author_id    := auth.uid();
    new.author_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.mention_ids  := edu.hani_called_ids(new.body);
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  -- UPDATE : 본문과 작성 기록은 되돌려 놓는다. 허용되는 변경은 '지움 표시' 하나뿐.
  new.body         := old.body;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.mention_ids  := old.mention_ids;

  if tg_table_name = 'hani_memos' then
    new.target_type  := old.target_type;
    new.target_id    := old.target_id;
    new.target_label := old.target_label;
  else
    new.memo_id := old.memo_id;
  end if;

  if new.deleted_at is not null and old.deleted_at is null then
    new.deleted_at := now();
    new.deleted_by := auth.uid();
  else
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end
$$;

-- 알림은 mention_ids(번호 목록)를 보고 보낸다. 끈 사람에게는 보내지 않는다.
create or replace function edu.hani_fanout()
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
  v_actor_name   text;
  v_excerpt      text;
  v_memo_author  uuid;
  v_uid          uuid;
  v_name         text;
begin
  if tg_table_name = 'hani_memos' then
    v_memo_id  := new.id;
    v_reply_id := null;
    v_target_type  := new.target_type;
    v_target_id    := new.target_id;
    v_target_label := new.target_label;
  else
    v_reply_id := new.id;
    v_memo_id  := new.memo_id;
    select m.target_type, m.target_id, m.target_label, m.author_id
      into v_target_type, v_target_id, v_target_label, v_memo_author
      from edu.hani_memos m
     where m.id = new.memo_id;
  end if;

  v_excerpt := left(new.body, 120);

  select v.display_name into v_actor_name
    from edu.hani_viewers v where v.user_id = new.author_id;
  v_actor_name := coalesce(v_actor_name, split_part(coalesce(new.author_email, ''), '@', 1));

  foreach v_uid in array coalesce(new.mention_ids, '{}'::uuid[]) loop
    -- 나 자신에게는 보내지 않는다
    continue when v_uid = new.author_id;

    select v.display_name into v_name from edu.hani_viewers v where v.user_id = v_uid;

    insert into edu.hani_mentions
      (memo_id, reply_id, mentioned_id, mentioned_name, actor_id)
    values (v_memo_id, v_reply_id, v_uid, coalesce(v_name, '?'), new.author_id);

    -- 알림을 꺼 둔 사람에게는 보내지 않는다 (호출 기록은 남는다)
    continue when exists (select 1 from edu.hani_notification_prefs p
                           where p.user_id = v_uid and p.muted);

    insert into edu.hani_notifications
      (recipient_id, actor_id, actor_name, kind, memo_id, reply_id,
       target_type, target_id, target_label, excerpt)
    values (v_uid, new.author_id, v_actor_name, 'mention', v_memo_id, v_reply_id,
            v_target_type, v_target_id, v_target_label, v_excerpt);
  end loop;

  -- 답글이면 메모 작성자에게도 (본인 제외, 이미 호출로 받았으면 제외, 꺼 뒀으면 제외)
  if v_reply_id is not null
     and v_memo_author is not null
     and v_memo_author <> new.author_id
     and not (v_memo_author = any (coalesce(new.mention_ids, '{}'::uuid[])))
     and not exists (select 1 from edu.hani_notification_prefs p
                      where p.user_id = v_memo_author and p.muted)
  then
    insert into edu.hani_notifications
      (recipient_id, actor_id, actor_name, kind, memo_id, reply_id,
       target_type, target_id, target_label, excerpt)
    values (v_memo_author, new.author_id, v_actor_name, 'reply', v_memo_id, v_reply_id,
            v_target_type, v_target_id, v_target_label, v_excerpt);
  end if;

  return new;
end
$$;