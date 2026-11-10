/*
# Add QR code payment image to settings + storage bucket

1. Purpose
- Admin can upload a QR code image for cash-in payments.
- Users see the current QR code in the deposit modal.
- Admin can change it anytime without redeploying.

2. Changes
- Add `qr_code_url` text column to `settings` (defaults to the existing static image path).
- Create `qr-codes` storage bucket (public read, admin-only write).
- Storage policies: anyone can SELECT (public read), only admin can INSERT/UPDATE/DELETE.

3. Security
- `settings` table: extend existing admin update grant to cover the new column.
- Storage bucket `qr-codes`: public SELECT, admin-only write via is_admin() check.
*/

-- Add qr_code_url column to settings
ALTER TABLE public.settings ADD COLUMN IF NOT EXISTS qr_code_url text NOT NULL DEFAULT '/images/bank-payment_(2)_copy_2_copy.jpg';

-- Create qr-codes storage bucket (public read)
INSERT INTO storage.buckets (id, name, public)
VALUES ('qr-codes', 'qr-codes', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for qr-codes bucket
-- Public read (anyone can view the QR code, including non-authenticated visitors)
DROP POLICY IF EXISTS "qr_codes_public_read" ON storage.objects;
CREATE POLICY "qr_codes_public_read"
ON storage.objects FOR SELECT
TO anon, authenticated
USING (bucket_id = 'qr-codes');

-- Admin-only insert
DROP POLICY IF EXISTS "qr_codes_admin_insert" ON storage.objects;
CREATE POLICY "qr_codes_admin_insert"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'qr-codes' AND public.is_admin());

-- Admin-only update
DROP POLICY IF EXISTS "qr_codes_admin_update" ON storage.objects;
CREATE POLICY "qr_codes_admin_update"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'qr-codes' AND public.is_admin())
WITH CHECK (bucket_id = 'qr-codes' AND public.is_admin());

-- Admin-only delete
DROP POLICY IF EXISTS "qr_codes_admin_delete" ON storage.objects;
CREATE POLICY "qr_codes_admin_delete"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'qr-codes' AND public.is_admin());
