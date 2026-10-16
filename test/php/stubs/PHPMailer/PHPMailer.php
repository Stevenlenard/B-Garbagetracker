<?php
namespace PHPMailer\PHPMailer;
// TEST STUB: records the message instead of sending it.
class PHPMailer {
    const ENCRYPTION_STARTTLS = 'tls';
    public $Host, $SMTPAuth, $Username, $Password, $SMTPSecure, $Port, $Subject, $Body;
    private $to = [];
    public function __construct($exceptions = false) {}
    public function isSMTP() {}
    public function isHTML($b) {}
    public function setFrom($a, $n = '') {}
    public function addAddress($a) { $this->to[] = $a; }
    public $ErrorInfo = '';
    public $Timeout;
    public function send() {
        if (getenv('GT_FAKE_MAIL_FAIL')) {
            throw new Exception('SMTP Error: Could not authenticate. user=' . $this->Username . ' pass=' . $this->Password);
        }
        file_put_contents(getenv('GT_PHP_STATE') . '.mail', json_encode([
            'to' => $this->to, 'subject' => $this->Subject, 'body' => $this->Body,
        ]) . "\n", FILE_APPEND);
        return true;
    }
}
