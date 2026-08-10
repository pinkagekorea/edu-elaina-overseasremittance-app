-- 버그: elaina_stamp() 가 security invoker 였다.
-- 이 트리거는 edu.elaina_called_ids() 를 부르는데 그 함수의 EXECUTE 는
-- authenticated 에서 회수해 두었다. 그래서 로그인한 사용자가 메모를 남기면
--   ERROR 42501: permission denied for function elaina_called_ids
-- 로 전부 실패했다. (적용 직후 시험 삽입으로 잡음)
--
-- 고르는 길은 둘이었다.
--   (가) elaina_called_ids 의 EXECUTE 를 authenticated 에 준다
--        → 명단 대조 함수가 REST 로 열린다. 이름을 넣어 보며 명단을
--          떠볼 수 있게 되므로 원하지 않는다.
--   (나) 트리거를 security definer 로 바꾼다  ← 이쪽
--        → 명단 함수는 계속 비공개다.
--
-- definer 라도 auth.uid() / auth.jwt() 는 세션의 JWT 를 읽으므로
-- '지금 로그인한 사람' 판정은 그대로다. 표에 걸린 RLS 는 트리거의
-- 권한 모드와 무관하게 호출자 기준으로 검사되므로 방어선도 그대로다.

create or replace function edu.elaina_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_admin boolean := edu.elaina_is_admin();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 남길 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;                                     -- 작성자 = 지금 로그인한 사람
    new.author_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    new.created_at   := now();                                     -- 작성시각 = 서버 시각
    new.mention_ids  := edu.elaina_called_ids(new.body);           -- 부른 사람도 서버가 계산
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  -- 여기부터 UPDATE
  if old.deleted_at is not null then
    raise exception '이미 지운 글은 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  -- 무슨 값을 보내든 아래는 원래 값으로 되돌린다.
  -- 본문 수정 불가 — 남긴 뒤에는 못 고친다.
  new.body         := old.body;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.mention_ids  := old.mention_ids;

  if tg_table_name = 'elaina_memos' then
    new.target_type  := old.target_type;
    new.target_id    := old.target_id;
    new.target_label := old.target_label;
  else
    new.memo_id := old.memo_id;
  end if;

  -- 허용되는 변경은 '지움 표시' 하나뿐
  if new.deleted_at is not null then
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 글이거나 관리자일 때만 지울 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();          -- 시각은 서버가 정한다
    new.deleted_by := v_uid;
  else
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end
$$;

-- 트리거 전용이다. 트리거 실행은 EXECUTE 권한과 무관하므로 전부 회수한다.
revoke all on function edu.elaina_stamp() from public, anon, authenticated;

notify pgrst, 'reload schema';