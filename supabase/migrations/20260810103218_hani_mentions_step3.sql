-- 9일차 Step 3 : @호출 · 알림
-- 글에는 @이름, 저장은 번호(uuid). 이름→번호 변환은 사람이 아니라 트리거가 한다.

-- 이 화면을 볼 수 있는 사람 = @ 로 부를 수 있는 사람 (8일차 권한을 그대로 물려받는다)
create table if not exists edu.hani_viewers (
  user_id      uuid primary key references auth.users(id),
  email        text not null unique,
  display_name text not null unique check (display_name ~ '^[^@[:space:]]{1,32}$'),
  added_by     uuid references auth.users(id),
  created_at   timestamptz not null default now()
);
comment on table  edu.hani_viewers              is '이 화면을 볼 수 있는 사람. @ 목록과 알림 대상은 여기서만 나온다.';
comment on column edu.hani_viewers.display_name is '본문에 "@이름" 으로 들어갈 표시 이름. 공백 불가, 중복 불가.';

-- 명단은 이메일로 찾아 넣는다 (번호를 코드에 박지 않는다)
insert into edu.hani_viewers (user_id, email, display_name)
select u.id, lower(u.email), v.display_name
  from (values ('hani@pinkage.co.kr', '하니'),
               ('daizy@pinkage.co.kr', '데이지')) as v(email, display_name)
  join auth.users u on lower(u.email) = v.email
on conflict (user_id) do nothing;

-- 트리거가 본문에서 뽑아낸 호출 기록 (사람이 직접 쓰지 않는다)
create table if not exists edu.hani_mentions (
  id             bigint generated always as identity primary key,
  memo_id        bigint references edu.hani_memos(id) on delete cascade,
  reply_id       bigint references edu.hani_memo_replies(id) on delete cascade,
  mentioned_id   uuid not null references auth.users(id),
  mentioned_name text not null,
  actor_id       uuid not null references auth.users(id),
  created_at     timestamptz not null default now()
);
comment on column edu.hani_mentions.mentioned_id   is '불린 사람의 번호(uuid). 알림은 이 값으로 보낸다.';
comment on column edu.hani_mentions.mentioned_name is '본문에 쓰인 표시 이름. 사람이 읽는 쪽 기록.';

-- 알림 — 트리거만 만들 수 있고, 받는 사람만 읽음 처리할 수 있다
create table if not exists edu.hani_notifications (
  id           bigint generated always as identity primary key,
  recipient_id uuid not null references auth.users(id),
  actor_id     uuid not null references auth.users(id),
  actor_name   text,
  kind         text not null check (kind in ('mention', 'reply')),
  memo_id      bigint references edu.hani_memos(id) on delete cascade,
  reply_id     bigint references edu.hani_memo_replies(id) on delete cascade,
  target_type  text not null,
  target_id    text not null,
  target_label text,
  excerpt      text,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);
comment on column edu.hani_notifications.target_label is '어디서 — 대상의 사람이 읽는 이름';
comment on column edu.hani_notifications.actor_name   is '누가 — 부른 사람의 표시 이름';
comment on column edu.hani_notifications.excerpt      is '뭐라고 — 본문 앞부분';

create index if not exists hani_notifications_inbox_idx
  on edu.hani_notifications (recipient_id, read_at, created_at desc);

-- @ 목록 : 명단에 있는 사람에게만, 이름만 돌려준다.
-- security definer — 표를 통째로 열어 주지 않고 이 함수로만 내보낸다.
create or replace function edu.hani_mention_list()
returns table (display_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select v.display_name
    from edu.hani_viewers v
   where exists (select 1 from edu.hani_viewers me where me.user_id = auth.uid())
   order by v.display_name
$$;

revoke all on function edu.hani_mention_list() from public, anon;
grant execute on function edu.hani_mention_list() to authenticated;

-- 본문에서 @이름 을 찾아 알림을 만든다.
-- security definer — 알림 표에는 사람의 권한으로는 한 줄도 못 넣는다.
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
  r              record;
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

  -- 명단에 있는 이름만 찾는다. 명단 밖의 @이름 은 그냥 글자로 남는다.
  for r in select v.user_id, v.display_name from edu.hani_viewers v loop
    if position('@' || r.display_name in new.body) > 0 and r.user_id <> new.author_id then
      insert into edu.hani_mentions
        (memo_id, reply_id, mentioned_id, mentioned_name, actor_id)
      values (v_memo_id, v_reply_id, r.user_id, r.display_name, new.author_id);

      insert into edu.hani_notifications
        (recipient_id, actor_id, actor_name, kind, memo_id, reply_id,
         target_type, target_id, target_label, excerpt)
      values (r.user_id, new.author_id, v_actor_name, 'mention', v_memo_id, v_reply_id,
              v_target_type, v_target_id, v_target_label, v_excerpt);
    end if;
  end loop;

  -- 답글이면 메모 작성자에게도 알린다 (본인 제외, 이미 호출로 받았으면 제외)
  if v_reply_id is not null
     and v_memo_author is not null
     and v_memo_author <> new.author_id
     and not exists (select 1 from edu.hani_notifications n
                      where n.reply_id = v_reply_id and n.recipient_id = v_memo_author)
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

drop trigger if exists hani_memos_fanout on edu.hani_memos;
create trigger hani_memos_fanout
  after insert on edu.hani_memos
  for each row execute function edu.hani_fanout();

drop trigger if exists hani_memo_replies_fanout on edu.hani_memo_replies;
create trigger hani_memo_replies_fanout
  after insert on edu.hani_memo_replies
  for each row execute function edu.hani_fanout();

-- RLS : 표를 만든 그 자리에서 켠다 -------------------------------------------
alter table edu.hani_viewers       enable row level security;
alter table edu.hani_mentions      enable row level security;
alter table edu.hani_notifications enable row level security;

revoke all on edu.hani_viewers       from anon, public, authenticated;
revoke all on edu.hani_mentions      from anon, public, authenticated;
revoke all on edu.hani_notifications from anon, public, authenticated;

-- 명단 표 자체는 아무에게도 열지 않는다. 이름은 위 함수로만 나간다.
-- (정책을 하나도 만들지 않으면 authenticated 도 한 줄을 못 본다)

grant select on edu.hani_mentions to authenticated;
drop policy if exists hani_mentions_select on edu.hani_mentions;
create policy hani_mentions_select on edu.hani_mentions
  for select to authenticated
  using (mentioned_id = (select auth.uid()) or actor_id = (select auth.uid()));

-- 알림 : 받는 사람만 본다. 만들기는 트리거만(정책 없음), 고치기는 읽음 표시만.
grant select, update on edu.hani_notifications to authenticated;

drop policy if exists hani_notifications_select on edu.hani_notifications;
create policy hani_notifications_select on edu.hani_notifications
  for select to authenticated
  using (recipient_id = (select auth.uid()));

drop policy if exists hani_notifications_read on edu.hani_notifications;
create policy hani_notifications_read on edu.hani_notifications
  for update to authenticated
  using (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));