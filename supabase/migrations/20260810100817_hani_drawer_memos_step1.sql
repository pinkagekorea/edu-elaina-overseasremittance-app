-- 9일차 Step 1 : 서랍(메모) 부품이 쓸 표 두 개
-- 원칙 : 표를 만드는 그 자리에서 RLS 를 켠다. anon 은 한 줄도 보지 못한다.

-- 관리자 판별 : 로그인 토큰의 이메일로만 판단한다 (화면의 팻말이 아니라 DB 의 방어선)
create or replace function edu.hani_is_admin()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'hani@pinkage.co.kr'
$$;

-- 서랍 메모 ------------------------------------------------------------------
create table if not exists edu.hani_memos (
  id            bigint generated always as identity primary key,
  target_type   text not null check (target_type ~ '^[a-z][a-z0-9_]{0,31}$'),
  target_id     text not null check (length(btrim(target_id)) between 1 and 200),
  target_label  text,
  body          text not null check (length(btrim(body)) between 1 and 4000),
  author_id     uuid not null default auth.uid() references auth.users(id),
  author_email  text,
  created_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  deleted_by    uuid references auth.users(id)
);

comment on table  edu.hani_memos              is '서랍 메모. 어느 대상의 서랍인지는 (target_type, target_id) 로 구분한다.';
comment on column edu.hani_memos.target_type  is '대상 종류. dashboard = 현황판 전체, product = 개별 상품 한 줄.';
comment on column edu.hani_memos.target_id    is '대상 id. 부품에 넘기는 값과 같다 (product 면 hani_competitor.id).';
comment on column edu.hani_memos.target_label is '사람이 읽는 대상 이름. 목록/알림에 그대로 쓴다.';
comment on column edu.hani_memos.author_id    is '작성자. 트리거가 auth.uid() 로 채우며 이후 변경 불가.';
comment on column edu.hani_memos.created_at   is '작성시각. 트리거가 now() 로 채우며 이후 변경 불가.';
comment on column edu.hani_memos.deleted_at   is '소프트 삭제 시각. 본인 또는 관리자만 설정할 수 있다.';

create index if not exists hani_memos_target_idx
  on edu.hani_memos (target_type, target_id, created_at desc);

-- 답글 (팝업 오른쪽 칸) --------------------------------------------------------
create table if not exists edu.hani_memo_replies (
  id           bigint generated always as identity primary key,
  memo_id      bigint not null references edu.hani_memos(id) on delete cascade,
  body         text not null check (length(btrim(body)) between 1 and 4000),
  author_id    uuid not null default auth.uid() references auth.users(id),
  author_email text,
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  deleted_by   uuid references auth.users(id)
);

comment on table edu.hani_memo_replies is '메모에 달리는 답글. 팝업 오른쪽 칸에 표시된다.';

create index if not exists hani_memo_replies_memo_idx
  on edu.hani_memo_replies (memo_id, created_at);

-- 작성자·작성시각 자동 기록 + 이후 수정 불가 -------------------------------------
-- 사람이 보낸 author_id / created_at 은 무시한다. 서버가 찍은 값만 남는다.
create or replace function edu.hani_stamp_author()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.author_id    := auth.uid();
    new.author_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  -- UPDATE : 본문과 작성 기록은 되돌려 놓는다. 허용되는 변경은 '삭제 표시' 하나뿐.
  new.body         := old.body;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;

  if tg_table_name = 'hani_memos' then
    new.target_type  := old.target_type;
    new.target_id    := old.target_id;
    new.target_label := old.target_label;
  else
    new.memo_id := old.memo_id;
  end if;

  if new.deleted_at is not null and old.deleted_at is null then
    new.deleted_at := now();
    new.deleted_by := auth.uid();
  else
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end
$$;

drop trigger if exists hani_memos_stamp on edu.hani_memos;
create trigger hani_memos_stamp
  before insert or update on edu.hani_memos
  for each row execute function edu.hani_stamp_author();

drop trigger if exists hani_memo_replies_stamp on edu.hani_memo_replies;
create trigger hani_memo_replies_stamp
  before insert or update on edu.hani_memo_replies
  for each row execute function edu.hani_stamp_author();

-- RLS : 표를 만든 그 자리에서 바로 켠다 ------------------------------------------
alter table edu.hani_memos        enable row level security;
alter table edu.hani_memo_replies enable row level security;

-- anon 은 아무 권한도 갖지 않는다 (정책 이전에 권한부터 없다)
revoke all on edu.hani_memos        from anon, public;
revoke all on edu.hani_memo_replies from anon, public;
grant select, insert, update on edu.hani_memos        to authenticated;
grant select, insert, update on edu.hani_memo_replies to authenticated;

-- 읽기 : 로그인한 사람은 서랍을 함께 본다 (팀의 기록이므로)
drop policy if exists hani_memos_select on edu.hani_memos;
create policy hani_memos_select on edu.hani_memos
  for select to authenticated
  using (true);

-- 쓰기 : 남의 이름으로는 쓸 수 없다
drop policy if exists hani_memos_insert on edu.hani_memos;
create policy hani_memos_insert on edu.hani_memos
  for insert to authenticated
  with check (author_id = (select auth.uid()));

-- 수정 : 본인 또는 관리자만. 트리거가 '삭제 표시' 외의 변경을 되돌린다.
drop policy if exists hani_memos_update on edu.hani_memos;
create policy hani_memos_update on edu.hani_memos
  for update to authenticated
  using (author_id = (select auth.uid()) or edu.hani_is_admin())
  with check (author_id = (select auth.uid()) or edu.hani_is_admin());

-- DELETE 정책은 만들지 않는다 → 진짜 삭제는 누구도 못 한다 (기록이 사라지지 않는다)

drop policy if exists hani_memo_replies_select on edu.hani_memo_replies;
create policy hani_memo_replies_select on edu.hani_memo_replies
  for select to authenticated
  using (true);

drop policy if exists hani_memo_replies_insert on edu.hani_memo_replies;
create policy hani_memo_replies_insert on edu.hani_memo_replies
  for insert to authenticated
  with check (author_id = (select auth.uid()));

drop policy if exists hani_memo_replies_update on edu.hani_memo_replies;
create policy hani_memo_replies_update on edu.hani_memo_replies
  for update to authenticated
  using (author_id = (select auth.uid()) or edu.hani_is_admin())
  with check (author_id = (select auth.uid()) or edu.hani_is_admin());