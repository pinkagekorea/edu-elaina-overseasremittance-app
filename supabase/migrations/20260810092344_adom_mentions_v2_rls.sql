-- ═══════════════════════════════════════════════════════════════
-- 화면 권한 함수 + 새 표 RLS + 기존 정책을 "볼 수 있는 사람만" 으로 조인다
-- ═══════════════════════════════════════════════════════════════

-- 이 사람이 ADOM 화면을 볼 수 있는가.
-- SECURITY DEFINER 인 이유: adom_viewers 의 정책이 이 함수를 부르므로
-- 소유자 권한으로 읽어야 정책이 자기 자신을 다시 부르는 재귀가 생기지 않는다.
create or replace function edu.adom_can_view(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_uid is not null
     and exists (select 1 from edu.adom_viewers v where v.user_id = p_uid);
$$;

comment on function edu.adom_can_view(uuid) is
  '8일차 화면 권한. 관리자는 adom_viewers 에 항상 들어 있으므로 여기서 함께 판정된다.';

-- ── 새 표 2개 — 만들자마자 잠근다 ───────────────────────────────
alter table edu.adom_viewers            enable row level security;
alter table edu.adom_notification_prefs enable row level security;

revoke all on edu.adom_viewers, edu.adom_notification_prefs
  from anon, authenticated, public;

-- 명단은 "볼 수 있는 사람" 끼리만 읽는다. 쓰기 권한은 아무에게도 주지 않는다
-- (추가·제외는 관리자 전용 SECURITY DEFINER 함수로만 가능).
grant select on edu.adom_viewers to authenticated;

create policy adom_viewers_select on edu.adom_viewers
  for select to authenticated
  using (edu.adom_can_view(auth.uid()));

-- 알림 설정은 본인 것만
grant select, insert, update on edu.adom_notification_prefs to authenticated;

create policy adom_prefs_select on edu.adom_notification_prefs
  for select to authenticated
  using (user_id = auth.uid());

create policy adom_prefs_insert on edu.adom_notification_prefs
  for insert to authenticated
  with check (user_id = auth.uid());

create policy adom_prefs_update on edu.adom_notification_prefs
  for update to authenticated
  using      (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ── 기존 정책을 화면 권한에 맞춘다 ──────────────────────────────
-- 지금까지는 "로그인한 사람 모두" 였다. 이제 "이 화면을 볼 수 있는 사람" 으로 좁힌다.
alter policy adom_memos_select on edu.adom_memos
  using (edu.adom_can_view(auth.uid()));

alter policy adom_memos_insert on edu.adom_memos
  with check (author_id = auth.uid() and edu.adom_can_view(auth.uid()));

alter policy adom_memos_update on edu.adom_memos
  using      ((author_id = auth.uid() or edu.adom_is_admin()) and edu.adom_can_view(auth.uid()))
  with check ((author_id = auth.uid() or edu.adom_is_admin()) and edu.adom_can_view(auth.uid()));

alter policy adom_memo_replies_select on edu.adom_memo_replies
  using (edu.adom_can_view(auth.uid()));

alter policy adom_memo_replies_insert on edu.adom_memo_replies
  with check (author_id = auth.uid() and edu.adom_can_view(auth.uid()));

alter policy adom_memo_replies_update on edu.adom_memo_replies
  using      ((author_id = auth.uid() or edu.adom_is_admin()) and edu.adom_can_view(auth.uid()))
  with check ((author_id = auth.uid() or edu.adom_is_admin()) and edu.adom_can_view(auth.uid()));

alter policy adom_mentions_select on edu.adom_mentions
  using (edu.adom_can_view(auth.uid()));

-- 알림은 받는 사람 것만 (기존 그대로 — 화면 권한을 잃어도 이미 온 알림은 읽을 수 있다)

revoke all on function edu.adom_can_view(uuid) from public, anon;
grant execute on function edu.adom_can_view(uuid) to authenticated, service_role;