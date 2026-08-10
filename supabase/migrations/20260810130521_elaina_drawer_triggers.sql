-- ═══════════════════════════════════════════════════════════════
-- 서랍 — 불변성 트리거 · 멘션/알림 자동 생성
--   사람이 보낸 author_id / created_at / mention_ids 는 전부 버리고
--   서버가 찍은 값만 남긴다.
-- ═══════════════════════════════════════════════════════════════

-- ── 본문에서 부른 사람의 번호만 뽑아 준다 ──────────────────────
-- 명단(elaina_viewers)은 아무에게도 열려 있지 않으므로 definer 로 대신 읽는다.
create or replace function edu.elaina_called_ids(p_body text)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(v.user_id order by v.display_name), '{}')
    from edu.elaina_viewers v
   where position('@' || v.display_name in coalesce(p_body, '')) > 0;
$$;

comment on function edu.elaina_called_ids(text) is
  '본문의 @이름을 명단과 대조해 uuid 목록으로. 글자와 번호를 나누는 자리.';

-- ── 작성자·작성시각 고정 · 본문 수정 불가 ──────────────────────
-- 메모와 답글이 같은 규칙이라 함수 하나를 두 표에 건다.
create or replace function edu.elaina_stamp()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_admin boolean := edu.elaina_is_admin();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 남길 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;                                     -- 작성자 = 지금 로그인한 사람
    new.author_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    new.created_at   := now();                                     -- 작성시각 = 서버 시각
    new.mention_ids  := edu.elaina_called_ids(new.body);           -- 부른 사람도 서버가 계산
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  -- 여기부터 UPDATE
  if old.deleted_at is not null then
    raise exception '이미 지운 글은 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  -- 무슨 값을 보내든 아래는 원래 값으로 되돌린다.
  -- 본문 수정 불가 — 남긴 뒤에는 못 고친다.
  new.body         := old.body;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.mention_ids  := old.mention_ids;

  if tg_table_name = 'elaina_memos' then
    new.target_type  := old.target_type;
    new.target_id    := old.target_id;
    new.target_label := old.target_label;
  else
    new.memo_id := old.memo_id;
  end if;

  -- 허용되는 변경은 '지움 표시' 하나뿐
  if new.deleted_at is not null then
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 글이거나 관리자일 때만 지울 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();          -- 시각은 서버가 정한다
    new.deleted_by := v_uid;
  else
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end
$$;

create trigger elaina_memos_stamp
  before insert or update on edu.elaina_memos
  for each row execute function edu.elaina_stamp();

create trigger elaina_memo_replies_stamp
  before insert or update on edu.elaina_memo_replies
  for each row execute function edu.elaina_stamp();

-- ── 멘션 기록 + 알림 생성 ──────────────────────────────────────
-- SECURITY DEFINER 로만 멘션·알림이 생긴다. 사용자에게 INSERT 권한을
-- 주지 않으므로 남의 이름으로 부르거나 알림을 위조할 수 없다.
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

  -- ── 부른 사람들 ─────────────────────────────────────────────
  foreach v_uid in array coalesce(new.mention_ids, '{}'::uuid[]) loop
    continue when v_uid = new.author_id;          -- 나 자신에게는 알리지 않는다

    select v.display_name into v_name
      from edu.elaina_viewers v where v.user_id = v_uid;

    insert into edu.elaina_mentions
      (memo_id, reply_id, mentioned_id, mentioned_name, actor_id)
    values (v_memo_id, v_reply_id, v_uid, coalesce(v_name, '?'), new.author_id)
    on conflict do nothing;

    insert into edu.elaina_notifications
      (recipient_id, actor_id, actor_name, kind, memo_id, reply_id,
       target_type, target_id, target_label, excerpt)
    values (v_uid, new.author_id, v_actor_name, 'mention', v_memo_id, v_reply_id,
            v_target_type, v_target_id, v_target_label, v_excerpt);
  end loop;

  -- ── 답글이면 메모 주인에게도 (본인 제외, 이미 불렸으면 제외) ──
  if v_reply_id is not null
     and v_memo_author is not null
     and v_memo_author <> new.author_id
     and not (v_memo_author = any (coalesce(new.mention_ids, '{}'::uuid[])))
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

create trigger elaina_memos_fanout
  after insert on edu.elaina_memos
  for each row execute function edu.elaina_fanout();

create trigger elaina_memo_replies_fanout
  after insert on edu.elaina_memo_replies
  for each row execute function edu.elaina_fanout();

-- ── 알림: 읽음 시각 하나만 바꿀 수 있다 ────────────────────────
-- 정책만으로는 어느 칸을 고치는지까지 막지 못하므로 트리거로 되돌린다.
create or replace function edu.elaina_notification_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.id           := old.id;
  new.recipient_id := old.recipient_id;
  new.actor_id     := old.actor_id;
  new.actor_name   := old.actor_name;
  new.kind         := old.kind;
  new.memo_id      := old.memo_id;
  new.reply_id     := old.reply_id;
  new.target_type  := old.target_type;
  new.target_id    := old.target_id;
  new.target_label := old.target_label;
  new.excerpt      := old.excerpt;
  new.created_at   := old.created_at;

  -- 읽음은 한 번만 찍히고, 되돌릴 수 없고, 시각은 서버가 정한다
  if old.read_at is null and new.read_at is not null then
    new.read_at := now();
  else
    new.read_at := old.read_at;
  end if;

  return new;
end
$$;

create trigger elaina_notifications_guard
  before update on edu.elaina_notifications
  for each row execute function edu.elaina_notification_guard();

-- ── 트리거 전용 함수는 EXECUTE 를 전부 회수한다 ────────────────
-- 트리거 실행은 EXECUTE 권한과 무관하다. REST 로 부를 이유가 없다.
revoke all on function edu.elaina_called_ids(text)        from public, anon, authenticated;
revoke all on function edu.elaina_stamp()                 from public, anon, authenticated;
revoke all on function edu.elaina_fanout()                from public, anon, authenticated;
revoke all on function edu.elaina_notification_guard()    from public, anon, authenticated;

notify pgrst, 'reload schema';