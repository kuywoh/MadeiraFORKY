/*
 * Madeira dummy Credential Manager probe.
 *
 * Writes a unique, non-secret generic credential, reads it back, compares
 * the dummy bytes, and deletes it. It never enumerates or accesses other
 * credentials and never prints the credential blob.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#pragma comment(lib, "Advapi32.lib")

static const BYTE dummy_blob[] = "MADEIRA-DUMMY-ONLY-NOT-A-SECRET";

int wmain(void)
{
    WCHAR target[96];
    CREDENTIALW credential = {0};
    PCREDENTIALW read_back = NULL;
    BOOL wrote = FALSE;
    int result = 1;
    DWORD error;

    if (swprintf_s(target, _countof(target),
                   L"Madeira-Dummy-Credential-Probe-%lu-%llu",
                   GetCurrentProcessId(), GetTickCount64()) < 0)
    {
        puts("FAIL: could not create a unique dummy target name");
        return 1;
    }

    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = target;
    credential.CredentialBlob = (LPBYTE)dummy_blob;
    credential.CredentialBlobSize = (DWORD)(sizeof(dummy_blob) - 1);
    credential.Persist = CRED_PERSIST_SESSION;
    credential.UserName = L"Madeira dummy probe";

    if (!CredWriteW(&credential, 0))
    {
        printf("FAIL: CredWriteW error %lu\n", GetLastError());
        return 1;
    }
    wrote = TRUE;
    puts("PASS: CredWriteW stored a dummy generic credential");

    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &read_back))
    {
        printf("FAIL: CredReadW error %lu\n", GetLastError());
        goto cleanup;
    }

    if (read_back->CredentialBlobSize != sizeof(dummy_blob) - 1 ||
        memcmp(read_back->CredentialBlob, dummy_blob, sizeof(dummy_blob) - 1) != 0)
    {
        puts("FAIL: read-back did not match the dummy bytes");
        CredFree(read_back);
        read_back = NULL;
        goto cleanup;
    }

    CredFree(read_back);
    read_back = NULL;
    puts("PASS: CredReadW returned the matching dummy credential");
    result = 0;

cleanup:
    if (read_back) CredFree(read_back);
    if (wrote)
    {
        if (!CredDeleteW(target, CRED_TYPE_GENERIC, 0))
        {
            error = GetLastError();
            printf("FAIL: CredDeleteW cleanup error %lu\n", error);
            result = 1;
        }
        else
        {
            puts("PASS: CredDeleteW removed the dummy credential");
        }
    }

    if (!result) puts("RESULT: dummy credential round-trip passed; no Roblox credentials were accessed");
    return result;
}
