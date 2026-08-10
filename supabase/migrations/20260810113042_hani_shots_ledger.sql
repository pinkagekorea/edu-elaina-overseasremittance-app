-- 올린 사람과 시각을 따로 적어 둔다 (버킷 안 파일만으로는 앱에서 보기 어렵다)
create table if not exists edu.hani_shots (
  path        text primary key,
  uploaded_by uuid not null default auth.uid() references auth.users(id),
  uploaded_at timestamptz not null default now(),
  mime        text,
  byte_size   bigint
);
comment on table edu.hani_shots is '붙여넣은 캡처의 기록. 파일 자체는 비공개 버킷에 있고 여기엔 경로와 올린 사람·시각만 남는다.';

-- 올린 사람과 시각은 서버가 찍는다 (사람이 보낸 값은 무시)
create or replace function edu.hani_stamp_shot()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.uploaded_by := auth.uid();
    new.uploaded_at := now();
    return new;
  end if;
  return old;                     -- 기록은 고치지 못한다
end
$$;

drop trigger if exists hani_shots_stamp on edu.hani_shots;
create trigger hani_shots_stamp
  before insert or update on edu.hani_shots
  for each row execute function edu.hani_stamp_shot();

alter table edu.hani_shots enable row level security;
revoke all on edu.hani_shots from anon, public, authenticated;
grant select, insert on edu.hani_shots to authenticated;

-- 이 화면을 볼 수 있는 사람(= 로그인한 사람)은 캡처 기록도 함께 본다
drop policy if exists hani_shots_select on edu.hani_shots;
create policy hani_shots_select on edu.hani_shots
  for select to authenticated using (true);

-- 남의 이름으로는 올릴 수 없다
drop policy if exists hani_shots_insert on edu.hani_shots;
create policy hani_shots_insert on edu.hani_shots
  for insert to authenticated
  with check (uploaded_by = (select auth.uid()));