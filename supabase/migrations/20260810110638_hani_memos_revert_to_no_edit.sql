-- 교육자료 요구사항대로 되돌린다 : 남긴 뒤에는 본문을 고칠 수 없다.
drop trigger if exists hani_memos_fanout_edit        on edu.hani_memos;
drop trigger if exists hani_memo_replies_fanout_edit on edu.hani_memo_replies;

alter table edu.hani_memos        drop column if exists edited_at;
alter table edu.hani_memo_replies drop column if exists edited_at;

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

  -- UPDATE : 본문과 작성 기록은 되돌려 놓는다. 허용되는 변경은 '지움 표시' 하나뿐.
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