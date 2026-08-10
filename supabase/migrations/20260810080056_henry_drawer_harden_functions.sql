-- 린터 지적 보완 (0011 / 0028 / 0029)

-- 1) 가드 함수 search_path 고정
alter function edu.henry_guard_immutable()    set search_path = edu, pg_catalog;
alter function edu.henry_guard_notification() set search_path = edu, pg_catalog;

-- 2) 알림 트리거 함수는 트리거 전용이다. REST 로 부를 이유가 없으므로
--    EXECUTE 를 전부 회수한다. 트리거 실행은 EXECUTE 권한과 무관하다.
revoke all on function edu.henry_notify_mention() from anon, authenticated, public;
revoke all on function edu.henry_notify_reply()   from anon, authenticated, public;

-- 3) 가드 함수도 같은 이유로 회수
revoke all on function edu.henry_guard_immutable()    from anon, authenticated, public;
revoke all on function edu.henry_guard_notification() from anon, authenticated, public;

-- henry_is_member() / henry_is_admin() 의 authenticated EXECUTE 는 유지한다.
-- RLS 정책 식이 호출자 권한으로 평가되므로 회수하면 정책이 깨진다.
-- 반환값은 "나 자신이 멤버/관리자인가" 라는 불리언 하나뿐이라 노출 위험이 없다.
