# Madeira dummy Credential Manager probe

This diagnostic checks the `CredWriteW` → `CredReadW` → `CredDeleteW` path
inside the Wine prefix used to launch it. It uses a unique target and a
hard-coded dummy blob; it does not enumerate, read, change, or log any other
credential. It is not a Roblox login test.

## Build and run

Run the **Build dummy credential probe** workflow manually from GitHub Actions.
Download its `madeira-dummy-credential-probe` artifact and import
`credential-manager-probe.exe` into Madeira as a temporary program. Launch it
using the same Madeira installation and Wine prefix as Studio; do not create,
reset, or migrate a prefix for this test.

Expected output is three `PASS` lines for write, read-back, and deletion, then
a final result line. If cleanup fails, the output says so; the leftover value
is only the dummy blob and has a unique target. Remove the temporary program
from Madeira after the test. A successful result proves only that this Wine
build's generic Credential Manager round trip works in that prefix. It does
not prove Roblox Studio accepts credentials stored there.
