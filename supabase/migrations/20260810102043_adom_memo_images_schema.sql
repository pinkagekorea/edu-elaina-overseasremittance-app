-- ═══════════════════════════════════════════════════════════════
-- 메모·답글에 붙는 이미지
--   · 파일 자체는 Storage(adom-memo, 비공개)에, 경로만 여기에 남긴다
--   · 올린 사람·시각은 storage.objects 의 owner / created_at 에 남는다
--   · 경로는 만든 뒤 바꿀 수 없다 (작성자·작성시각과 같은 취급)
-- ═══════════════════════════════════════════════════════════════

alter table edu.adom_memos
  add column image_paths text[] not null default '{}';

alter table edu.adom_memo_replies
  add column image_paths text[] not null default '{}';

comment on column edu.adom_memos.image_paths is
  'adom-memo 버킷 안의 객체 경로 목록. 파일명은 예측 불가능한 무작위 값이다.';

-- ── 불변성 트리거에 image_paths 도 포함 ─────────────────────────
create or replace function edu.adom_memo_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_admin boolean := edu.adom_is_admin();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 메모를 쓸 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;
    new.author_email := lower(nullif(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.edited_at    := null;
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  if old.deleted_at is not null then
    raise exception '이미 삭제된 메모는 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  new.id           := old.id;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.target_type  := old.target_type;
  new.target_id    := old.target_id;
  new.image_paths  := old.image_paths;          -- 붙인 이미지는 나중에 못 바꾼다

  if new.deleted_at is not null then
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 메모이거나 관리자일 때만 삭제할 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();
    new.deleted_by := v_uid;
    new.body       := old.body;
    new.edited_at  := old.edited_at;
    return new;
  end if;

  new.deleted_by := old.deleted_by;
  if new.body is distinct from old.body then
    if old.author_id is distinct from v_uid then
      raise exception '본인이 쓴 메모만 고칠 수 있습니다.' using errcode = '42501';
    end if;
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end
$$;

create or replace function edu.adom_reply_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_admin boolean := edu.adom_is_admin();
begin
  if tg_op = 'INSERT' then
    if v_uid is null then
      raise exception '로그인한 사용자만 답글을 쓸 수 있습니다.' using errcode = '42501';
    end if;
    new.author_id    := v_uid;
    new.author_email := lower(nullif(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.edited_at    := null;
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  if old.deleted_at is not null then
    raise exception '이미 삭제된 답글은 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  new.id           := old.id;
  new.memo_id      := old.memo_id;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.image_paths  := old.image_paths;

  if new.deleted_at is not null then
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 답글이거나 관리자일 때만 삭제할 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();
    new.deleted_by := v_uid;
    new.body       := old.body;
    new.edited_at  := old.edited_at;
    return new;
  end if;

  new.deleted_by := old.deleted_by;
  if new.body is distinct from old.body then
    if old.author_id is distinct from v_uid then
      raise exception '본인이 쓴 답글만 고칠 수 있습니다.' using errcode = '42501';
    end if;
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end
$$;