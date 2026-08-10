-- 등록된 모든 계정을 ADOM 명단에 넣는다 (사용자 선택).
-- 표시 이름 = 이메일 앞부분. 이미 있는 사람·이름이 겹치는 사람은 건너뛴다.
insert into edu.adom_viewers (user_id, email, display_name, added_by)
select u.id,
       lower(u.email),
       split_part(lower(u.email), '@', 1),
       (select v.user_id from edu.adom_viewers v where v.email = 'adom@pinkage.co.kr')
  from auth.users u
 where u.deleted_at is null
   and u.email is not null
   and not exists (select 1 from edu.adom_viewers v2
                    where v2.user_id = u.id)
   and not exists (select 1 from edu.adom_viewers v3
                    where v3.display_name = split_part(lower(u.email), '@', 1))
on conflict do nothing;