-- ═══════════════════════════════════════════════════════════════
-- 슬랙 배관 — 표와 관리자용 창구
--
--   비밀값(봇 토큰·웹훅 주소)은 이 표에도, 코드에도, index.html 에도
--   넣지 않는다. Edge Function 의 환경변수에만 둔다.
--   그래서 '누구에게 어떻게 보낼지' 판정과 실제 발송은 Edge 가 한다.
--   DB 는 짝 맞춤표와 결과 기록만 들고 있는다.
--
--   등급 세 가지:
--     dm      개인 DM 으로 감      (짝 맞춤표에 있고 봇 토큰도 있을 때)
--     channel 채널 웹훅으로만 감   (짝이 없거나 봇 토큰이 없을 때)
--     bell    아무 것도 안 보냄    (웹훅도 없을 때 — 인앱 벨만)
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 아이디 ↔ 슬랙 사람 (지금은 빈 표) ───────────────────────
create table if not exists edu.elaina_slack_links (
  user_id       uuid        primary key references auth.users(id) on delete cascade,
  slack_user_id text        not null,
  slack_display text,
  updated_by    uuid        references auth.users(id),
  updated_at    timestamptz not null default now(),
  constraint elaina_slack_links_uniq unique (slack_user_id),
  -- 슬랙 멤버 ID 는 U 또는 W 로 시작한다. '@이름' 을 잘못 넣는 실수를 여기서 잡는다.
  constraint elaina_slack_links_shape check (slack_user_id ~ '^[UW][A-Z0-9]{2,}$')
);

comment on table  edu.elaina_slack_links is
  '앱 계정 ↔ 슬랙 사람 짝 맞춤표. 여기 있는 사람에게만 개인 DM 을 시도한다. 관리자만 채운다.';
comment on column edu.elaina_slack_links.slack_user_id is
  '슬랙 멤버 ID (U 로 시작). 슬랙 프로필 > 더 보기 > 멤버 ID 복사 에서 얻는다.';

alter table edu.elaina_slack_links enable row level security;
revoke all on edu.elaina_slack_links from anon, authenticated, public;

-- 읽기는 관리자만. 쓰기 권한은 아무에게도 주지 않는다(아래 함수로만).
grant select on edu.elaina_slack_links to authenticated;

drop policy if exists elaina_slack_links_select on edu.elaina_slack_links;
create policy elaina_slack_links_select on edu.elaina_slack_links
  for select to authenticated
  using (edu.elaina_is_admin());

-- ── 2. 무엇이 어떻게 나갔는지 기록 ─────────────────────────────
create table if not exists edu.elaina_slack_deliveries (
  id              bigint generated always as identity primary key,
  notification_id bigint references edu.elaina_notifications(id) on delete cascade,
  memo_id         bigint references edu.elaina_memos(id)         on delete cascade,
  reply_id        bigint references edu.elaina_memo_replies(id)  on delete cascade,
  actor_id        uuid not null,
  recipient_id    uuid not null,
  recipient_name  text,
  tier            text not null check (tier in ('dm', 'channel', 'bell')),
  detail          text,
  created_at      timestamptz not null default now()
);

comment on table edu.elaina_slack_deliveries is
  '호출 하나가 슬랙으로 어떻게 갔는지. Edge Function 이 판정 결과를 적는다.';
comment on column edu.elaina_slack_deliveries.tier is
  'dm = 개인 DM 감 · channel = 채널로만 감 · bell = 벨로만 감';

create index if not exists elaina_slack_deliveries_actor_idx
  on edu.elaina_slack_deliveries (actor_id, created_at desc);

alter table edu.elaina_slack_deliveries enable row level security;
revoke all on edu.elaina_slack_deliveries from anon, authenticated, public;

-- 보낸 사람은 자기가 보낸 것의 결과만 본다. 쓰기는 service_role(Edge)만.
grant select on edu.elaina_slack_deliveries to authenticated;
grant select, insert on edu.elaina_slack_deliveries to service_role;

