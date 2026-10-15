# Roblox Studio compatibility notes

This is a bounded, read-only comparison between the installed Windows Studio
executable and Madeira's Wine ARM64EC module farm. It records loader metadata
and import names only; it does not execute or decompile Roblox binaries.

## Evidence and boundary

- The inspected file was `RobloxStudioBeta.exe`, file/product version
  `0, 742, 0, 7421053`, PE32+ x86-64 (`0x8664`), SHA-256
  `0dbf33f09b53ed29dc39d8fe95d32dfbb7be3c05e7446168a8a9f2fbd17907e5`.
- This identity matches the earlier local `studio_inventory.csv` entry. That
  inventory is from the user's Windows installation and is not included in
  this repository.
- The prior static import record contains 5,618 imported-symbol rows for the
  main executable, with zero delay-loaded rows. Imports establish loader
  dependencies, not that every API is called on every run.
- Its direct imports include Qt5/Qtitan UI libraries, FBX SDK, D3D11, DXGI,
  desktop OpenGL, Windows UI/system libraries, Media Foundation components,
  and `EVR.dll`.
- Madeira's `app/Madeira/arm64ec-windows` directory already includes Wine
  built-ins for D3D11, DXGI, OpenGL, MFPlat, and the VC runtime module names.
  The Qt/Qtitan, FBX, allocator, and WebView2 DLLs are part of the Studio
  installation inventory, not Madeira's module farm; their availability in a
  Wine prefix depends on obtaining and installing Studio's own files.

## EVR import gap

**Verified:** The Studio import table names the non-delay import
`EVR.dll!MFCreateVideoSampleFromSurface`. The inspected installation's PE
inventory and Madeira's bundled ARM64EC module directory did not contain an
`evr.dll` at the time of this observation.

**Verified:** The pinned Wine source contains `wine/dlls/evr/evr.spec`, which
declares `MFCreateVideoSampleFromSurface`, and `wine/dlls/evr/Makefile.in`,
which builds `evr.dll`. That module imports `dxva2.dll`, which was also absent
from the app's ARM64EC Wine module farm; Wine source includes its implementation
at `wine/dlls/dxva2`.

**Change made:** CI builds Wine's `evr.dll` and `dxva2.dll` with the existing
ARM64EC Wine toolchain, checks both PE machine types and the required EVR
export, places them in the app's Wine DLL resource folder, and checks that the
unsigned IPA contains both.

**Not established:** The export's runtime semantics, the complete transitive
import closure for an installed Studio version, and whether Studio successfully
starts. Wine source presence and a matching export do not prove API behavior.

## API-set schema prerequisite

**Verified:** Madeira's iOS loader maps `apisetschema.dll` from the selected PE
architecture directory to populate the process API-set map. Its ARM64EC path
therefore needs `app/Madeira/arm64ec-windows/apisetschema.dll`; the module farm
did not contain that file in the inspected checkout. The inspected Studio PE
imports API-set contract DLL names, which Wine resolves through this schema
instead of by shipping a separate DLL for every contract.

**Verified:** The pinned Wine source builds `apisetschema.dll` as a data-only PE
with a `.apiset` section. Wine's resolver hashes the contract prefix through
the final version-independent segment, allowing a contract such as
`api-ms-win-core-winrt-string-l1-1-0` to use the schema's `...-l1-1-1` mapping
to `combase.dll`.

**Change made:** CI builds Wine's ARM64EC schema, checks its PE machine type
and `.apiset` section, stages it with the ARM64EC DLL farm, and verifies that
the unsigned IPA contains it. This proves the required schema resource is
packaged, not that all imported API-set functions are implemented or that
Studio starts.

## Overall assessment

This is a useful loader-compatibility improvement, not a Studio port or a
runtime compatibility result. The executable also depends on Qt/Qtitan, FBX,
WebView2, many Windows APIs, D3D11/DXGI, and media services. A device test must
first install a signed Madeira build, enable JIT, and attempt to install/start
Studio; failures should be captured from Madeira/Wine logs before pursuing more
API coverage. No Roblox Studio binaries or Microsoft runtime DLLs are shipped
by this repository change.
