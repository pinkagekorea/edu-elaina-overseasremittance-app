-- 트리거 함수는 PostgREST 로 직접 호출할 수 없지만(반환형이 trigger),
-- "anon 에는 어떤 권한도 주지 않는다"를 문자 그대로 지키기 위해 기본 EXECUTE 도 회수한다.
revoke all on function edu.adom_memo_guard()         from public, anon;
revoke all on function edu.adom_reply_guard()        from public, anon;
revoke all on function edu.adom_notification_guard() from public, anon;
revoke all on function edu.adom_fanout()             from public, anon;

notify pgrst, 'reload schema';