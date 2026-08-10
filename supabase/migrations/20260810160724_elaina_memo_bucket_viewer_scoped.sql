-- ═══════════════════════════════════════════════════════════════
-- elaina-memo 버킷 — 8일차 화면 권한을 그대로 따르게 조인다.
--   기존 정책 3개를 ALTER 로 고칠 뿐 DROP 하지 않는다.
--   edu.elaina_can_view() 는 elaina_viewers 명단을 보는 definer 함수다.
--   → 그 프로젝트를 볼 수 없는 사람은 이미지도 올릴 수 없고 볼 수 없다.
--   anon 은 여전히 어떤 정책에도 걸리지 않는다(대상 롤이 authenticated 뿐).
-- ═══════════════════════════════════════════════════════════════

alter policy elaina_memo_insert on storage.objects
  with check (
    bucket_id = 'elaina-memo'
    and owner = auth.uid()
    and edu.elaina_can_view(auth.uid())
  );

alter policy elaina_memo_select on storage.objects
  using (
    bucket_id = 'elaina-memo'
    and edu.elaina_can_view(auth.uid())
  );

alter policy elaina_memo_delete on storage.objects
  using (
    bucket_id = 'elaina-memo'
    and owner = auth.uid()
    and edu.elaina_can_view(auth.uid())
  );

-- 서버 측 제한. 클라이언트 검사는 팻말이고 이것이 경비원이다 —
-- API 를 직접 쳐도 여기서 막힌다. 버킷은 지우지 않고 설정 열만 갱신한다.
update storage.buckets
   set file_size_limit    = 5242880,                                    -- 5MB
       allowed_mime_types = array['image/png','image/jpeg','image/gif','image/webp']
 where id = 'elaina-memo';