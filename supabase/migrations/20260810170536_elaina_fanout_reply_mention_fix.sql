-- 버그: 답글에서 누군가를 부르면 답글 저장 자체가 실패했다.
--
--   ERROR 23514: new row for relation "elaina_mentions"
--                violates check constraint "elaina_mentions_one_source"
--
-- elaina_mentions 는 '메모에 달린 호출' 이거나 '답글에 달린 호출' 이거나
-- 둘 중 하나여야 한다(num_nonnulls(memo_id, reply_id) = 1). 그런데
-- fanout 이 답글일 때 알림 딥링크용으로 풀어 둔 v_memo_id 를 멘션 기록에도
-- 그대로 같이 넣어 둘 다 채워지고 있었다.
--
-- 멘션에는 출처 하나만 적는다. 어느 메모에 속한 답글인지는 알림 행이
-- memo_id 로 이미 들고 있으므로 딥링크는 그대로 동작한다.
--
-- (멘션 없는 답글은 이 줄을 타지 않아 지금까지 정상이었다.)

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

    -- 호출 기록은 알림을 껐어도 남긴다.
    -- 출처는 하나만 적는다 — 답글이면 reply_id 만, 메모면 memo_id 만.
    insert into edu.elaina_mentions
      (memo_id, reply_id, mentioned_id, mentioned_name, actor_id)
    values (case when v_reply_id is null then v_memo_id end,
            v_reply_id, v_uid, coalesce(v_name, '?'), new.author_id)
    on conflict do nothing;

    continue when exists (select 1 from edu.elaina_notification_prefs p
                           where p.user_id = v_uid and p.muted);

    -- 알림은 memo_id 를 계속 들고 간다. 딥링크가 그 값을 쓴다.
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

revoke all on function edu.elaina_fanout() from public, anon, authenticated;

notify pgrst, 'reload schema';