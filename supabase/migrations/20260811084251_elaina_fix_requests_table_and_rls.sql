-- ═══════════════════════════════════════════════════════════════
-- 수정요청 — 카톡·말로 흩어지던 "이거 고쳐 주세요" 를 앱 안에 쌓는다
--
--   막는 일은 전부 DB 가 한다. 화면이 감추는 것은 편의일 뿐이다.
--     · 작성자·시각·처음 상태는 트리거가 찍는다 (화면이 보낸 값은 버린다)
--     · authenticated 에게 update/delete 권한을 주지 않는다
--       → 상태 변경·삭제는 SECURITY DEFINER 함수로만 된다
--     · 자기 요청만 보인다. 전부 보는 것은 관리자뿐이다
--     · anon 은 아무 권한도 없다
-- ═══════════════════════════════════════════════════════════════

create table if not exists edu.elaina_fix_requests (
  id           bigint generated always as identity primary key,

  -- 트리거가 찍는다. 화면이 무엇을 보내도 덮어쓴다.
  author_id    uuid        not null references auth.users(id) on delete cascade,
  author_email text,
  created_at   timestamptz not null default now(),

  body         text        not null,
  image_paths  text[]      not null default '{}',

  -- 어느 화면에서 왔는지 — 사용자가 적지 않아도 화면이 넣어 준다
  page_url     text        not null,
  page_label   text,
  viewport     text,

  -- 상태 (화면에서는 대기·진행중·완료·반려)
  status       text        not null default 'open',
  status_note  text,
  status_by    uuid        references auth.users(id),
  status_at    timestamptz,

  constraint elaina_fix_body_len   check (length(btrim(body)) between 1 and 2000),
  constraint elaina_fix_status_val check (status in ('open','doing','done','rejected')),
  constraint elaina_fix_url_len    check (length(page_url) <= 2048),
  constraint elaina_fix_note_len   check (status_note is null or length(status_note) <= 500),
  constraint elaina_fix_shots_max  check (coalesce(array_length(image_paths, 1), 0) <= 10)
);

comment on table edu.elaina_fix_requests is
  '수정요청. 작성자·시각·처음 상태는 트리거가 찍고, 상태 변경·삭제는 관리자 서버함수로만 된다.';
comment on column edu.elaina_fix_requests.page_url is
  '요청을 올린 화면의 주소 (쿼리 포함). 사용자가 적지 않아도 화면이 넣는다.';
comment on column edu.elaina_fix_requests.page_label is
  '사람이 읽는 화면 이름 (예: 월별 상세 내역). 열려 있던 팝업 제목이 있으면 그것.';
comment on column edu.elaina_fix_requests.viewport is
  '올릴 때의 화면 크기 (예: 390x844). 레이아웃 관련 요청을 재현할 때 쓴다.';
comment on column edu.elaina_fix_requests.status is
  'open 대기 · doing 진행중 · done 완료 · rejected 반려';
comment on column edu.elaina_fix_requests.image_paths is
  'elaina-memo 비공개 버킷 경로. 본인이 방금 올린 것만 붙을 수 있다.';

create index if not exists elaina_fix_requests_author_idx
  on edu.elaina_fix_requests (author_id, created_at desc);
create index if not exists elaina_fix_requests_status_idx
  on edu.elaina_fix_requests (status, created_at desc);

-- ── 잠금 ───────────────────────────────────────────────────────
alter table edu.elaina_fix_requests enable row level security;

revoke all on edu.elaina_fix_requests from anon, authenticated, public;

-- update·delete 는 일부러 주지 않는다. 권한 자체가 없으므로 RLS 판정 전에 막힌다.
grant select, insert on edu.elaina_fix_requests to authenticated;

-- 읽기: 자기 것만. 전부 보는 것은 관리자뿐이다.
drop policy if exists elaina_fix_select on edu.elaina_fix_requests;
create policy elaina_fix_select on edu.elaina_fix_requests
  for select to authenticated
  using (author_id = auth.uid() or edu.elaina_is_admin());

-- 쓰기: 본인 이름으로만, 이 화면을 볼 수 있는 사람만.
drop policy if exists elaina_fix_insert on edu.elaina_fix_requests;
create policy elaina_fix_insert on edu.elaina_fix_requests
  for insert to authenticated
  with check (author_id = auth.uid() and edu.elaina_can_view(auth.uid()));

-- ── 트리거 — 위조를 여기서 막는다 ──────────────────────────────
create or replace function edu.elaina_fix_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 수정요청을 남길 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;
    new.author_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.status       := 'open';         -- 처음 상태는 화면이 정하지 못한다
    new.status_note  := null;
    new.status_by    := null;
    new.status_at    := null;
    return new;
  end if;

  -- 남긴 뒤에는 내용·작성자·화면정보를 바꿀 수 없다. 움직이는 것은 상태뿐이다.
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.body         := old.body;
  new.image_paths  := old.image_paths;
  new.page_url     := old.page_url;
  new.page_label   := old.page_label;
  new.viewport     := old.viewport;

  if new.status <> old.status
     or coalesce(new.status_note, '') <> coalesce(old.status_note, '') then
    -- SECURITY DEFINER 함수 안에서도 auth.jwt() 는 그 요청의 것이라 이 검사가 산다
    if not edu.elaina_is_admin() then
      raise exception '상태는 관리자만 바꿀 수 있습니다.' using errcode = '42501';
    end if;
    new.status_by := v_uid;
    new.status_at := now();
  else
    new.status_by := old.status_by;
    new.status_at := old.status_at;
  end if;

  return new;
end
$$;

drop trigger if exists elaina_fix_requests_stamp on edu.elaina_fix_requests;
create trigger elaina_fix_requests_stamp
  before insert or update on edu.elaina_fix_requests
  for each row execute function edu.elaina_fix_stamp();

-- 트리거 함수는 사람이 직접 부를 일이 없다
revoke all on function edu.elaina_fix_stamp() from public, anon, authenticated;

notify pgrst, 'reload schema';
