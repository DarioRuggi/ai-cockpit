<?php
// saas.php — the account layer is NOT part of the open-source release.
// In the full product this file talks to the Cockpit account server (sign-in, plans, the Everywhere relay pairing). Here it answers
// every request with the same refusal, so the Stand-alone edition (which never calls it) and every other file keep working.
header('Content-Type: application/json');
echo json_encode(['ok' => false, 'error' => 'The Cockpit account layer is not part of the open-source release.', 'open_source' => true]);
