-- 답글에서 누군가를 부르면 알림의 memo_id 가 비어 있었다.
-- 그래서 (1) 슬랙 딥링크가 안 붙고 (2) 알림을 눌러도 아무 데도 가지 않았다.
--
-- 근원: 이 함수는 답글 → 메모를 이미 풀어서(v_memo_id) 대상을 찾는 데 쓰면서도
-- 정작 알림에는 저장하지 않았다. 푼 값을 그대로 넣는다.
-- reply_id 도 그대로 둔다 — 어느 답글인지는 여전히 필요하다.
--
-- 기존 행 중 memo_id 가 빈 것은 0건이라 백필하지 않는다.
--
-- 적용됨: 2026-08-10 (Supabase 프로젝트 llbpdejavfndqcyfbylg / edu)

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
    (new.mentioned_id, new.actor_id, 'mention',
     v_memo_id,                      -- ★ new.memo_id 가 아니라 풀어낸 값
     new.reply_id, v_type, v_id);
  return new;
end $$;
