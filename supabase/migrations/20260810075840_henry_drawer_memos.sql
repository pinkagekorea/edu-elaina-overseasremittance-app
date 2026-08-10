-- 서랍(메모) 기능 — edu 스키마, 공용 프로젝트라 전부 henry_ 접두사
-- 설계: docs/superpowers/specs/2026-08-10-henry-drawer-design.md

-- ── 1. 표 ──────────────────────────────────────────────────────

create table if not exists edu.henry_members (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  display_name text not null,
  role         text not null default 'member' check (role in ('member','admin')),
  created_at   timestamptz not null default now()
);

-- target_type 에 CHECK 를 걸지 않는다. 걸면 새 대상을 붙일 때마다
-- 마이그레이션이 필요해져서 "부품 하나로 여러 곳에" 목적과 어긋난다.
create table if not exists edu.henry_memos (
  id          bigint generated always as identity primary key,
  target_type text not null check (char_length(btrim(target_type)) between 1 and 40),
  target_id   text not null check (char_length(btrim(target_id))   between 1 and 200),
  body        text not null check (char_length(btrim(body))        between 1 and 4000),
  author_id   uuid not null default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  deleted_by  uuid references auth.users(id)
);

create table if not exists edu.henry_memo_replies (
  id         bigint generated always as identity primary key,
  memo_id    bigint not null references edu.henry_memos(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 4000),
  author_id  uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id)
);

-- 멘션은 메모에 달리거나 답글에 달린다. 둘 다이거나 둘 다 아니면 안 된다.
create table if not exists edu.henry_mentions (
  id           bigint generated always as identity primary key,
  memo_id      bigint references edu.henry_memos(id)        on delete cascade,
  reply_id     bigint references edu.henry_memo_replies(id) on delete cascade,
  mentioned_id uuid not null references auth.users(id) on delete cascade,
  actor_id     uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now(),
  constraint henry_mentions_one_parent check (num_nonnulls(memo_id, reply_id) = 1)
);

create table if not exists edu.henry_notifications (
  id           bigint generated always as identity primary key,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id     uuid not null references auth.users(id) on delete cascade,
  kind         text not null check (kind in ('mention','reply')),
  memo_id      bigint references edu.henry_memos(id)        on delete cascade,
  reply_id     bigint references edu.henry_memo_replies(id) on delete cascade,
  target_type  text not null,
  target_id    text not null,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);

-- ── 2. 인덱스 ──────────────────────────────────────────────────

create index if not exists henry_memos_target_idx
  on edu.henry_memos (target_type, target_id, created_at desc);
create index if not exists henry_memo_replies_memo_idx
  on edu.henry_memo_replies (memo_id, created_at);
create unique index if not exists henry_mentions_memo_uq
  on edu.henry_mentions (memo_id, mentioned_id)  where memo_id  is not null;
create unique index if not exists henry_mentions_reply_uq
  on edu.henry_mentions (reply_id, mentioned_id) where reply_id is not null;
create index if not exists henry_notifications_inbox_idx
  on edu.henry_notifications (recipient_id, read_at, created_at desc);

-- ── 3. 헬퍼 ────────────────────────────────────────────────────
-- SECURITY DEFINER 라야 henry_members 정책이 자기 자신을 조회하는
-- 무한 재귀에 걸리지 않는다.

create or replace function edu.henry_is_member()
returns boolean language sql stable security definer
set search_path = edu, pg_catalog as $$
  select exists (select 1 from edu.henry_members m where m.user_id = auth.uid());
$$;

create or replace function edu.henry_is_admin()
returns boolean language sql stable security definer
set search_path = edu, pg_catalog as $$
  select exists (
    select 1 from edu.henry_members m
    where m.user_id = auth.uid() and m.role = 'admin'
  );
$$;

-- ── 4. 불변 가드 ───────────────────────────────────────────────
-- 열 이름을 하나씩 비교하지 않고 통째로 비교한다. 나중에 열이 늘어도 자동 보호.

create or replace function edu.henry_guard_immutable()
returns trigger language plpgsql as $$
begin
  if (to_jsonb(old) - 'deleted_at' - 'deleted_by')
     is distinct from
     (to_jsonb(new) - 'deleted_at' - 'deleted_by') then
    raise exception '삭제 표시 외에는 수정할 수 없습니다 (본문·작성자·작성시각 고정)';
  end if;
  return new;
end; $$;

create or replace function edu.henry_guard_notification()
returns trigger language plpgsql as $$
begin
  if (to_jsonb(old) - 'read_at') is distinct from (to_jsonb(new) - 'read_at') then
    raise exception '알림은 읽음 표시 외에는 수정할 수 없습니다';
  end if;
  return new;
end; $$;

drop trigger if exists henry_memos_guard on edu.henry_memos;
create trigger henry_memos_guard before update on edu.henry_memos
  for each row execute function edu.henry_guard_immutable();

drop trigger if exists henry_memo_replies_guard on edu.henry_memo_replies;
create trigger henry_memo_replies_guard before update on edu.henry_memo_replies
  for each row execute function edu.henry_guard_immutable();

drop trigger if exists henry_notifications_guard on edu.henry_notifications;
create trigger henry_notifications_guard before update on edu.henry_notifications
  for each row execute function edu.henry_guard_notification();

-- ── 5. 알림 생성 ───────────────────────────────────────────────
-- SECURITY DEFINER 로만 알림이 생긴다. 사용자에게 INSERT 정책을 주지
-- 않으므로 알림을 위조할 수 없다.

create or replace function edu.henry_notify_mention()
returns trigger language plpgsql security definer
set search_path = edu, pg_catalog as $$
declare
  v_memo_id bigint;
  v_type    text;
  v_id      text;
