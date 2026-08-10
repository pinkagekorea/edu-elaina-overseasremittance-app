-- ═══════════════════════════════════════════════════════════════
-- 서랍 — 불변성 트리거 · 멘션/알림 자동 생성 · 조회용 함수
-- ═══════════════════════════════════════════════════════════════

-- ── 메모: 작성자·작성시각·대상 고정, 수정은 본인만, 삭제는 본인+관리자 ──
create or replace function edu.adom_memo_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_admin boolean := edu.adom_is_admin();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 메모를 쓸 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;                                    -- 작성자 = 지금 로그인한 사람
    new.author_email := lower(nullif(auth.jwt() ->> 'email', ''));
    new.created_at   := now();                                    -- 작성시각 = 서버 시각
    new.edited_at    := null;
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  -- 여기부터 UPDATE
  if old.deleted_at is not null then
    raise exception '이미 삭제된 메모는 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  -- 무슨 값을 보내든 아래 항목은 원래 값으로 되돌린다
  new.id           := old.id;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.target_type  := old.target_type;
  new.target_id    := old.target_id;

  if new.deleted_at is not null then
    -- 삭제 — 본인 것이거나 관리자일 때만
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 메모이거나 관리자일 때만 삭제할 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();
    new.deleted_by := v_uid;
    new.body       := old.body;        -- 삭제하면서 내용을 바꿔치기할 수 없다
    new.edited_at  := old.edited_at;
    return new;
  end if;

  -- 본문 수정 — 본인만 (관리자라도 남의 글은 못 고친다)
  new.deleted_by := old.deleted_by;
  if new.body is distinct from old.body then
    if old.author_id is distinct from v_uid then
      raise exception '본인이 쓴 메모만 고칠 수 있습니다.' using errcode = '42501';
    end if;
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end
$$;

create trigger adom_memos_guard
  before insert or update on edu.adom_memos
  for each row execute function edu.adom_memo_guard();

-- ── 답글: 메모와 같은 규칙 ──────────────────────────────────────
create or replace function edu.adom_reply_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_admin boolean := edu.adom_is_admin();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 답글을 쓸 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;
    new.author_email := lower(nullif(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.edited_at    := null;
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  if old.deleted_at is not null then
    raise exception '이미 삭제된 답글은 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  new.id           := old.id;
  new.memo_id      := old.memo_id;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;

  if new.deleted_at is not null then
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 답글이거나 관리자일 때만 삭제할 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();
    new.deleted_by := v_uid;
    new.body       := old.body;
    new.edited_at  := old.edited_at;
    return new;
  end if;

  new.deleted_by := old.deleted_by;
  if new.body is distinct from old.body then
    if old.author_id is distinct from v_uid then
      raise exception '본인이 쓴 답글만 고칠 수 있습니다.' using errcode = '42501';
    end if;
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end
$$;

create trigger adom_memo_replies_guard
  before insert or update on edu.adom_memo_replies
  for each row execute function edu.adom_reply_guard();

-- ── 알림: read_at 만 바꿀 수 있고, 읽음은 되돌릴 수 없다 ─────────
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
  new.created_at   := old.created_at;

  if old.read_at is not null or new.read_at is null then
    new.read_at := old.read_at;
  else
    new.read_at := now();
  end if;
  return new;
end
$$;

create trigger adom_notifications_guard
  before update on edu.adom_notifications
  for each row execute function edu.adom_notification_guard();

-- ── 멘션 추출 + 알림 생성 ───────────────────────────────────────
-- 본문에서 @이메일 을 찾아 멘션을 남기고, 계정이 있으면 알림을 만든다.
-- 사용자가 멘션·알림을 직접 위조할 수 없도록 트리거로만 쓴다.
create or replace function edu.adom_fanout()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_memo_id     bigint;
  v_reply_id    bigint;
  v_target_type text;
  v_target_id   text;
  v_memo_author uuid;
  v_actor       uuid := new.author_id;
  v_email       text;
  v_uid         uuid;
begin
  if tg_table_name = 'adom_memos' then
    v_memo_id     := new.id;
    v_reply_id    := null;
    v_target_type := new.target_type;
    v_target_id   := new.target_id;
  else
    v_memo_id  := new.memo_id;
    v_reply_id := new.id;
    select m.target_type, m.target_id, m.author_id
      into v_target_type, v_target_id, v_memo_author
      from edu.adom_memos m
     where m.id = new.memo_id;

    -- 답글 알림 — 메모 작성자에게 (자기 글에 자기가 단 답글은 제외)
    if v_memo_author is not null and v_memo_author <> v_actor then
      insert into edu.adom_notifications
        (recipient_id, actor_id, kind, memo_id, reply_id, target_type, target_id)
      values
        (v_memo_author, v_actor, 'reply', v_memo_id, v_reply_id, v_target_type, v_target_id);
    end if;
  end if;

  for v_email in
    select distinct lower(m[1])
      from regexp_matches(new.body,
             '@([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', 'g') as m
  loop
    select u.id into v_uid
      from auth.users u
     where lower(u.email) = v_email
     limit 1;

    insert into edu.adom_mentions
      (memo_id, reply_id, mentioned_email, mentioned_id, actor_id)
    values
      (v_memo_id, v_reply_id, v_email, v_uid, v_actor)
    on conflict do nothing;

    -- 계정이 있고, 자기 자신이 아닐 때만 알림
    if v_uid is not null and v_uid <> v_actor then
      insert into edu.adom_notifications
        (recipient_id, actor_id, kind, memo_id, reply_id, target_type, target_id)
      values
        (v_uid, v_actor, 'mention', v_memo_id, v_reply_id, v_target_type, v_target_id);
    end if;
  end loop;

  return null;
end
$$;

create trigger adom_memos_fanout
  after insert on edu.adom_memos
  for each row execute function edu.adom_fanout();

create trigger adom_memo_replies_fanout
  after insert on edu.adom_memo_replies
  for each row execute function edu.adom_fanout();

-- ── 배지용 건수 조회 (여러 대상을 한 번에) ──────────────────────
-- security invoker → RLS 가 그대로 적용된다.
create or replace function edu.adom_memo_counts(
  p_target_type text,
  p_target_ids  text[]
)
returns table (target_id text, memo_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select m.target_id, count(*)
    from edu.adom_memos m
   where m.deleted_at is null
     and m.target_type = p_target_type
     and m.target_id = any(p_target_ids)
   group by m.target_id;
$$;

-- ── 멘션 자동완성 후보 ──────────────────────────────────────────
-- 팀원 이메일 목록. 로그인한 사용자에게만 응답한다.
create or replace function edu.adom_mention_candidates()
returns table (email text)
language sql
stable
security definer
set search_path = ''
as $$
  select lower(u.email)
    from auth.users u
   where auth.uid() is not null
     and u.email is not null
     and u.deleted_at is null
   order by 1;
$$;

-- 함수 실행 권한 — anon 에게는 주지 않는다
revoke all on function edu.adom_is_admin()                       from public, anon;
revoke all on function edu.adom_memo_counts(text, text[])        from public, anon;
revoke all on function edu.adom_mention_candidates()             from public, anon;

grant execute on function edu.adom_is_admin()                    to authenticated, service_role;
grant execute on function edu.adom_memo_counts(text, text[])     to authenticated, service_role;
grant execute on function edu.adom_mention_candidates()          to authenticated, service_role;

notify pgrst, 'reload schema';