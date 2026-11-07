/*
# Lock race_results grants to read-only for signed-in users

1. Modified Tables
- `race_results`: removes the default write and maintenance privileges that the
  project setup grants every new public table.

2. Security
- `anon` loses all privileges on the table.
- `authenticated` keeps SELECT only, which the read policy already scopes.
- `service_role` is left as is.
- Only the settlement function writes results, and it runs with owner rights.

3. Notes
- TRUNCATE is not subject to row level security, so it must be revoked explicitly.
*/

REVOKE ALL ON public.race_results FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.race_results FROM authenticated;
