-- ═══════════════════════════════════════════════════════════════
-- Storage 버킷 adom-memo (비공개) 접근 규칙
--   · 대상은 storage.objects 중 bucket_id = 'adom-memo' 인 행만
--   · 역할은 authenticated 에만 준다 → anon 은 어떤 정책에도 걸리지 않는다
--   · 기존 정책(portal-memo 용)은 건드리지 않는다. DROP 없음.
-- storage.objects 의 RLS 는 이미 켜져 있다(Supabase 기본).
-- ═══════════════════════════════════════════════════════════════

-- 올리기 — 로그인한 사람만, 소유자는 반드시 자기 자신
create policy adom_memo_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'adom-memo' and owner = auth.uid());

-- 조회 — 로그인한 사람이면 이 버킷의 파일을 볼 수 있다
create policy adom_memo_select on storage.objects
  for select to authenticated
  using (bucket_id = 'adom-memo');

-- 지우기 — 자기가 올린 것만
create policy adom_memo_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'adom-memo' and owner = auth.uid());