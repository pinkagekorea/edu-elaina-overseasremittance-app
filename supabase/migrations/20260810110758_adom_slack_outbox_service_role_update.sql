-- Edge Function 이 발송 결과(status·tier·detail·sent_at)를 되돌려 적어야 하는데
-- service_role 에 UPDATE 가 없어 조용히 실패하고 있었다. 필요한 만큼만 준다.
-- (짝 맞춤표는 읽기만 하므로 SELECT 로 충분 — 이미 있다.)
grant update on edu.adom_slack_outbox to service_role;