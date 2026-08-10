-- Step 4 : 캡처 붙여넣기
-- 파일은 '비공개' 버킷에 둔다. 주소만 알면 열리는 공개 링크는 만들지 않는다.
-- 화면에 보일 때는 짧게 사는 '서명 URL' 을 그때그때 만들어 쓴다.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hani-memo-shots', 'hani-memo-shots', false, 5242880,
        array['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

-- 메모/답글에 붙은 파일의 '경로' 만 적어 둔다 (파일 자체는 버킷에 있다)
alter table edu.hani_memos        add column if not exists image_paths text[] not null default '{}';
alter table edu.hani_memo_replies add column if not exists image_paths text[] not null default '{}';

comment on column edu.hani_memos.image_paths is '버킷 안 파일 경로. 공개 주소가 아니라 경로일 뿐이며, 볼 때마다 서명 URL 을 새로 만든다.';

-- 올리기 : 자기 폴더(user_id/…)에만 올릴 수 있다
drop policy if exists hani_shots_insert on storage.objects;
create policy hani_shots_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'hani-memo-shots'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- 보기 : 로그인한 사람은 서랍을 함께 보므로 캡처도 함께 본다 (anon 은 정책이 없어 못 본다)
drop policy if exists hani_shots_select on storage.objects;
create policy hani_shots_select on storage.objects
  for select to authenticated
  using (bucket_id = 'hani-memo-shots');

-- 지우기 : 올린 본인만
drop policy if exists hani_shots_delete on storage.objects;
create policy hani_shots_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'hani-memo-shots'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );