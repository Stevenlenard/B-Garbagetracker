    <?php
// SMTP settings can be supplied WITHOUT editing this tracked file:
//   1. backend/email_credentials.php (untracked; see email_credentials.example.php), or
//   2. environment variables GT_SMTP_HOST / GT_SMTP_PORT / GT_SMTP_USER / GT_SMTP_PASS /
//      GT_SMTP_FROM / GT_SMTP_NAME.
// Anything supplied there wins; the values below are only the legacy fallback and should be
// removed (and the password rotated) once the untracked file exists on the server.
if (is_file(__DIR__ . '/email_credentials.php')) {
    include_once __DIR__ . '/email_credentials.php';
}
foreach (['HOST', 'PORT', 'USER', 'PASS', 'FROM', 'NAME'] as $__gtk) {
    $__gtv = getenv('GT_SMTP_' . $__gtk);
    if ($__gtv !== false && $__gtv !== '' && !defined('SMTP_' . $__gtk)) {
        define('SMTP_' . $__gtk, $__gtk === 'PORT' ? (int)$__gtv : $__gtv);
    }
}
// SMTP Configuration for Gmail
// Note: Use a Google App Password, NOT your regular Gmail password.
defined('SMTP_HOST') || define('SMTP_HOST', 'smtp.gmail.com');
defined('SMTP_PORT') || define('SMTP_PORT', 587);
defined('SMTP_USER') || define('SMTP_USER', 'princebarola191@gmail.com'); // Your Gmail
defined('SMTP_PASS') || define('SMTP_PASS', 'ogku kmnx ewto vcnf');    // Your Password/App Password
defined('SMTP_FROM') || define('SMTP_FROM', 'princebarola191@gmail.com'); // Same as SMTP_USER
defined('SMTP_NAME') || define('SMTP_NAME', 'Garbage Tracker Support');
?>