-- ═══════════════════════════════════════════════════════════════
-- 서랍(메모) 기능 — 표 4개 + 관리자 판별 함수
--   edu.adom_memos           메모   (대상: target_type + target_id)
--   edu.adom_memo_replies    답글
--   edu.adom_mentions        멘션   (본문의 @이메일에서 자동 추출)
--   edu.adom_notifications   알림   (멘션·답글 발생 시 자동 생성)
-- 삭제는 소프트 삭제(deleted_at)로만 한다 — 팀의 판단을 기록으로 남기는 것이 목적.
-- ═══════════════════════════════════════════════════════════════

-- 관리자 판별 — index.html 의 ADMIN_EMAIL 과 같은 값을 쓴다.
create or replace function edu.adom_is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'adom@pinkage.co.kr';
$$;

comment on function edu.adom_is_admin() is
  '로그인한 사용자가 ADOM 관리자인지. index.html 의 ADMIN_EMAIL 과 값을 맞출 것.';

-- ── 메모 ────────────────────────────────────────────────────────
create table edu.adom_memos (
  id           bigint generated always as identity primary key,
  target_type  text not null check (target_type ~ '^[a-z][a-z0-9_]{0,31}$'),
  target_id    text not null check (length(btrim(target_id)) between 1 and 200),
  body         text not null check (length(btrim(body)) between 1 and 4000),
  author_id    uuid not null default auth.uid(),
  author_email text,
  created_at   timestamptz not null default now(),
  edited_at    timestamptz,
  deleted_at   timestamptz,
  deleted_by   uuid
);

comment on table  edu.adom_memos            is '서랍 메모. 어느 대상의 메모인지는 (target_type, target_id) 로 구분한다.';
comment on column edu.adom_memos.target_type is '대상 종류. dashboard = 현황판 전체, product = 개별 상품.';
comment on column edu.adom_memos.target_id   is '대상 id. 부품에 넘겨주는 값과 같다.';
comment on column edu.adom_memos.author_id   is '작성자. 트리거가 auth.uid() 로 채우며 이후 변경 불가.';
comment on column edu.adom_memos.created_at  is '작성시각. 트리거가 now() 로 채우며 이후 변경 불가.';
comment on column edu.adom_memos.deleted_at  is '소프트 삭제 시각. 본인 또는 관리자만 설정할 수 있다.';

create index adom_memos_target_idx  on edu.adom_memos (target_type, target_id, created_at desc);
create index adom_memos_author_idx  on edu.adom_memos (author_id);

-- ── 답글 ────────────────────────────────────────────────────────
create table edu.adom_memo_replies (
  id           bigint generated always as identity primary key,
  memo_id      bigint not null references edu.adom_memos(id) on delete cascade,
  body         text not null check (length(btrim(body)) between 1 and 4000),
  author_id    uuid not null default auth.uid(),
  author_email text,
  created_at   timestamptz not null default now(),
  edited_at    timestamptz,
  deleted_at   timestamptz,
  deleted_by   uuid
);

comment on table edu.adom_memo_replies is '메모에 달리는 답글. 팝업 오른쪽 칸에 표시된다.';

create index adom_memo_replies_memo_idx on edu.adom_memo_replies (memo_id, created_at);

-- ── 멘션 ────────────────────────────────────────────────────────
create table edu.adom_mentions (
  id              bigint generated always as identity primary key,
  memo_id         bigint references edu.adom_memos(id)        on delete cascade,
  reply_id        bigint references edu.adom_memo_replies(id) on delete cascade,
  mentioned_email text not null,
  mentioned_id    uuid,
  actor_id        uuid not null default auth.uid(),
  created_at      timestamptz not null default now(),
  constraint adom_mentions_one_source check (num_nonnulls(memo_id, reply_id) = 1),
  constraint adom_mentions_uniq unique nulls not distinct (memo_id, reply_id, mentioned_email)
);

comment on table  edu.adom_mentions                 is '본문의 @이메일에서 트리거가 자동 추출한 멘션. 사용자가 직접 쓰지 않는다.';
comment on column edu.adom_mentions.mentioned_id    is '해당 이메일의 계정 id. 계정이 없으면 null 이고 알림도 만들지 않는다.';

create index adom_mentions_email_idx on edu.adom_mentions (mentioned_email);

-- ── 알림 ────────────────────────────────────────────────────────
create table edu.adom_notifications (
  id           bigint generated always as identity primary key,
  recipient_id uuid not null,
  actor_id     uuid not null,
  kind         text not null check (kind in ('mention', 'reply')),
  memo_id      bigint references edu.adom_memos(id)        on delete cascade,
  reply_id     bigint references edu.adom_memo_replies(id) on delete cascade,
  target_type  text not null,
  target_id    text not null,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);

comment on table edu.adom_notifications is '멘션·답글 알림. 트리거만 만들 수 있고, 받는 사람만 읽음 처리할 수 있다.';

create index adom_notifications_inbox_idx
  on edu.adom_notifications (recipient_id, created_at desc)
  where read_at is null;