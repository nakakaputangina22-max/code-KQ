/*
# Remove anon grants from chat_messages

1. Problem
- chat_messages had anon grants (SELECT/INSERT/UPDATE/DELETE) left over from
  the initial migration. This is a signed-in app — anon should have no access.
- Extra grants on anon don't directly cause the insert failure but are
  unnecessary surface area.

2. Fix
- REVOKE all privileges on chat_messages FROM anon.
- authenticated keeps SELECT, INSERT, UPDATE (no DELETE).
*/

REVOKE SELECT, INSERT, UPDATE, DELETE ON chat_messages FROM anon;