drop policy if exists elaina_deliveries_select on edu.elaina_slack_deliveries;
create policy elaina_deliveries_select on edu.elaina_slack_deliveries
  for select to authenticated
  using (actor_id = auth.uid() or edu.elaina_is_admin());

-- ── 3. 짝 맞춤표 관리 (관리자 전용) ────────────────────────────
create or replace function edu.elaina_slack_link_set(
  p_email         text,
  p_slack_user_id text,
  p_slack_display text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_slack text := upper(btrim(coalesce(p_slack_user_id, '')));
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 짝 맞춤표를 바꿀 수 있습니다.' using errcode = '42501';
  end if;

  select u.id into v_uid from auth.users u
   where lower(u.email) = v_email and u.deleted_at is null;
  if v_uid is null then
    raise exception '그런 계정이 없습니다: %', v_email using errcode = '22023';
  end if;

  insert into edu.elaina_slack_links
       (user_id, slack_user_id, slack_display, updated_by, updated_at)
       values (v_uid, v_slack, nullif(btrim(coalesce(p_slack_display,'')),''), auth.uid(), now())
  on conflict (user_id) do update
     set slack_user_id = excluded.slack_user_id,
         slack_display = excluded.slack_display,
         updated_by    = excluded.updated_by,
         updated_at    = now();

  return jsonb_build_object('email', v_email, 'slack_user_id', v_slack);
end
$$;

create or replace function edu.elaina_slack_link_remove(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not edu.elaina_is_admin() then
    raise exception '관리자만 짝 맞춤표를 바꿀 수 있습니다.' using errcode = '42501';
  end if;
  delete from edu.elaina_slack_links where user_id = p_user_id;
  return jsonb_build_object('removed', p_user_id);
end
$$;

-- 명단 + 짝 맞춤 상태를 한눈에 (관리자에게만 응답)
create or replace function edu.elaina_slack_links_list()
returns table (user_id uuid, email text, display_name text,
               slack_user_id text, slack_display text, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select v.user_id, v.email, v.display_name,
         l.slack_user_id, l.slack_display, l.updated_at
    from edu.elaina_viewers v
    left join edu.elaina_slack_links l on l.user_id = v.user_id
   where edu.elaina_is_admin()
   order by (l.slack_user_id is null), v.display_name;
$$;

-- ── 4. 보낸 사람에게 '무엇으로 갔는지' 알려주는 창구 ───────────
create or replace function edu.elaina_delivery_report(
  p_memo_id  bigint default null,
  p_reply_id bigint default null
)
returns table (name text, tier text)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(d.recipient_name, v.display_name, '알 수 없음'), d.tier
    from edu.elaina_slack_deliveries d
    left join edu.elaina_viewers v on v.user_id = d.recipient_id
   where d.actor_id = auth.uid()                      -- 남의 결과는 못 본다
     and (p_memo_id  is null or d.memo_id  = p_memo_id)
     and (p_reply_id is null or d.reply_id = p_reply_id)
     and (p_memo_id is not null or p_reply_id is not null)
   order by 1;
$$;

-- ── 5. 실행 권한 — anon 에는 아무것도 주지 않는다 ──────────────
revoke all on function edu.elaina_slack_link_set(text, text, text)     from public, anon;
revoke all on function edu.elaina_slack_link_remove(uuid)              from public, anon;
revoke all on function edu.elaina_slack_links_list()                   from public, anon;
revoke all on function edu.elaina_delivery_report(bigint, bigint)      from public, anon;

grant execute on function edu.elaina_slack_link_set(text, text, text)  to authenticated, service_role;
grant execute on function edu.elaina_slack_link_remove(uuid)           to authenticated, service_role;
grant execute on function edu.elaina_slack_links_list()                to authenticated, service_role;
grant execute on function edu.elaina_delivery_report(bigint, bigint)   to authenticated, service_role;

notify pgrst, 'reload schema';