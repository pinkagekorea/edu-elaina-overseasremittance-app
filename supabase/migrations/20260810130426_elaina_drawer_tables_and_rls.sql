-- ═══════════════════════════════════════════════════════════════
-- 서랍(메모) — 표 5개 + RLS
--   설계: docs/superpowers/specs/2026-08-10-elaina-drawer-design.md
--   원칙: 표를 만드는 그 자리에서 RLS 를 켠다. anon 에는 아무 권한도 주지 않는다.
--   DELETE 권한은 누구에게도 주지 않는다 → 하드 삭제가 문법적으로 불가능하고,
--   지우기는 deleted_at 을 채우는 UPDATE 로만 이루어진다.
-- ═══════════════════════════════════════════════════════════════

-- ── 관리자 판별 ────────────────────────────────────────────────
-- 화면의 팻말이 아니라 DB 의 방어선. index.html 의 ADMIN_EMAIL 과 값을 맞출 것.
create or replace function edu.elaina_is_admin()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'elaina@pinkage.co.kr';
$$;

comment on function edu.elaina_is_admin() is
  '로그인한 사용자가 해외송금 대시보드 관리자인지. index.html 의 ADMIN_EMAIL 과 맞춘다.';

-- ── 1. 이 화면을 볼 수 있는 사람 = @ 로 부를 수 있는 사람 ──────
create table edu.elaina_viewers (
  user_id      uuid        primary key references auth.users(id) on delete cascade,
  email        text        not null,
  display_name text        not null,
  added_by     uuid        references auth.users(id),
  created_at   timestamptz not null default now(),
  constraint elaina_viewers_email_uniq unique (email),
  constraint elaina_viewers_name_uniq  unique (display_name),
  -- 본문의 '@이름' 을 정확히 되짚으려면 이름에 공백·@ 가 없어야 한다
  constraint elaina_viewers_name_shape check (display_name ~ '^[^@[:space:]]{1,32}$')
);

comment on table  edu.elaina_viewers              is
  '이 화면을 볼 수 있는 사람. @ 목록과 알림 대상은 여기서만 나온다.';
comment on column edu.elaina_viewers.display_name is
  '본문에 "@이름" 으로 들어갈 표시 이름. 공백 불가, 중복 불가.';

-- ── 2. 메모 ────────────────────────────────────────────────────
-- target_type 에 값 목록(CHECK in ...)을 걸지 않는다. 걸면 새 대상을 붙일 때마다
-- 마이그레이션이 필요해져서 "부품 하나로 여러 곳에" 목적과 어긋난다.
-- 모양만 검사한다.
create table edu.elaina_memos (
  id           bigint generated always as identity primary key,
  target_type  text not null check (target_type ~ '^[a-z][a-z0-9_]{0,31}$'),
  target_id    text not null check (length(btrim(target_id)) between 1 and 200),
  target_label text,
  body         text not null check (length(btrim(body)) between 1 and 4000),
  author_id    uuid not null default auth.uid() references auth.users(id),
  author_email text,
  mention_ids  uuid[] not null default '{}',
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  deleted_by   uuid references auth.users(id)
);

comment on table  edu.elaina_memos              is
  '서랍 메모. 어느 대상의 서랍인지는 (target_type, target_id) 로 구분한다.';
comment on column edu.elaina_memos.target_type  is
  '대상 종류. table = 표 전체. 새 종류를 붙일 때 마이그레이션이 필요 없다.';
comment on column edu.elaina_memos.target_id    is '대상 id. 부품에 넘겨주는 값과 같다.';
comment on column edu.elaina_memos.target_label is '사람이 읽는 대상 이름. 알림에 그대로 쓴다.';
comment on column edu.elaina_memos.author_id    is '작성자. 트리거가 auth.uid() 로 채우며 이후 변경 불가.';
comment on column edu.elaina_memos.created_at   is '작성시각. 트리거가 now() 로 채우며 이후 변경 불가.';
comment on column edu.elaina_memos.mention_ids  is
  '이 글에서 부른 사람들의 번호. 본문에는 이름만 남고, 알림은 이 값으로 보낸다.';