begin
  if new.mentioned_id = new.actor_id then return new; end if;

  v_memo_id := coalesce(
    new.memo_id,
    (select r.memo_id from edu.henry_memo_replies r where r.id = new.reply_id)
  );
  select m.target_type, m.target_id into v_type, v_id
    from edu.henry_memos m where m.id = v_memo_id;

  insert into edu.henry_notifications
    (recipient_id, actor_id, kind, memo_id, reply_id, target_type, target_id)
  values
    (new.mentioned_id, new.actor_id, 'mention', new.memo_id, new.reply_id, v_type, v_id);
  return new;
end; $$;

create or replace function edu.henry_notify_reply()
returns trigger language plpgsql security definer
set search_path = edu, pg_catalog as $$
declare m record;
begin
  select author_id, target_type, target_id into m
    from edu.henry_memos where id = new.memo_id;
  if m.author_id = new.author_id then return new; end if;

  insert into edu.henry_notifications
    (recipient_id, actor_id, kind, memo_id, reply_id, target_type, target_id)
  values
    (m.author_id, new.author_id, 'reply', new.memo_id, new.id, m.target_type, m.target_id);
  return new;
end; $$;

drop trigger if exists henry_mentions_notify on edu.henry_mentions;
create trigger henry_mentions_notify after insert on edu.henry_mentions
  for each row execute function edu.henry_notify_mention();

drop trigger if exists henry_memo_replies_notify on edu.henry_memo_replies;
create trigger henry_memo_replies_notify after insert on edu.henry_memo_replies
  for each row execute function edu.henry_notify_reply();

-- ── 6. 권한: anon 은 0 ─────────────────────────────────────────

revoke all on edu.henry_members       from anon, authenticated, public;
revoke all on edu.henry_memos         from anon, authenticated, public;
revoke all on edu.henry_memo_replies  from anon, authenticated, public;
revoke all on edu.henry_mentions      from anon, authenticated, public;
revoke all on edu.henry_notifications from anon, authenticated, public;

revoke all on function edu.henry_is_member()  from anon, public;
revoke all on function edu.henry_is_admin()   from anon, public;

grant select, insert, update on edu.henry_members       to authenticated;
grant select, insert, update on edu.henry_memos         to authenticated;
grant select, insert, update on edu.henry_memo_replies  to authenticated;
grant select, insert         on edu.henry_mentions      to authenticated;
grant select,         update on edu.henry_notifications to authenticated;

grant execute on function edu.henry_is_member() to authenticated;
grant execute on function edu.henry_is_admin()  to authenticated;

-- ── 7. RLS ─────────────────────────────────────────────────────

alter table edu.henry_members       enable row level security;
alter table edu.henry_memos         enable row level security;
alter table edu.henry_memo_replies  enable row level security;
alter table edu.henry_mentions      enable row level security;
alter table edu.henry_notifications enable row level security;

-- 명단: 멤버만 본다. 외부 계정에 팀 명단이 안 보인다.
create policy henry_members_select on edu.henry_members
  for select to authenticated using (edu.henry_is_member());
create policy henry_members_insert on edu.henry_members
  for insert to authenticated with check (edu.henry_is_admin());
create policy henry_members_update on edu.henry_members
  for update to authenticated using (edu.henry_is_admin()) with check (edu.henry_is_admin());

-- 메모: 남의 이름으로 못 쓴다. 지우기(=deleted_at 찍기)는 본인과 관리자만.
create policy henry_memos_select on edu.henry_memos
  for select to authenticated using (edu.henry_is_member());
create policy henry_memos_insert on edu.henry_memos
  for insert to authenticated
  with check (edu.henry_is_member() and author_id = auth.uid());
create policy henry_memos_softdelete on edu.henry_memos
  for update to authenticated
  using      (edu.henry_is_member() and (author_id = auth.uid() or edu.henry_is_admin()))
  with check (edu.henry_is_member() and (author_id = auth.uid() or edu.henry_is_admin()));

create policy henry_memo_replies_select on edu.henry_memo_replies
  for select to authenticated using (edu.henry_is_member());
create policy henry_memo_replies_insert on edu.henry_memo_replies
  for insert to authenticated
  with check (edu.henry_is_member() and author_id = auth.uid());
create policy henry_memo_replies_softdelete on edu.henry_memo_replies
  for update to authenticated
  using      (edu.henry_is_member() and (author_id = auth.uid() or edu.henry_is_admin()))
  with check (edu.henry_is_member() and (author_id = auth.uid() or edu.henry_is_admin()));

-- 멘션: 사실 기록. 남 이름으로 부를 수 없고 수정·삭제 정책이 없다.
create policy henry_mentions_select on edu.henry_mentions
  for select to authenticated using (edu.henry_is_member());
create policy henry_mentions_insert on edu.henry_mentions
  for insert to authenticated
  with check (edu.henry_is_member() and actor_id = auth.uid());

-- 알림: 내 것만. INSERT 정책이 없어 위조 불가(트리거만 넣는다).
create policy henry_notifications_select on edu.henry_notifications
  for select to authenticated using (recipient_id = auth.uid());
create policy henry_notifications_read on edu.henry_notifications
  for update to authenticated
  using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

-- ── 8. 초기 명단 ───────────────────────────────────────────────
-- 기본은 막고 시작한다. 나머지는 필요할 때 관리자가 추가한다.

insert into edu.henry_members (user_id, email, display_name, role)
select u.id, lower(u.email), split_part(u.email, '@', 1),
       case when lower(u.email) = 'henry@pinkage.co.kr' then 'admin' else 'member' end
from auth.users u
where lower(u.email) in ('henry@pinkage.co.kr', 'henry-team@pinkage.co.kr')
on conflict (user_id) do nothing;
