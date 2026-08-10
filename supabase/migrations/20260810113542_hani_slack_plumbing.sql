-- Step 5 : 호출을 슬랙까지 (배관만 · 점등은 준비되면)
-- 규칙 : 웹훅 주소 같은 비밀값은 코드/index.html/깃에 절대 안 들어간다. Vault 에만 둔다.
--        슬랙이 실패해도 메모는 멀쩡해야 한다 (best-effort).

-- 사람이 나중에 채울 짝 맞춤표. 지금은 비어 있고, 관리자만 채울 수 있다.
create table if not exists edu.hani_slack_map (
  user_id       uuid primary key references auth.users(id),
  slack_user_id text not null,
  added_by      uuid references auth.users(id),
  created_at    timestamptz not null default now()
);
comment on table edu.hani_slack_map is
  '우리 계정 ↔ 슬랙 사람 짝 맞춤표. 봇 토큰이 생기면 이 표를 보고 개인 DM 을 보낸다. 지금은 비어 있다.';

alter table edu.hani_slack_map enable row level security;
revoke all on edu.hani_slack_map from anon, public, authenticated;
grant select, insert, update on edu.hani_slack_map to authenticated;

drop policy if exists hani_slack_map_admin on edu.hani_slack_map;
create policy hani_slack_map_admin on edu.hani_slack_map
  for all to authenticated
  using (edu.hani_is_admin())
  with check (edu.hani_is_admin());

-- 알림이 슬랙으로 어떻게 갔는지 그대로 적어 둔다 (조용히 실패하지 않기 위해)
alter table edu.hani_notifications
  add column if not exists slack_status text
  check (slack_status in ('dm', 'channel', 'bell_only', 'error'));
comment on column edu.hani_notifications.slack_status is
  'dm = 개인 DM / channel = 채널 heads-up / bell_only = 벨만 / error = 보내다 실패';

-- 설정값(비밀 아님) — 딥링크에 쓸 앱 주소
create table if not exists edu.hani_app_config (
  key   text primary key,
  value text not null
);
alter table edu.hani_app_config enable row level security;
revoke all on edu.hani_app_config from anon, public, authenticated;
grant select on edu.hani_app_config to authenticated;

drop policy if exists hani_app_config_select on edu.hani_app_config;
create policy hani_app_config_select on edu.hani_app_config
  for select to authenticated using (true);

insert into edu.hani_app_config (key, value)
values ('base_url', 'http://127.0.0.1:8931/index.html')
on conflict (key) do nothing;

-- 알림 한 건이 만들어질 때만 heads-up 1건을 보낸다.
-- (1) 짝 맞춤표에 있고 봇 토큰이 있으면 개인 DM
-- (2) 없으면 채널 웹훅으로 heads-up
-- (3) 그것도 없으면 아무 것도 안 하고 벨만
create or replace function edu.hani_slack_headsup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_webhook  text;
  v_bot      text;
  v_slack_id text;
  v_base     text;
  v_link     text;
  v_text     text;
  v_status   text := 'bell_only';
begin
  begin
    select decrypted_secret into v_webhook
      from vault.decrypted_secrets where name = 'hani_slack_webhook';
    select decrypted_secret into v_bot
      from vault.decrypted_secrets where name = 'hani_slack_bot_token';
  exception when others then
    v_webhook := null; v_bot := null;         -- Vault 가 없어도 메모는 멀쩡해야 한다
  end;

  select s.slack_user_id into v_slack_id
    from edu.hani_slack_map s where s.user_id = new.recipient_id;

  select c.value into v_base from edu.hani_app_config c where c.key = 'base_url';
  v_base := coalesce(v_base, '');

  -- Step 2 에서 만든 그 주소를 그대로 쓴다
  v_link := v_base
         || '?brand=&t='   || new.target_type
         || '&id='         || new.target_id
         || '&drawer=1'
         || coalesce('&memo=' || new.memo_id::text, '');

  -- 어느 서랍 · 누가 · 뭐라고
  v_text := '🗄 ' || coalesce(new.target_label, new.target_id) || ' 서랍' || E'\n'
         || coalesce(new.actor_name, '누군가') || '님이 '
         || case when new.kind = 'mention' then '호출' else '답글' end
         || E'\n"' || coalesce(new.excerpt, '') || '"' || E'\n'
         || '<' || v_link || '|바로 열기>';

  begin
    if v_slack_id is not null and v_bot is not null then
      -- (1) 개인 DM — 봇 토큰과 짝 맞춤표가 둘 다 있을 때만 켜진다
      perform net.http_post(
        url     := 'https://slack.com/api/chat.postMessage',
        headers := jsonb_build_object(
                     'Content-Type', 'application/json; charset=utf-8',
                     'Authorization', 'Bearer ' || v_bot),
        body    := jsonb_build_object('channel', v_slack_id, 'text', v_text),
        timeout_milliseconds := 3000);
      v_status := 'dm';

    elsif v_webhook is not null then
      -- (2) 채널 heads-up
      perform net.http_post(
        url     := v_webhook,
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body    := jsonb_build_object('username', 'test', 'text', v_text),
        timeout_milliseconds := 3000);
      v_status := 'channel';

    else
      -- (3) 벨만
      v_status := 'bell_only';
    end if;
  exception when others then
    v_status := 'error';                       -- 슬랙이 죽어도 메모는 남는다
  end;

  update edu.hani_notifications set slack_status = v_status where id = new.id;
  return null;
end
$$;

drop trigger if exists hani_notifications_slack on edu.hani_notifications;
create trigger hani_notifications_slack
  after insert on edu.hani_notifications
  for each row execute function edu.hani_slack_headsup();

-- 메모를 남긴 사람에게 '무엇으로 갔는지' 그대로 알려 준다.
-- 알림 표는 받는 사람만 보므로, 보낸 사람용으로 이 함수만 연다.
create or replace function edu.hani_delivery_report(p_memo_id bigint)
returns table (받는사람 text, 경로 text)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(v.display_name, '알 수 없음'),
         coalesce(n.slack_status, 'bell_only')
    from edu.hani_notifications n
    left join edu.hani_viewers v on v.user_id = n.recipient_id
   where n.memo_id = p_memo_id
     and exists (select 1 from edu.hani_memos m
                  where m.id = p_memo_id and m.author_id = auth.uid())
   order by 1
$$;

revoke all on function edu.hani_delivery_report(bigint) from public, anon;
grant execute on function edu.hani_delivery_report(bigint) to authenticated;