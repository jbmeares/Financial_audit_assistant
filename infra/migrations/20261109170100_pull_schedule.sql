-- local-test: skip (pg_cron and pg_net exist only on Supabase)
-- D3. The nightly schedule. pg_cron runs on UTC and New York shifts with daylight saving, so
-- the job fires at both 04:00 and 05:00 UTC. The era-pull function asks raw.is_midnight_eastern()
-- and only the run that lands in New York's midnight hour pulls; the other returns "skipped".
--
-- The call carries the project's anon key, which is public by design (it is the key a web page
-- would ship). The function requires a valid project JWT, and anon can read or write nothing in
-- the finance schemas. A dedicated trigger secret would be stronger; see infra/functions/era-pull/README.md.

select cron.unschedule(jobid) from cron.job where jobname = 'era-pull-nightly';

select cron.schedule(
  'era-pull-nightly',
  '0 4,5 * * *',
  $job$
  select net.http_post(
    url := 'https://lbhrkwjffgbfvmpyjuai.supabase.co/functions/v1/era-pull',
    body := '{"mode": "nightly"}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxiaHJrd2pmZmdiZnZtcHlqdWFpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODExMTUyODUsImV4cCI6MjA5NjY5MTI4NX0.fvsvuejhFDOyasw284Sf_bLCqgEyFPSzLgp_gMdiVAc'
    ),
    timeout_milliseconds := 150000
  );
  $job$
);
