-- ═══════════════════════════════════════════════════════════════
-- 메모·답글에 붙는 캡처
--   · 파일 자체는 Storage(elaina-memo, 비공개)에, 경로만 여기에 남긴다
--   · 올린 사람·시각은 storage.objects 의 owner / created_at 에 남는다
--   · 붙일 수 있는 이미지는 "본인이 방금 올린 것" 뿐이다
--     → 남이 올린 파일 경로를 적어 넣어 훔쳐보는 것을 막는다
--   · 경로는 남긴 뒤 바꿀 수 없다 (작성자·작성시각과 같은 취급)
--
-- 아래 네 가지는 사용자 확인을 받고 넣는다(구조 변경, 데이터 무관):
--   drop constraint elaina_memos_body_check / elaina_memo_replies_body_check
--   drop function   elaina_post_memo(text,text,text,text)
--   drop function   elaina_post_reply(bigint,text)
-- 표·행은 건드리지 않는다.
-- ═══════════════════════════════════════════════════════════════

alter table edu.elaina_memos
  add column if not exists image_paths text[] not null default '{}';
alter table edu.elaina_memo_replies
  add column if not exists image_paths text[] not null default '{}';

comment on column edu.elaina_memos.image_paths is
  'elaina-memo 버킷 안 객체 경로. 공개 주소가 아니라 경로일 뿐이며, 볼 때마다 서명 URL 을 새로 만든다.';

-- ── 본문 제약: 글이 비어도 캡처가 있으면 통과 ──────────────────
alter table edu.elaina_memos drop constraint elaina_memos_body_check;
alter table edu.elaina_memos add constraint elaina_memos_body_check
  check (length(body) <= 4000
         and (length(btrim(body)) >= 1
              or coalesce(array_length(image_paths, 1), 0) >= 1));

alter table edu.elaina_memo_replies drop constraint elaina_memo_replies_body_check;
alter table edu.elaina_memo_replies add constraint elaina_memo_replies_body_check
  check (length(body) <= 4000
         and (length(btrim(body)) >= 1
              or coalesce(array_length(image_paths, 1), 0) >= 1));

