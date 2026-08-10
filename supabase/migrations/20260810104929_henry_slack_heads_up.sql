-- 알림이 만들어질 때 슬랙에 heads-up 1건.
--
-- 웹훅 주소는 코드에도 index.html 에도 git 에도 넣지 않는다. Vault 에만 둔다.
-- 관리자가 아래 두 값을 직접 넣는다 (README 에 절차를 적어 둔다):
--   henry_slack_webhook  — 공유 채널 웹훅 주소 (비밀)
--   henry_app_base_url   — 배포 주소. 딥링크를 만들 때 앞에 붙는다
--
-- best-effort: 슬랙이 어떤 이유로 실패해도 메모 저장을 깨뜨리지 않는다.
--   1) pg_net 은 비동기다. 큐에 넣기만 하고 응답을 기다리지 않는다
--   2) 그마저도 EXCEPTION 으로 감싼다. 실패하면 상태만 남기고 넘어간다

-- ── 1. 배달 상태 ───────────────────────────────────────────────
-- 메모를 남긴 사람에게 '슬랙으로 감 / 벨로만 감' 을 보여주려면 흔적이 필요하다.
alter table edu.henry_notifications
  add column if not exists slack_status     text,
  add column if not exists slack_request_id bigint;

comment on column edu.henry_notifications.slack_status is
  'queued=슬랙 큐에 실림, no_webhook=웹훅 미설정, error=보내다 실패. null=아직 판정 전';

-- ── 2. 설정 읽기 ───────────────────────────────────────────────
-- Vault 는 postgres 만 읽는다. 그래서 SECURITY DEFINER 로 감싸고
-- 아무에게도 EXECUTE 를 주지 않는다 (트리거만 쓴다).
create or replace function edu.henry_secret(p_name text)
returns text language sql stable security definer
set search_path = vault, pg_catalog as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_name limit 1;
$$;

revoke all on function edu.henry_secret(text) from anon, authenticated, public;

-- ── 3. 슬랙 heads-up ───────────────────────────────────────────
create or replace function edu.henry_slack_heads_up()
returns trigger language plpgsql security definer
set search_path = edu, public, pg_catalog as $$
declare
  v_hook   text;
  v_base   text;
  v_actor  text;
  v_to     text;
  v_body   text;
  v_link   text;
  v_head   text;
  v_text   text;
  v_req    bigint;
begin
  v_hook := edu.henry_secret('henry_slack_webhook');

  -- 웹훅이 아직 없으면 조용히 벨로만 간다. 이것은 오류가 아니다.
  if v_hook is null or btrim(v_hook) = '' then
    new.slack_status := 'no_webhook';
    return new;
  end if;

  -- 누가 / 누구를
  select display_name into v_actor from edu.henry_members where user_id = new.actor_id;
  select display_name into v_to    from edu.henry_members where user_id = new.recipient_id;
  v_actor := coalesce(v_actor, '(알 수 없음)');
  v_to    := coalesce(v_to,    '(알 수 없음)');

  -- 뭐라고 — 답글 알림이면 답글 본문, 메모 멘션이면 메모 본문
  if new.reply_id is not null then
    select body into v_body from edu.henry_memo_replies where id = new.reply_id;
  else
    select body into v_body from edu.henry_memos where id = new.memo_id;
  end if;
  v_body := coalesce(v_body, '');
  if char_length(v_body) > 180 then
    v_body := left(v_body, 180) || '…';
  end if;

  v_head := case new.kind
              when 'mention' then format('*%s* 님이 *%s* 님을 불렀습니다', v_actor, v_to)
              else                format('*%s* 님이 *%s* 님의 메모에 답글을 남겼습니다', v_actor, v_to)
            end;

  -- 딥링크. 배포 주소가 없으면 링크 없이 보낸다 (알림 자체는 살린다).
  v_base := edu.henry_secret('henry_app_base_url');
  if v_base is not null and btrim(v_base) <> '' and new.memo_id is not null then
    v_link := format('%s?drawer=1&memo=%s', rtrim(btrim(v_base), '/'), new.memo_id);
    v_link := format('%s<%s|→ 그 메모 열기>', E'\n', v_link);
  else
    v_link := '';
  end if;

  v_text := format(
    E'🗄 서랍 · %s · %s\n%s\n>%s%s',
    new.target_type, new.target_id, v_head,
    replace(v_body, E'\n', E'\n>'),      -- 인용 블록이 여러 줄에서도 유지되게
    v_link
  );

  select net.http_post(
           url     := v_hook,
           body    := jsonb_build_object('text', v_text),
           headers := '{"Content-Type": "application/json"}'::jsonb
         ) into v_req;

  new.slack_status     := 'queued';
  new.slack_request_id := v_req;
  return new;

exception when others then
  -- 슬랙 때문에 메모가 안 저장되는 일은 없어야 한다.
  new.slack_status := 'error';
  return new;
end $$;

revoke all on function edu.henry_slack_heads_up() from anon, authenticated, public;

drop trigger if exists henry_notifications_slack on edu.henry_notifications;
create trigger henry_notifications_slack
  before insert on edu.henry_notifications
  for each row execute function edu.henry_slack_heads_up();

-- ── 4. 배달 결과 보고 ──────────────────────────────────────────
-- 알림 행은 받는 사람만 볼 수 있다(RLS). 그래서 글쓴이는 자기가 만든 알림이
-- 어떻게 갔는지 직접 못 읽는다. 자기가 actor 인 것만 세어 주는 창구를 연다.
create or replace function edu.henry_delivery_report(
  p_memo_id bigint default null, p_reply_id bigint default null)
returns table (slack integer, bell integer)
language sql stable security definer
set search_path = edu, pg_catalog as $$
  select
    count(*) filter (where n.slack_status = 'queued')::int,
    count(*) filter (where n.slack_status is distinct from 'queued')::int
  from edu.henry_notifications n
  where n.actor_id = auth.uid()             -- 남의 배달 결과는 못 본다
    and (p_memo_id  is null or n.memo_id  = p_memo_id)
    and (p_reply_id is null or n.reply_id = p_reply_id)
    and (p_memo_id is not null or p_reply_id is not null);
$$;

revoke all on function edu.henry_delivery_report(bigint, bigint) from anon, public;
grant execute on function edu.henry_delivery_report(bigint, bigint) to authenticated;
