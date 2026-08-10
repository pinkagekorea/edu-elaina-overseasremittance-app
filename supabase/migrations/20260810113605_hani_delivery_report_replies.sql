-- 답글로 부른 경우에도 '무엇으로 갔는지' 를 볼 수 있게 한다.
create or replace function edu.hani_delivery_report(p_memo_id bigint, p_reply_id bigint default null)
returns table (받는사람 text, 경로 text)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(v.display_name, '알 수 없음'),
         coalesce(n.slack_status, 'bell_only')
    from edu.hani_notifications n
    left join edu.hani_viewers v on v.user_id = n.recipient_id
   where n.memo_id is not distinct from p_memo_id
     and n.reply_id is not distinct from p_reply_id
     and (
       case when p_reply_id is null
            then exists (select 1 from edu.hani_memos m
                          where m.id = p_memo_id and m.author_id = auth.uid())
            else exists (select 1 from edu.hani_memo_replies r
                          where r.id = p_reply_id and r.author_id = auth.uid())
       end
     )
   order by 1
$$;

revoke all on function edu.hani_delivery_report(bigint, bigint) from public, anon;
grant execute on function edu.hani_delivery_report(bigint, bigint) to authenticated;