-- 알림에서 사람이 바꿀 수 있는 것은 '읽음 시각' 하나뿐이다.
-- 정책만으로는 어느 칸을 고치는지까지 막지 못하므로 트리거로 되돌린다.
create or replace function edu.hani_notification_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
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

  -- 읽음은 한 번만 찍히고, 시각은 서버가 정한다
  if new.read_at is not null and old.read_at is null then
    new.read_at := now();
  else
    new.read_at := old.read_at;
  end if;

  return new;
end
$$;

drop trigger if exists hani_notifications_guard on edu.hani_notifications;
create trigger hani_notifications_guard
  before update on edu.hani_notifications
  for each row execute function edu.hani_notification_guard();