-- ── 붙일 수 있는 이미지인지 확인 ────────────────────────────────
create or replace function edu.elaina_check_images(p_uid uuid, p_paths text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int := coalesce(array_length(p_paths, 1), 0);
begin
  if v_n = 0 then return; end if;
  if v_n > 10 then
    raise exception '캡처는 한 번에 10장까지만 붙일 수 있습니다.' using errcode = '22023';
  end if;

  if exists (
    select 1
      from unnest(p_paths) as t(path)
     where not exists (
       select 1 from storage.objects o
        where o.bucket_id = 'elaina-memo'
          and o.name      = t.path
          and o.owner     = p_uid          -- 본인이 올린 것만
     )
  ) then
    raise exception '본인이 방금 올린 캡처만 붙일 수 있습니다.' using errcode = '42501';
  end if;
end
$$;

comment on function edu.elaina_check_images(uuid, text[]) is
  '남이 올린 파일 경로를 본문에 적어 넣어 훔쳐보는 것을 막는다.';

-- ── 불변 규칙에 image_paths 도 포함 ────────────────────────────
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
    new.author_id    := v_uid;
    new.author_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    new.created_at   := now();
    new.mention_ids  := edu.elaina_called_ids(new.body);
    new.deleted_at   := null;
    new.deleted_by   := null;
    return new;
  end if;

  if old.deleted_at is not null then
    raise exception '이미 지운 글은 더 이상 바꿀 수 없습니다.' using errcode = '42501';
  end if;

  -- 본문도 붙인 캡처도 남긴 뒤에는 못 바꾼다
  new.body         := old.body;
  new.author_id    := old.author_id;
  new.author_email := old.author_email;
  new.created_at   := old.created_at;
  new.mention_ids  := old.mention_ids;
  new.image_paths  := old.image_paths;

  if tg_table_name = 'elaina_memos' then
    new.target_type  := old.target_type;
    new.target_id    := old.target_id;
    new.target_label := old.target_label;
  else
    new.memo_id := old.memo_id;
  end if;

  if new.deleted_at is not null then
    if not (old.author_id = v_uid or v_admin) then
      raise exception '본인이 쓴 글이거나 관리자일 때만 지울 수 있습니다.' using errcode = '42501';
    end if;
    new.deleted_at := now();
    new.deleted_by := v_uid;
  else
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end
$$;

revoke all on function edu.elaina_stamp() from public, anon, authenticated;

-- ── 남기기 (캡처 포함) ─────────────────────────────────────────
-- 인자를 늘려야 하는데 기본값을 준 채 늘리면 4개짜리와 겹쳐
-- PostgREST 가 "function is not unique" 로 실패한다. 그래서 갈아끼운다.
drop function if exists edu.elaina_post_memo(text, text, text, text);

create function edu.elaina_post_memo(
  p_target_type  text,
  p_target_id    text,
  p_target_label text,
  p_body         text,
  p_image_paths  text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_memo_id  bigint;
  v_imgs     int   := coalesce(array_length(p_image_paths, 1), 0);
  v_notified jsonb := '[]'::jsonb;
  v_blocked  jsonb := '[]'::jsonb;
  v_muted    jsonb := '[]'::jsonb;
  r          record;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.elaina_can_view(v_uid) then
    raise exception '이 화면에 메모를 남길 권한이 없습니다.' using errcode = '42501';
  end if;

  perform edu.elaina_check_images(v_uid, p_image_paths);

  insert into edu.elaina_memos (target_type, target_id, target_label, body, image_paths)
       values (p_target_type, p_target_id,
               nullif(btrim(coalesce(p_target_label,'')),''),
               p_body, coalesce(p_image_paths, '{}'))
    returning id into v_memo_id;

  for r in select * from edu.elaina_resolve_names(p_body) loop
    continue when r.user_id = v_uid;
    if not r.can_view then
      v_blocked  := v_blocked  || jsonb_build_object('name', r.name);
    elsif r.muted then
      v_muted    := v_muted    || jsonb_build_object('name', r.name);
    else
      v_notified := v_notified || jsonb_build_object('name', r.name);
    end if;
  end loop;

  return jsonb_build_object('memo_id',  v_memo_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

drop function if exists edu.elaina_post_reply(bigint, text);

create function edu.elaina_post_reply(
  p_memo_id     bigint,
  p_body        text,
  p_image_paths text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_reply_id bigint;
  v_dead     timestamptz;
  v_imgs     int   := coalesce(array_length(p_image_paths, 1), 0);
  v_notified jsonb := '[]'::jsonb;
  v_blocked  jsonb := '[]'::jsonb;
  v_muted    jsonb := '[]'::jsonb;
  r          record;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.' using errcode = '42501';
  end if;
  if not edu.elaina_can_view(v_uid) then
    raise exception '이 화면에 답글을 달 권한이 없습니다.' using errcode = '42501';
  end if;

  select m.deleted_at into v_dead from edu.elaina_memos m where m.id = p_memo_id;
  if not found then
    raise exception '그런 메모가 없습니다.' using errcode = '22023';
  end if;
  if v_dead is not null then
    raise exception '지워진 메모에는 답글을 달 수 없습니다.' using errcode = '42501';
  end if;

  perform edu.elaina_check_images(v_uid, p_image_paths);

  insert into edu.elaina_memo_replies (memo_id, body, image_paths)
       values (p_memo_id, p_body, coalesce(p_image_paths, '{}'))
    returning id into v_reply_id;

  for r in select * from edu.elaina_resolve_names(p_body) loop
    continue when r.user_id = v_uid;
    if not r.can_view then
      v_blocked  := v_blocked  || jsonb_build_object('name', r.name);
    elsif r.muted then
      v_muted    := v_muted    || jsonb_build_object('name', r.name);
    else
      v_notified := v_notified || jsonb_build_object('name', r.name);
    end if;
  end loop;

  return jsonb_build_object('reply_id', v_reply_id,
                            'images',   v_imgs,
                            'notified', v_notified,
                            'blocked',  v_blocked,
                            'muted',    v_muted);
end
$$;

-- ── 실행 권한 — anon 에는 아무것도 주지 않는다 ─────────────────
revoke all on function edu.elaina_check_images(uuid, text[]) from public, anon, authenticated;

revoke all on function edu.elaina_post_memo(text, text, text, text, text[]) from public, anon;
revoke all on function edu.elaina_post_reply(bigint, text, text[])          from public, anon;

grant execute on function edu.elaina_post_memo(text, text, text, text, text[]) to authenticated, service_role;
grant execute on function edu.elaina_post_reply(bigint, text, text[])          to authenticated, service_role;

notify pgrst, 'reload schema';