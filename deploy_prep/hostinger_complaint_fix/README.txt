RESIDENT COMPLAINT FIX - HOSTINGER UPLOAD (3 files, 1 upload, no database change)

BEFORE
 1. Hostinger hPanel > Files > File Manager > public_html/backend/   (the folder that already
    contains login.php and register.php; your site URL ends in /backend/).
 2. BACKUP: select file_complaint.php and get_complaints.php (and auth_token.php if it exists)
    > Download (or Copy to a new folder "backup_YYYYMMDD"). Keep them.

UPLOAD (one operation)
 3. In the same backend/ folder click Upload and select the 3 files in this folder's backend/:
        file_complaint.php
        get_complaints.php
        auth_token.php
    Choose "Overwrite" if asked.
    Do NOT upload anything else. Do NOT create auth_config.php (that would change auth behaviour).

CHECK (2 minutes)
 4. Open https://<your-site>/backend/get_complaints.php in the browser:
    expect JSON starting {"success":true,"data":[...  (not a blank page / "Fatal error").
 5. Submit a test complaint from the Resident Web portal, then open Admin > Complaints and refresh.
    Expect the complaint in the list and ONE new Admin notification.
    (An old Resident APK/Web may add a second notification until it is updated: expected.)

ROLLBACK
 6. Upload the backed-up file_complaint.php / get_complaints.php over the new ones.
    (auth_token.php can stay; it does nothing on its own.)

NOT INCLUDED ON PURPOSE: email_config.php, db_config.php, any credentials or database dumps.
Web/APK are NOT part of this step: deploy the PHP first, clients later.
