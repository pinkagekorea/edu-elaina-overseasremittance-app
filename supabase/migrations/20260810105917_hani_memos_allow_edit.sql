-- 본문 수정을 연다. 단, 작성자와 작성시각은 여전히 못 고친다.
-- 고치면 edited_at 이 남아 "고쳤다"는 사실 자체는 지워지지 않는다.
alter table edu.hani_memos        add column if not exists edited_at timestamptz;
alter table edu.hani_memo_replies add column if not exists edited_at timestamptz;

comment on column edu.hani_memos.edited_at is '본문을 고친 시각. 서버가 찍으며 사람이 정할 수 없다.';

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
    new.edited_at    := null;
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  -- UPDATE : 작성 기록은 손대지 못한다
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;

  if tg_table_name = 'hani_memos' then
    new.target_type  := old.target_type;
    new.target_id    := old.target_id;
    new.target_label := old.target_label;
  else
    new.memo_id := old.memo_id;
  end if;

  -- 지운 글은 되살리지도, 고치지도 못한다
  if old.deleted_at is not null then
    new.body      := old.body;
    new.edited_at := old.edited_at;
  elsif new.body is distinct from old.body then
    new.edited_at := now();          -- 고친 시각은 서버가 찍는다
  else
    new.edited_at := old.edited_at;
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

-- 고치면서 새로 부른 사람에게도 알림이 가야 한다.
-- 이미 부른 사람에게 두 번 가지 않도록 걸러 넣는다.
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

  for r in select v.user_id, v.display_name from edu.hani_viewers v loop
    if position('@' || r.display_name in new.body) > 0
       and r.user_id <> new.author_id
       and not exists (
             select 1 from edu.hani_mentions x
              where x.mentioned_id = r.user_id
                and x.memo_id is not distinct from v_memo_id
                and x.reply_id is not distinct from v_reply_id)
    then
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

-- 고쳐서 사람을 새로 불렀을 때도 알림이 나가도록
drop trigger if exists hani_memos_fanout_edit on edu.hani_memos;
create trigger hani_memos_fanout_edit
  after update of body on edu.hani_memos
  for each row when (new.deleted_at is null)
  execute function edu.hani_fanout();

drop trigger if exists hani_memo_replies_fanout_edit on edu.hani_memo_replies;
create trigger hani_memo_replies_fanout_edit
  after update of body on edu.hani_memo_replies
  for each row when (new.deleted_at is null)
  execute function edu.hani_fanout();