-- ═══════════════════════════════════════════════════════════════
-- 슬랙 배관 (1) — 짝 맞춤표와 발송 대기함
--   · 비밀값(봇 토큰·웹훅 주소)은 여기에 절대 넣지 않는다.
--     Edge Function 의 환경변수에만 둔다.
--   · 짝 맞춤표는 지금 비어 있다. 관리자만 채울 수 있다.
-- ═══════════════════════════════════════════════════════════════

-- ── 아이디 ↔ 슬랙 사람 ─────────────────────────────────────────
create table edu.adom_slack_links (
  user_id       uuid        primary key,
  slack_user_id text        not null,
  slack_display text,
  updated_by    uuid,
  updated_at    timestamptz not null default now(),
  constraint adom_slack_links_uniq  unique (slack_user_id),
  -- 슬랙 멤버 ID 는 U/W 로 시작한다. '@이름' 을 잘못 넣는 실수를 여기서 잡는다.
  constraint adom_slack_links_shape check (slack_user_id ~ '^[UW][A-Z0-9]{2,}$')
);

comment on table  edu.adom_slack_links               is
  '앱 사용자 ↔ 슬랙 사람 짝 맞춤표. 여기 있는 사람에게만 개인 DM 을 시도한다.';
comment on column edu.adom_slack_links.slack_user_id is
  '슬랙 멤버 ID (U 로 시작). 슬랙 프로필 > 더 보기 > 멤버 ID 복사 에서 얻는다.';

-- ── 발송 대기·기록 ─────────────────────────────────────────────
-- 인앱 알림을 만들 때 여기에도 한 줄 쌓아 두고, Edge Function 이 집어 간다.
create table edu.adom_slack_outbox (
  id              bigint generated always as identity primary key,
  notification_id bigint references edu.adom_notifications(id)  on delete cascade,
  actor_id        uuid not null,
  recipient_id    uuid not null,
  recipient_name  text,
  memo_id         bigint references edu.adom_memos(id)          on delete cascade,
  reply_id        bigint references edu.adom_memo_replies(id)   on delete cascade,
  target_type     text not null,
  target_id       text not null,
  target_label    text,
  actor_name      text,
  excerpt         text,
  status          text not null default 'pending'
                  check (status in ('pending', 'done', 'failed')),
  tier            text check (tier in ('dm', 'channel', 'bell')),
  detail          text,
  created_at      timestamptz not null default now(),
  sent_at         timestamptz
);

comment on table  edu.adom_slack_outbox        is
  '슬랙으로 내보낼 호출 알림. Edge Function 이 처리하고 결과(tier)를 적는다.';
comment on column edu.adom_slack_outbox.tier   is
  'dm = 개인 DM 감 · channel = 채널로만 감 · bell = 벨로만 감(슬랙 미발송)';

create index adom_slack_outbox_pending_idx
  on edu.adom_slack_outbox (memo_id, reply_id)
  where status = 'pending';

-- ── 잠그기 ─────────────────────────────────────────────────────
alter table edu.adom_slack_links  enable row level security;
alter table edu.adom_slack_outbox enable row level security;

revoke all on edu.adom_slack_links, edu.adom_slack_outbox
  from anon, authenticated, public;

-- 짝 맞춤표는 관리자만 본다. 쓰기는 아무에게도 주지 않는다(관리자 전용 함수로만).
grant select on edu.adom_slack_links to authenticated;

create policy adom_slack_links_select on edu.adom_slack_links
  for select to authenticated
  using (edu.adom_is_admin());

-- 대기함은 자기가 보낸 것만 들여다볼 수 있다(무엇이 어떻게 나갔는지 확인용).
grant select on edu.adom_slack_outbox to authenticated;

create policy adom_slack_outbox_select on edu.adom_slack_outbox
  for select to authenticated
  using (actor_id = auth.uid() or edu.adom_is_admin());

-- ── 짝 맞춤표 관리 (관리자 전용) ───────────────────────────────
create or replace function edu.adom_slack_link_set(
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
  v_uid    uuid;
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_slack  text := upper(btrim(coalesce(p_slack_user_id, '')));
begin
  if not edu.adom_is_admin() then
    raise exception '관리자만 짝 맞춤표를 바꿀 수 있습니다.' using errcode = '42501';
  end if;

  select u.id into v_uid from auth.users u
   where lower(u.email) = v_email and u.deleted_at is null;
  if v_uid is null then
    raise exception '그런 계정이 없습니다: %', v_email using errcode = '22023';
  end if;

  insert into edu.adom_slack_links (user_id, slack_user_id, slack_display, updated_by, updated_at)
       values (v_uid, v_slack, nullif(btrim(coalesce(p_slack_display, '')), ''), auth.uid(), now())
  on conflict (user_id) do update
     set slack_user_id = excluded.slack_user_id,
         slack_display = excluded.slack_display,
         updated_by    = excluded.updated_by,
         updated_at    = now();

  return jsonb_build_object('user_id', v_uid, 'email', v_email, 'slack_user_id', v_slack);
end
$$;

create or replace function edu.adom_slack_link_remove(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not edu.adom_is_admin() then
    raise exception '관리자만 짝 맞춤표를 바꿀 수 있습니다.' using errcode = '42501';
  end if;
  delete from edu.adom_slack_links where user_id = p_user_id;
  return jsonb_build_object('removed', p_user_id);
end
$$;

-- 명단 + 짝 맞춤 상태를 한눈에 (관리자에게만 응답)
create or replace function edu.adom_slack_links_list()
returns table (user_id uuid, email text, display_name text,
               slack_user_id text, slack_display text, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select v.user_id, v.email, v.display_name,
         l.slack_user_id, l.slack_display, l.updated_at
    from edu.adom_viewers v
    left join edu.adom_slack_links l on l.user_id = v.user_id
   where edu.adom_is_admin()
   order by (l.slack_user_id is null), v.display_name;
$$;

revoke all on function edu.adom_slack_link_set(text, text, text) from public, anon;
revoke all on function edu.adom_slack_link_remove(uuid)          from public, anon;
revoke all on function edu.adom_slack_links_list()               from public, anon;

grant execute on function edu.adom_slack_link_set(text, text, text) to authenticated, service_role;
grant execute on function edu.adom_slack_link_remove(uuid)          to authenticated, service_role;
grant execute on function edu.adom_slack_links_list()               to authenticated, service_role;

notify pgrst, 'reload schema';