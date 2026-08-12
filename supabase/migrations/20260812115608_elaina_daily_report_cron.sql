-- ═══════════════════════════════════════════════════════════════
-- 데일리 리포트 — 매일 아침 9시
--
--   '0 0 * * *' = 00:00 UTC = 한국 09:00.
--   한국은 서머타임이 없어 연중 고정이다. cron 은 UTC 로만 돈다.
--
--   같은 이름으로 다시 걸면 이전 등록을 지우고 새로 건다 (중복 방지).
-- ═══════════════════════════════════════════════════════════════

select cron.unschedule(jobid)
  from cron.job
 where jobname = 'elaina-daily-report';

select cron.schedule(
  'elaina-daily-report',
  '0 0 * * *',
  $job$ select edu.elaina_build_daily_report(); $job$
);
