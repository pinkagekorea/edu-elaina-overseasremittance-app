-- ═══════════════════════════════════════════════════════════════
-- 서랍 표 4개 — RLS 활성화 + 권한 정리
--   · anon 에게는 어떤 권한도 주지 않는다 (로그인해야만 보인다)
--   · DELETE 권한은 누구에게도 주지 않는다 → 하드 삭제 자체가 불가능,
--     삭제는 deleted_at 을 채우는 UPDATE 로만 이루어진다
-- ═══════════════════════════════════════════════════════════════

alter table edu.adom_memos         enable row level security;
alter table edu.adom_memo_replies  enable row level security;
alter table edu.adom_mentions      enable row level security;
alter table edu.adom_notifications enable row level security;

-- 스키마 기본 권한으로 붙었을 수 있는 권한을 전부 걷어낸다
revoke all on edu.adom_memos, edu.adom_memo_replies,
              edu.adom_mentions, edu.adom_notifications
  from anon, authenticated, public;

grant usage on schema edu to authenticated;

-- 로그인한 사용자에게만, 필요한 만큼만
grant select, insert, update on edu.adom_memos         to authenticated;
grant select, insert, update on edu.adom_memo_replies  to authenticated;
grant select                 on edu.adom_mentions      to authenticated;
grant select, update         on edu.adom_notifications to authenticated;

-- ── 메모 정책 ───────────────────────────────────────────────────
-- 읽기: 로그인한 팀원이면 모두 (삭제된 것도 "삭제됨"으로 표시하기 위해 읽는다)
create policy adom_memos_select on edu.adom_memos
  for select to authenticated
  using (true);

-- 쓰기: 본인 이름으로만
create policy adom_memos_insert on edu.adom_memos
  for insert to authenticated
  with check (author_id = auth.uid());

-- 수정/삭제: 본인 또는 관리자. (관리자는 삭제만 가능 — 트리거가 추가로 제한)
create policy adom_memos_update on edu.adom_memos
  for update to authenticated
  using      (author_id = auth.uid() or edu.adom_is_admin())
  with check (author_id = auth.uid() or edu.adom_is_admin());

-- ── 답글 정책 ───────────────────────────────────────────────────
create policy adom_memo_replies_select on edu.adom_memo_replies
  for select to authenticated
  using (true);

create policy adom_memo_replies_insert on edu.adom_memo_replies
  for insert to authenticated
  with check (author_id = auth.uid());

create policy adom_memo_replies_update on edu.adom_memo_replies
  for update to authenticated
  using      (author_id = auth.uid() or edu.adom_is_admin())
  with check (author_id = auth.uid() or edu.adom_is_admin());

-- ── 멘션 정책 ───────────────────────────────────────────────────
-- 읽기만. INSERT 정책도 권한도 없으므로 트리거(SECURITY DEFINER)만 쓸 수 있다.
create policy adom_mentions_select on edu.adom_mentions
  for select to authenticated
  using (true);

-- ── 알림 정책 ───────────────────────────────────────────────────
-- 내 알림만 보이고, 내 알림만 읽음 처리할 수 있다.
create policy adom_notifications_select on edu.adom_notifications
  for select to authenticated
  using (recipient_id = auth.uid());

create policy adom_notifications_update on edu.adom_notifications
  for update to authenticated
  using      (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());