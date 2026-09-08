param(
    [Parameter(Mandatory=$true)]
    [string]$OptiRoot
)

$ErrorActionPreference = 'Stop'

function Normalize-LF([string]$s) {
    if ($null -eq $s) { return $s }
    return $s.Replace("`r`n", "`n")
}

# Start from the v3 patch which fixed stale/current-frame HUDless ordering,
# disabled the bad extra ResourceFlip, and kept the proven DX11->DX12 swapchain path.
$v3Patch = Join-Path $PSScriptRoot 'patch_optiscaler_0822_v3.ps1'
if (-not (Test-Path $v3Patch)) { throw "v3 base patch not found: $v3Patch" }
& $v3Patch -OptiRoot $OptiRoot

# -----------------------------------------------------------------------------
# v4 fix #1: force a REAL typed HUDless resource for Genshin's typeless NGX output.
#
# The live v3 log shows the current-frame output is DXGI format 27
# (R8G8B8A8_TYPELESS), while the presentation swapchain is format 28
# (R8G8B8A8_UNORM). Upstream 0822 treats those as the same precision group and can
# therefore skip HudlessFormatTransfer, later only relabeling the FFX descriptor.
# For this Genshin path, create the actual typed transfer resource instead. This
# targets the remaining dark/pixel horizontal band without touching MV/depth yet.
# -----------------------------------------------------------------------------
$fsrfgPath = Join-Path $OptiRoot 'OptiScaler\framegen\ffx\FSRFG_Dx12.cpp'
if (-not (Test-Path $fsrfgPath)) { throw "Source file not found: $fsrfgPath" }
$fsrfgText = Normalize-LF ([IO.File]::ReadAllText($fsrfgPath))

$hudlessOld = Normalize-LF @'
        auto resFormat = fResource->GetResource()->GetDesc().Format;
        _lastHudlessFormat = (FfxApiSurfaceFormat) ffxApiGetSurfaceFormatDX12(resFormat);

        if (_lastHudlessFormat != FFX_API_SURFACE_FORMAT_UNKNOWN && !CompareResourceFormats(resFormat, scFormat))
        {
            if (!HudlessFormatTransfer(fIndex, _device, scFormat, fResource))
            {
                LOG_WARN("Skipping hudless resource due to format mismatch! hudless: {}, swapchain: {}",
                         magic_enum::enum_name(_lastHudlessFormat), magic_enum::enum_name(scFfxFormat));

                _lastHudlessFormat = FFX_API_SURFACE_FORMAT_UNKNOWN;
                _frameResources[fIndex][type] = {};
                return false;
            }
            else
            {
                fResource->validity = FG_ResourceValidity::UntilPresent;
            }
        }

        _noHudless[fIndex] = false;
'@

$hudlessNew = Normalize-LF @'
        auto resFormat = fResource->GetResource()->GetDesc().Format;
        _lastHudlessFormat = (FfxApiSurfaceFormat) ffxApiGetSurfaceFormatDX12(resFormat);

        // Genshin's NGX output is commonly R8G8B8A8_TYPELESS while the visible FG
        // swapchain is R8G8B8A8_UNORM. They are copy-compatible, but passing the
        // typeless texture through and only relabeling its FFX description can leave
        // the FG swapchain sampling an ambiguous view. Force a physical format
        // transfer for typeless HUDless inputs.
        const bool typelessHudless =
            resFormat == DXGI_FORMAT_R8G8B8A8_TYPELESS ||
            resFormat == DXGI_FORMAT_B8G8R8A8_TYPELESS ||
            resFormat == DXGI_FORMAT_B8G8R8X8_TYPELESS ||
            resFormat == DXGI_FORMAT_R10G10B10A2_TYPELESS ||
            resFormat == DXGI_FORMAT_R16G16B16A16_TYPELESS;

        const bool regularFormatMismatch =
            _lastHudlessFormat != FFX_API_SURFACE_FORMAT_UNKNOWN && !CompareResourceFormats(resFormat, scFormat);

        if (typelessHudless || regularFormatMismatch)
        {
            if (!HudlessFormatTransfer(fIndex, _device, scFormat, fResource))
            {
                // The first call can legitimately initialize FormatTransfer and ask
                // for the next frame. Keep the normal SetResource failure semantics.
                LOG_WARN("GenshinFGCompat v4 HUDless transfer pending/failed: source={}, swapchain={}",
                         (UINT) resFormat, (UINT) scFormat);

                _lastHudlessFormat = FFX_API_SURFACE_FORMAT_UNKNOWN;
                _frameResources[fIndex][type] = {};
                return false;
            }
            else
            {
                fResource->validity = FG_ResourceValidity::UntilPresent;
                // GetResource() now resolves to the transfer buffer, which is in the
                // actual swapchain format. Tell FSR-FG that exact typed format too.
                _lastHudlessFormat = scFfxFormat;

                static bool genshinTypedHudlessLogged = false;
                if (!genshinTypedHudlessLogged)
                {
                    LOG_INFO("GenshinFGCompat v4 typed HUDless transfer: source format {} -> swapchain format {}, {}x{}",
                             (UINT) resFormat, (UINT) scFormat, fResource->width, fResource->height);
                    genshinTypedHudlessLogged = true;
                }
            }
        }

        _noHudless[fIndex] = false;
