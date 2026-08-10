-- ═══════════════════════════════════════════════════════════════
-- 멘션 2단계 — 글자(이름)와 번호(아이디)를 나눈다
--   · 본문에는 '@홍길동' 처럼 사람이 읽는 이름만 들어간다
--   · 누구를 불렀는지는 adom_mentions 에 사람 번호(uuid)로 따로 남긴다
--   · 알림은 서버 함수(security definer)만 만든다
-- 표 2개 추가: adom_viewers(화면 권한) · adom_notification_prefs(알림 끄기)
-- ═══════════════════════════════════════════════════════════════

-- ── 이 화면을 볼 수 있는 사람 ───────────────────────────────────
-- 8일차 규칙(로그인 + 관리자)을 표로 명시한 것. 관리자는 항상 이 안에 있다.
create table edu.adom_viewers (
  user_id      uuid        primary key,
  email        text        not null,
  display_name text        not null,
  added_by     uuid,
  created_at   timestamptz not null default now(),
  constraint adom_viewers_email_uniq unique (email),
  constraint adom_viewers_name_uniq  unique (display_name),
  -- 본문의 '@이름' 을 정확히 되짚으려면 이름에 공백·@ 가 없어야 한다
  constraint adom_viewers_name_shape check (display_name ~ '^[^@[:space:]]{1,32}$')
);

comment on table  edu.adom_viewers              is 'ADOM 화면을 볼 수 있는 사람. @ 목록·알림 대상은 여기서만 나온다.';
comment on column edu.adom_viewers.display_name is '본문에 "@이름" 으로 들어갈 표시 이름. 공백 불가, 중복 불가.';

-- ── 사람마다 알림 끄기 ──────────────────────────────────────────
create table edu.adom_notification_prefs (
  user_id    uuid        primary key,
  muted      boolean     not null default false,
  updated_at timestamptz not null default now()
);

comment on table edu.adom_notification_prefs is '알림 수신 여부. 본인 것만 읽고 쓸 수 있다.';

-- ── 멘션: 이메일 파싱 → 고른 사람 번호로 ────────────────────────
-- (표는 아직 0건이므로 값 손실 없음)
alter table edu.adom_mentions drop constraint adom_mentions_uniq;

alter table edu.adom_mentions
  alter column mentioned_email drop not null,
  alter column mentioned_id    set  not null,
  add   column mentioned_name  text;

alter table edu.adom_mentions
  add constraint adom_mentions_uniq
  unique nulls not distinct (memo_id, reply_id, mentioned_id);

comment on column edu.adom_mentions.mentioned_id   is '불린 사람의 번호(uuid). 알림은 이 값으로 보낸다.';
comment on column edu.adom_mentions.mentioned_name is '부를 때 본문에 쓰인 표시 이름. 사람이 읽는 쪽 기록.';

-- ── 알림: 어디서 · 누가 · 뭐라고 ────────────────────────────────
-- 메모가 지워져도 알림만 보고 내용을 알 수 있도록 값으로 저장한다.
alter table edu.adom_notifications
  add column target_label text,
  add column actor_name   text,
  add column excerpt      text;

comment on column edu.adom_notifications.target_label is '어디서 — 대상의 사람이 읽는 이름';
comment on column edu.adom_notifications.actor_name   is '누가 — 부른 사람의 표시 이름';
comment on column edu.adom_notifications.excerpt      is '뭐라고 — 본문 앞부분';

-- ── 본문 정규식 파싱 방식 제거 ──────────────────────────────────
-- 이제 누구를 불렀는지는 클라이언트가 고른 번호 목록으로 명시한다.
-- (트리거·함수만 제거하며 데이터는 건드리지 않는다)
drop trigger if exists adom_memos_fanout        on edu.adom_memos;
drop trigger if exists adom_memo_replies_fanout on edu.adom_memo_replies;
drop function if exists edu.adom_fanout();

-- 로그인만 하면 전체 계정 이메일을 받아 가던 함수 — 권한 모델이 생겼으므로 폐기
drop function if exists edu.adom_mention_candidates();

-- ── 알림 수정 잠금에 새 칼럼도 포함 ─────────────────────────────
create or replace function edu.adom_notification_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.id           := old.id;
  new.recipient_id := old.recipient_id;
  new.actor_id     := old.actor_id;
  new.kind         := old.kind;
  new.memo_id      := old.memo_id;
  new.reply_id     := old.reply_id;
  new.target_type  := old.target_type;
  new.target_id    := old.target_id;
  new.target_label := old.target_label;
  new.actor_name   := old.actor_name;
  new.excerpt      := old.excerpt;
  new.created_at   := old.created_at;

  if old.read_at is not null or new.read_at is null then
    new.read_at := old.read_at;      -- 읽음은 되돌릴 수 없다
  else
    new.read_at := now();
  end if;
  return new;
end
$$;

-- ── 관리자를 명단에 넣는다 (항상 볼 수 있어야 하므로) ───────────
insert into edu.adom_viewers (user_id, email, display_name, added_by)
select u.id, lower(u.email), 'adom', u.id
  from auth.users u
 where lower(u.email) = 'adom@pinkage.co.kr'
on conflict do nothing;