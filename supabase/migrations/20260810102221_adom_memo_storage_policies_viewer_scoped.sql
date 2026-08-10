-- ═══════════════════════════════════════════════════════════════
-- adom-memo 버킷 — 8일차 화면 권한을 그대로 따르게 조인다.
--   기존 정책 3개를 ALTER 로 고칠 뿐 DROP 하지 않는다.
--   edu.adom_can_view() 는 adom_viewers 명단을 보는 SECURITY DEFINER 함수.
--   → 그 프로젝트를 볼 수 없는 사람은 이미지도 올릴 수 없고 볼 수 없다.
-- ═══════════════════════════════════════════════════════════════

-- 올리기: 로그인 + 명단에 있음 + 소유자는 자기 자신
alter policy adom_memo_insert on storage.objects
  with check (
    bucket_id = 'adom-memo'
    and owner = auth.uid()
    and edu.adom_can_view(auth.uid())
  );

-- 조회: 로그인 + 명단에 있음
alter policy adom_memo_select on storage.objects
  using (
    bucket_id = 'adom-memo'
    and edu.adom_can_view(auth.uid())
  );

-- 지우기: 로그인 + 명단에 있음 + 자기가 올린 것만
alter policy adom_memo_delete on storage.objects
  using (
    bucket_id = 'adom-memo'
    and owner = auth.uid()
    and edu.adom_can_view(auth.uid())
  );