'@

if (-not $fsrfgText.Contains($hudlessOld)) { throw 'Expected 0822 FSRFG Hudless format block was not found after v3 patch' }
$fsrfgText = $fsrfgText.Replace($hudlessOld, $hudlessNew)
[IO.File]::WriteAllText($fsrfgPath, $fsrfgText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# v4 diagnostics: v3 logged only the first SetResource result. The first attempt
# can be rejected while the FSR-FG context is still in its startup/pause window.
# Log the first rejection AND the first later acceptance so the next user log tells
# us whether current-frame HUDless really becomes active.
# -----------------------------------------------------------------------------
$inputPath = Join-Path $OptiRoot 'OptiScaler\inputs\FG\Upscaler_Inputs_Dx12.cpp'
if (-not (Test-Path $inputPath)) { throw "Source file not found: $inputPath" }
$inputText = Normalize-LF ([IO.File]::ReadAllText($inputPath))

$diagOld = Normalize-LF @'
            const bool accepted = fg->SetResource(&hudless);
            static bool directHudlessLogged = false;
            if (!directHudlessLogged)
            {
                LOG_INFO("GenshinFGCompat v3 current-frame HUDless: accepted={}, {}x{}, format={}, frame={}",
                         accepted, desc.Width, desc.Height, (UINT) desc.Format, feature->FrameCount());
                directHudlessLogged = true;
            }
'@

$diagNew = Normalize-LF @'
            const bool accepted = fg->SetResource(&hudless);
            static bool hudlessRejectLogged = false;
            static bool hudlessAcceptLogged = false;

            if (!accepted && !hudlessRejectLogged)
            {
                LOG_INFO("GenshinFGCompat v4 current-frame HUDless: accepted=false, {}x{}, format={}, frame={}",
                         desc.Width, desc.Height, (UINT) desc.Format, feature->FrameCount());
                hudlessRejectLogged = true;
            }
            else if (accepted && !hudlessAcceptLogged)
            {
                LOG_INFO("GenshinFGCompat v4 current-frame HUDless: accepted=true, {}x{}, format={}, frame={}",
                         desc.Width, desc.Height, (UINT) desc.Format, feature->FrameCount());
                hudlessAcceptLogged = true;
            }
'@

if (-not $inputText.Contains($diagOld)) { throw 'Expected v3 HUDless diagnostic block was not found' }
$inputText = $inputText.Replace($diagOld, $diagNew)
[IO.File]::WriteAllText($inputPath, $inputText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# v4 fix #2: remove the presentation-side 60 Hz lock introduced by the conservative
# v2/v3 preset. ForceVsync=true + SyncInterval=1 makes the FG swapchain wait for
# vertical refresh. The external FPS Unlocker should own the game's requested cap.
# OptiScaler's own limiter stays disabled.
# -----------------------------------------------------------------------------
$iniPath = Join-Path $OptiRoot 'OptiScaler.ini'
if (-not (Test-Path $iniPath)) { throw "INI not found: $iniPath" }
$iniText = Normalize-LF ([IO.File]::ReadAllText($iniPath))

function Replace-OneIni([string]$content, [string]$key, [string]$value) {
    $pattern = '(?m)^' + [regex]::Escape($key) + '\s*=.*$'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) { throw "Expected one $key key, found $($matches.Count)" }
    return [regex]::Replace($content, $pattern, "$key=$value")
}

$iniText = Replace-OneIni $iniText 'OverrideVsync' 'false'
$iniText = Replace-OneIni $iniText 'ForceVsync' 'false'
$iniText = Replace-OneIni $iniText 'SyncInterval' '0'
$iniText = Replace-OneIni $iniText 'FramerateLimit' '0'

[IO.File]::WriteAllText($iniPath, $iniText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

Write-Host 'Genshin FSR FG v4 typed-HUDless + uncapped-present patch applied successfully.'