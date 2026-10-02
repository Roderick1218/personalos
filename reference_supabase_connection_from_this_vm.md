---
name: reference-supabase-connection-from-this-vm
description: "This VM can't reach Supabase's direct Postgres connection (IPv6-only, no local IPv6 route) — use the Supavisor pooler instead; how to find the right region"
metadata:
  node_type: memory
  type: reference
  originSessionId: c9acd624-f76b-483c-9ed7-aeaba1224f2b
  modified: 2026-09-30T08:57:04.887Z
---

This Windows VM has **no IPv6 route at all** (confirmed via `Test-NetConnection` in [[project_personal_life_os]]'s earlier session — TCP connect to a resolved IPv6 address fails outright, not a DNS issue). Supabase's direct-connection hostname (`db.<project-ref>.supabase.co`, port 5432) only has an `AAAA` (IPv6) DNS record, no `A` (IPv4) record, so **direct connection from this VM will always fail** — this is a durable environment limitation, not a per-project or per-credential problem.

**Working alternative: the Supavisor pooler**, which is IPv4-compatible:
- Host: `aws-0-<region>.pooler.supabase.com`
- Port: `6543` (transaction mode) — tried this first successfully; `5432` (session mode) is the other option if `6543` behaves oddly for a given use case
- Username: `postgres.<project-ref>` (note the project ref goes *after* `postgres.`, not as a separate field)
- Database: `postgres`
- Password: the project's DB password (same one used for direct connection)

**If the region is unknown**, brute-force common AWS regions — a wrong region gives a clean, fast, unambiguous error (`ENOTFOUND` / "tenant/user ... not found"), a right region connects immediately. Try in roughly this order for a Malaysia/SEA-based project: `ap-southeast-1`, `ap-southeast-2` (this is the one that worked for the `personal_os` Supabase project, project ref `xpbtyfattbqsaasmokoy` — `ap-southeast-1` was tried first and failed, so don't assume Singapore-region just because the user is in Malaysia), `ap-south-1`, then the US/EU regions.

**Practical setup used**: Node.js `pg` npm package (`npm install pg` in the session scratchpad directory), plain `Client` connection with `ssl: { rejectUnauthorized: false }` (Supabase's cert chain needs this relaxed in a quick script — fine for a one-off admin check, not something to bake into a real app's connection config without revisiting).

Once connected, useful verification queries: `information_schema.tables` (what exists), `pg_class.relrowsecurity` (RLS on/off per table), `pg_policies` (which policies exist) — this combination let a "did the migration actually work?" question get answered definitively from first principles instead of trusting old cached error messages the user had saved from a previous failed attempt.

**After running any `ALTER TABLE`/`DROP COLUMN`/etc. through this direct pooler connection (as opposed to Supabase's own dashboard SQL editor), the PostgREST API layer's schema cache can stay stale for a while** — symptom is a client (website or app) query against the changed table/column hanging or behaving as if the change never happened, even though `information_schema` and a raw REST call both confirm the DB itself is correct. Fix: run `NOTIFY pgrst, 'reload schema';` once through the same connection immediately after the DDL. Cheap and safe to run proactively after every migration script from now on, not just when something looks stale. See [[project_personal_os_mobile_background_features]] for the instance this caused ("通用提醒我现在刷新不出来" right after a `tag_id` column migration).
