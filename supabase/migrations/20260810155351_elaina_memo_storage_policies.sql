-- ═══════════════════════════════════════════════════════════════
-- Storage 버킷 elaina-memo (비공개) 접근 규칙
--
--   · 대상은 storage.objects 중 bucket_id = 'elaina-memo' 인 행만
--   · 역할은 authenticated 에만 준다 → anon 은 어떤 정책에도 걸리지 않는다
--
-- anon 차단을 '테이블 권한 회수'로 하지 않는 이유:
--   storage.objects 는 여섯 버킷이 함께 쓰는 공용 표다. anon 의 테이블
--   권한을 걷어내면 남의 버킷(portal-memo, henry-memo …)까지 같이 죽는다.
--   그래서 anon 을 대상으로 하는 정책을 하나도 만들지 않는 것으로 막는다.
--   RLS 는 정책이 없으면 통과시키지 않으므로 결과는 같다.
--
-- DROP 은 넣지 않는다. 이미 있으면 건너뛰고 없을 때만 만든다.
-- storage.objects 의 RLS 는 이미 켜져 있다(Supabase 기본).
-- ═══════════════════════════════════════════════════════════════

do $$
begin
  -- 올리기 — 로그인한 사람만, 소유자는 반드시 자기 자신
  if not exists (select 1 from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and policyname = 'elaina_memo_insert') then
    create policy elaina_memo_insert on storage.objects
      for insert to authenticated
      with check (bucket_id = 'elaina-memo' and owner = auth.uid());
  end if;

  -- 조회 — 로그인한 사람이면 이 버킷의 파일을 볼 수 있다
  if not exists (select 1 from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and policyname = 'elaina_memo_select') then
    create policy elaina_memo_select on storage.objects
      for select to authenticated
      using (bucket_id = 'elaina-memo');
  end if;

  -- 지우기 — 자기가 올린 것만
  if not exists (select 1 from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and policyname = 'elaina_memo_delete') then
    create policy elaina_memo_delete on storage.objects
      for delete to authenticated
      using (bucket_id = 'elaina-memo' and owner = auth.uid());
  end if;
end $$;