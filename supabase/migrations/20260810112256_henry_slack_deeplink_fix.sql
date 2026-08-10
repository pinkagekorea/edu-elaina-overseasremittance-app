-- 딥링크가 안 붙던 원인: henry_app_base_url 이 등록되지 않아 링크 분기가 통째로 빠졌다.
-- 슬랙 전송 자체는 정상(HTTP 200)이었다.
--
-- 두 가지를 한다.
--   1) 배포 주소를 설정값으로 심는다 (하드코딩 아님 — Vault 에서 읽는다)
--   2) 메시지 조립을 트리거에서 함수로 뺀다. 트리거 안에 묻혀 있으면
--      실제로 슬랙에 쏘지 않고는 링크가 붙었는지 확인할 방법이 없다.

-- ── 1. 배포 주소 ───────────────────────────────────────────────
-- 이미 넣어 두었다면 건드리지 않는다. 사람이 바꾼 값이 이긴다.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'henry_app_base_url') then
    perform vault.create_secret(
      'https://edu-henry-youtube-app.netlify.app',
      'henry_app_base_url',
      '서랍 딥링크 앞에 붙는 배포 주소');
  end if;
end $$;

-- ── 2. 메시지 조립 (눈으로 검증 가능한 자리로) ─────────────────
create or replace function edu.henry_slack_message(n edu.henry_notifications)
returns text language plpgsql stable security definer
set search_path = edu, pg_catalog as $$
declare
  v_base text; v_root text; v_actor text; v_to text;
  v_body text; v_link text; v_head text;
begin
  select display_name into v_actor from edu.henry_members where user_id = n.actor_id;
  select display_name into v_to    from edu.henry_members where user_id = n.recipient_id;
  v_actor := coalesce(v_actor, '(알 수 없음)');
  v_to    := coalesce(v_to,    '(알 수 없음)');

  -- 답글 알림이면 답글 본문, 메모 멘션이면 메모 본문
  if n.reply_id is not null then
    select body into v_body from edu.henry_memo_replies where id = n.reply_id;
  else
    select body into v_body from edu.henry_memos where id = n.memo_id;
  end if;
  v_body := coalesce(v_body, '');
  if char_length(v_body) > 180 then v_body := left(v_body, 180) || '…'; end if;

  v_head := case n.kind
              when 'mention' then format('*%s* 님이 *%s* 님을 불렀습니다', v_actor, v_to)
              else                format('*%s* 님이 *%s* 님의 메모에 답글을 남겼습니다', v_actor, v_to)
            end;

  -- 딥링크. 주소가 없으면 링크만 빠지고 알림은 그대로 간다.
  v_base := edu.henry_secret('henry_app_base_url');
  if v_base is not null and btrim(v_base) <> '' and n.memo_id is not null then
    v_root := btrim(v_base);
    -- 경로가 아예 없으면(https://host) 슬래시를 붙인다.
    -- 있으면(/index.html, /app/) 그대로 둔다 — 함부로 자르면 404 가 난다.
    if v_root !~ '^https?://[^/]+/' then v_root := v_root || '/'; end if;
    v_link := format(E'\n<%s?drawer=1&memo=%s|→ 그 메모 열기>', v_root, n.memo_id);
  else
    v_link := '';
  end if;

  return format(
    E'🗄 서랍 · %s · %s\n%s\n>%s%s',
    n.target_type, n.target_id, v_head,
    replace(v_body, E'\n', E'\n>'),
    v_link
  );
end $$;

revoke all on function edu.henry_slack_message(edu.henry_notifications) from anon, authenticated, public;

-- ── 3. 트리거는 보내는 일만 한다 ───────────────────────────────
create or replace function edu.henry_slack_heads_up()
returns trigger language plpgsql security definer
set search_path = edu, public, pg_catalog as $$
declare
  v_hook text;
  v_req  bigint;
begin
  v_hook := edu.henry_secret('henry_slack_webhook');

  -- 웹훅이 아직 없으면 조용히 벨로만 간다. 이것은 오류가 아니다.
  if v_hook is null or btrim(v_hook) = '' then
    new.slack_status := 'no_webhook';
    return new;
  end if;

  select net.http_post(
           url     := v_hook,
           body    := jsonb_build_object('text', edu.henry_slack_message(new)),
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