comment on column edu.elaina_memos.deleted_at   is '소프트 삭제 시각. 본인 또는 관리자만 찍을 수 있다.';

create index elaina_memos_target_idx
  on edu.elaina_memos (target_type, target_id, created_at desc);
create index elaina_memos_author_idx on edu.elaina_memos (author_id);

-- ── 3. 답글 ────────────────────────────────────────────────────
create table edu.elaina_memo_replies (
  id           bigint generated always as identity primary key,
  memo_id      bigint not null references edu.elaina_memos(id) on delete cascade,
  body         text not null check (length(btrim(body)) between 1 and 4000),
  author_id    uuid not null default auth.uid() references auth.users(id),
  author_email text,
  mention_ids  uuid[] not null default '{}',
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  deleted_by   uuid references auth.users(id)
);

comment on table edu.elaina_memo_replies is '메모에 달리는 답글. 팝업 오른쪽 칸에 표시된다.';

create index elaina_memo_replies_memo_idx on edu.elaina_memo_replies (memo_id, created_at);

-- ── 4. 멘션 (누가 누구를 불렀나) ───────────────────────────────
-- 트리거만 넣는다. 사용자에게는 INSERT 권한도 정책도 주지 않는다.
create table edu.elaina_mentions (
  id             bigint generated always as identity primary key,
  memo_id        bigint references edu.elaina_memos(id)        on delete cascade,
  reply_id       bigint references edu.elaina_memo_replies(id) on delete cascade,
  mentioned_id   uuid not null references auth.users(id) on delete cascade,
  mentioned_name text not null,
  actor_id       uuid not null references auth.users(id),
  created_at     timestamptz not null default now(),
  constraint elaina_mentions_one_source check (num_nonnulls(memo_id, reply_id) = 1),
  constraint elaina_mentions_uniq
    unique nulls not distinct (memo_id, reply_id, mentioned_id)
);

comment on table  edu.elaina_mentions                is
  '본문의 @이름에서 트리거가 뽑아낸 호출 기록. 사용자가 직접 쓰지 않는다.';
comment on column edu.elaina_mentions.mentioned_name is '부를 때 본문에 쓰인 표시 이름.';

-- ── 5. 알림 ────────────────────────────────────────────────────
-- 메모가 지워져도 알림만 보고 무슨 일이었는지 알 수 있도록 값으로 저장한다.
create table edu.elaina_notifications (
  id           bigint generated always as identity primary key,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id     uuid not null references auth.users(id) on delete cascade,
  actor_name   text,
  kind         text not null check (kind in ('mention', 'reply')),
  memo_id      bigint references edu.elaina_memos(id)        on delete cascade,
  reply_id     bigint references edu.elaina_memo_replies(id) on delete cascade,
  target_type  text not null,
  target_id    text not null,
  target_label text,
  excerpt      text,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);

comment on table  edu.elaina_notifications              is
  '멘션·답글 알림. 트리거만 만들 수 있고, 받는 사람만 읽음 처리할 수 있다.';
comment on column edu.elaina_notifications.target_label is '어디서 — 대상의 사람이 읽는 이름';
comment on column edu.elaina_notifications.actor_name   is '누가 — 부른 사람의 표시 이름';
comment on column edu.elaina_notifications.excerpt      is '뭐라고 — 본문 앞부분';

create index elaina_notifications_inbox_idx
  on edu.elaina_notifications (recipient_id, read_at, created_at desc);

