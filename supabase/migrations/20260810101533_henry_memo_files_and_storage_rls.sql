-- 서랍 이미지 첨부 — 첨부 기록표 + henry-memo 버킷 RLS
-- drop 은 넣지 않는다. 새 정책만 더한다.

-- ── 1. 첨부 기록표 ─────────────────────────────────────────────
-- storage.objects 만으로는 "이 이미지가 어느 메모의 것인가" 를 알 수 없다.
-- 올린 사람과 시각은 여기와 storage.objects 양쪽에 남는다.
create table if not exists edu.henry_memo_files (
  id          bigint generated always as identity primary key,
  memo_id     bigint references edu.henry_memos(id)        on delete cascade,
  reply_id    bigint references edu.henry_memo_replies(id) on delete cascade,
  bucket_id   text   not null default 'henry-memo',
  path        text   not null unique,
  mime        text,
  size_bytes  integer,
  uploaded_by uuid   not null default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now(),
  constraint henry_memo_files_one_parent check (num_nonnulls(memo_id, reply_id) = 1)
);

create index if not exists henry_memo_files_memo_idx  on edu.henry_memo_files (memo_id);
create index if not exists henry_memo_files_reply_idx on edu.henry_memo_files (reply_id);

revoke all on edu.henry_memo_files from anon, authenticated, public;
grant select, insert, delete on edu.henry_memo_files to authenticated;

alter table edu.henry_memo_files enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='edu'
                 and tablename='henry_memo_files' and policyname='henry_memo_files_select') then
    create policy henry_memo_files_select on edu.henry_memo_files
      for select to authenticated using (edu.henry_is_member());
  end if;

  -- 남의 이름으로 첨부를 남길 수 없다
  if not exists (select 1 from pg_policies where schemaname='edu'
                 and tablename='henry_memo_files' and policyname='henry_memo_files_insert') then
    create policy henry_memo_files_insert on edu.henry_memo_files
      for insert to authenticated
      with check (edu.henry_is_member() and uploaded_by = auth.uid());
  end if;

  -- 첨부 떼기는 올린 사람과 관리자만. 스토리지 삭제 규칙과 짝을 맞춘다.
  if not exists (select 1 from pg_policies where schemaname='edu'
                 and tablename='henry_memo_files' and policyname='henry_memo_files_delete') then
    create policy henry_memo_files_delete on edu.henry_memo_files
      for delete to authenticated
      using (uploaded_by = auth.uid() or edu.henry_is_admin());
  end if;
end $$;

-- ── 2. henry-memo 버킷 RLS (storage.objects) ───────────────────
-- storage.objects 는 남의 버킷(portal-memo)도 함께 쓰는 공용 표다.
-- 그래서 기존 정책을 건드리지 않고 bucket_id 로 한정한 정책만 새로 만든다.
-- anon 은 정책을 하나도 만들지 않는 것으로 막는다 —
-- 테이블 grant 를 회수하면 남의 버킷까지 같이 죽는다.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='storage'
                 and tablename='objects' and policyname='henry_memo_storage_insert') then
    create policy henry_memo_storage_insert on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'henry-memo'
        and owner = auth.uid()
        and edu.henry_is_member()
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='storage'
                 and tablename='objects' and policyname='henry_memo_storage_select') then
    create policy henry_memo_storage_select on storage.objects
      for select to authenticated
      using (
        bucket_id = 'henry-memo'
        and edu.henry_is_member()
      );
  end if;

  -- 지우기는 자기가 올린 것만
  if not exists (select 1 from pg_policies where schemaname='storage'
                 and tablename='objects' and policyname='henry_memo_storage_delete') then
    create policy henry_memo_storage_delete on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'henry-memo'
        and owner = auth.uid()
      );
  end if;
end $$;