-- ── 화면 권한 판정 ─────────────────────────────────────────────
-- SECURITY DEFINER 인 이유: 이 함수를 정책 안에서 부르는데, 명단 표를
-- 호출자 권한으로 읽으면 정책이 자기 자신을 다시 부르는 재귀가 생긴다.
create or replace function edu.elaina_can_view(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_uid is not null
     and exists (select 1 from edu.elaina_viewers v where v.user_id = p_uid);
$$;

comment on function edu.elaina_can_view(uuid) is
  '이 사람이 서랍을 볼 수 있는가. 명단(elaina_viewers)에 있으면 볼 수 있다.';

-- ═══════════════════════════════════════════════════════════════
-- RLS — 표를 만든 그 자리에서 바로 켠다
-- ═══════════════════════════════════════════════════════════════

alter table edu.elaina_viewers       enable row level security;
alter table edu.elaina_memos         enable row level security;
alter table edu.elaina_memo_replies  enable row level security;
alter table edu.elaina_mentions      enable row level security;
alter table edu.elaina_notifications enable row level security;

-- 스키마 기본 권한으로 딸려왔을 수 있는 권한을 전부 걷어낸다.
-- anon 은 이 뒤로 아무것도 받지 않는다.
revoke all on edu.elaina_viewers, edu.elaina_memos, edu.elaina_memo_replies,
              edu.elaina_mentions, edu.elaina_notifications
  from anon, authenticated, public;

grant usage on schema edu to authenticated;

-- ── 명단: 표 자체는 아무에게도 열지 않는다 ─────────────────────
-- 권한도 정책도 없다. 이름은 elaina_mention_list() 로만 나간다.
-- (계정 18개의 이메일이 로그인한 누구에게나 보이지 않게 하기 위해서다)

-- ── 메모 ───────────────────────────────────────────────────────
grant select, insert, update on edu.elaina_memos to authenticated;

-- 읽기: 명단에 있는 사람은 서랍을 함께 본다 (팀의 기록이므로).
-- 지워진 것도 "지워짐"으로 표시하기 위해 읽는다.
create policy elaina_memos_select on edu.elaina_memos
  for select to authenticated
  using (edu.elaina_can_view(auth.uid()));

-- 쓰기: 남의 이름으로는 쓸 수 없다
create policy elaina_memos_insert on edu.elaina_memos
  for insert to authenticated
  with check (author_id = auth.uid() and edu.elaina_can_view(auth.uid()));

-- 수정: 본인 또는 관리자. 트리거가 '삭제 표시' 외의 변경을 되돌린다.
create policy elaina_memos_update on edu.elaina_memos
  for update to authenticated
  using      ((author_id = auth.uid() or edu.elaina_is_admin())
              and edu.elaina_can_view(auth.uid()))
  with check ((author_id = auth.uid() or edu.elaina_is_admin())
              and edu.elaina_can_view(auth.uid()));

-- DELETE 정책은 만들지 않는다 → 진짜 삭제는 누구도 못 한다

-- ── 답글 ───────────────────────────────────────────────────────
grant select, insert, update on edu.elaina_memo_replies to authenticated;

create policy elaina_replies_select on edu.elaina_memo_replies
  for select to authenticated
  using (edu.elaina_can_view(auth.uid()));

create policy elaina_replies_insert on edu.elaina_memo_replies
  for insert to authenticated
  with check (author_id = auth.uid() and edu.elaina_can_view(auth.uid()));

create policy elaina_replies_update on edu.elaina_memo_replies
  for update to authenticated
  using      ((author_id = auth.uid() or edu.elaina_is_admin())
              and edu.elaina_can_view(auth.uid()))
  with check ((author_id = auth.uid() or edu.elaina_is_admin())
              and edu.elaina_can_view(auth.uid()));

-- ── 멘션: 읽기만 ───────────────────────────────────────────────
-- INSERT 권한도 정책도 없으므로 SECURITY DEFINER 트리거만 넣을 수 있다.
grant select on edu.elaina_mentions to authenticated;

create policy elaina_mentions_select on edu.elaina_mentions
  for select to authenticated
  using (edu.elaina_can_view(auth.uid()));

-- ── 알림: 내 것만 ──────────────────────────────────────────────
-- 만들기는 트리거만(정책 없음), 고치기는 읽음 표시만(트리거가 나머지를 되돌린다).
grant select, update on edu.elaina_notifications to authenticated;

create policy elaina_notifications_select on edu.elaina_notifications
  for select to authenticated
  using (recipient_id = auth.uid());

create policy elaina_notifications_read on edu.elaina_notifications
  for update to authenticated
  using      (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

-- ── 함수 실행 권한 — anon 에는 주지 않는다 ─────────────────────
revoke all on function edu.elaina_is_admin()        from public, anon;
revoke all on function edu.elaina_can_view(uuid)    from public, anon;

grant execute on function edu.elaina_is_admin()     to authenticated, service_role;
grant execute on function edu.elaina_can_view(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';