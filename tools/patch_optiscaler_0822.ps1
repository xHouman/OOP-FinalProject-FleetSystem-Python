param(
    [Parameter(Mandatory=$true)]
    [string]$OptiRoot
)

$ErrorActionPreference = 'Stop'

function Normalize-LF([string]$s) {
    if ($null -eq $s) { return $s }
    return $s.Replace("`r`n", "`n")
}

# -----------------------------------------------------------------------------
# 1) DX11 -> DX12 visible FG swapchain compatibility
# -----------------------------------------------------------------------------
$path = Join-Path $OptiRoot 'OptiScaler\hooks\DxgiFactory_Hooks.cpp'
if (-not (Test-Path $path)) { throw "Source file not found: $path" }
$text = Normalize-LF ([IO.File]::ReadAllText($path))

$old = Normalize-LF @'
static bool PrepareDx12InteropDesc1(DXGI_SWAP_CHAIN_DESC1& desc)
{
    if (desc.SampleDesc.Count > 1)
    {
        LOG_ERROR("Dx11wDx12 interop does not support MSAA swapchains!");
        return false;
    }

    if (desc.BufferCount < 2)
        desc.BufferCount = 2;

    if (desc.SwapEffect == DXGI_SWAP_EFFECT_DISCARD)
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    else if (desc.SwapEffect == DXGI_SWAP_EFFECT_SEQUENTIAL)
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;

    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    return true;
}
'@

$new = Normalize-LF @'
static bool PrepareDx12InteropDesc1(DXGI_SWAP_CHAIN_DESC1& desc)
{
    // Genshin DX11 -> DX12 FG compatibility path.
    // The visible DX12 swapchain is an interop/presentation swapchain, so normalize
    // the DX11 descriptor to a conservative flip-model descriptor accepted by D3D12.
    LOG_INFO("GenshinFGCompat original desc: {}x{}, fmt={}, buffers={}, usage={:X}, flags={:X}, swap={}, scaling={}, alpha={}, stereo={}, sample={}/{}",
             desc.Width, desc.Height, (UINT) desc.Format, desc.BufferCount, desc.BufferUsage, desc.Flags,
             (UINT) desc.SwapEffect, (UINT) desc.Scaling, (UINT) desc.AlphaMode, desc.Stereo,
             desc.SampleDesc.Count, desc.SampleDesc.Quality);

    if (desc.SampleDesc.Count > 1)
        LOG_WARN("GenshinFGCompat: converting MSAA swapchain to non-MSAA for DX12 interop");

    if (desc.BufferCount < 2)
        desc.BufferCount = 2;

    // D3D12 HWND swapchains require flip model. FLIP_DISCARD is the least restrictive
    // choice for this helper interop presentation chain.
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.Stereo = FALSE;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;

    // Keep only the waitable-object flag when the game requested it. DX11-era flags
    // such as ALLOW_MODE_SWITCH or GDI_COMPATIBLE can make the helper DX12 flip chain invalid.
    desc.Flags &= DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

    // Flip-model swapchains do not accept sRGB/typeless back-buffer formats.
    switch (desc.Format)
    {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS:
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        break;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        break;
    case DXGI_FORMAT_B8G8R8X8_TYPELESS:
    case DXGI_FORMAT_B8G8R8X8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        break;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS:
        desc.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
        break;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS:
        desc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
        break;
    default:
        break;
    }

    LOG_INFO("GenshinFGCompat sanitized desc: {}x{}, fmt={}, buffers={}, usage={:X}, flags={:X}, swap={}, scaling={}, alpha={}, stereo={}, sample={}/{}",
             desc.Width, desc.Height, (UINT) desc.Format, desc.BufferCount, desc.BufferUsage, desc.Flags,
             (UINT) desc.SwapEffect, (UINT) desc.Scaling, (UINT) desc.AlphaMode, desc.Stereo,
             desc.SampleDesc.Count, desc.SampleDesc.Quality);
    return true;
}
'@

if (-not $text.Contains($old)) { throw 'Expected PrepareDx12InteropDesc1 block was not found in exact 0822 source' }
$text = $text.Replace($old, $new)

$needle = Normalize-LF @'
                    if (realScResult == S_OK && PrepareDx12InteropDesc1(fgDesc))
                    {
                        {
'@
$insert = Normalize-LF @'
                    if (realScResult == S_OK && PrepareDx12InteropDesc1(fgDesc))
                    {
                        // Resolve zero-sized descriptors before handing the visible interop chain to D3D12.
                        if (fgDesc.Width == 0 || fgDesc.Height == 0)
                        {
                            RECT clientRect {};
                            if (GetClientRect(hWnd, &clientRect))
                            {
                                if (fgDesc.Width == 0)
                                    fgDesc.Width = static_cast<UINT>(clientRect.right - clientRect.left);
                                if (fgDesc.Height == 0)
                                    fgDesc.Height = static_cast<UINT>(clientRect.bottom - clientRect.top);
                            }
                        }

                        LOG_INFO("GenshinFGCompat creating windowed DX12 FG interop swapchain: {}x{}, fmt={}, buffers={}, flags={:X}",
                                 fgDesc.Width, fgDesc.Height, (UINT) fgDesc.Format, fgDesc.BufferCount, fgDesc.Flags);
                        {
'@
if (-not $text.Contains($needle)) { throw 'Expected DX11 interop block was not found' }
$text = $text.Replace($needle, $insert)

$oldFgCall = Normalize-LF @'
                            fgScResult = FGHooks::CreateSwapChainForHwnd(
                                realFactory, dx12Queue, hWnd, &fgDesc,
                                pFullscreenDesc != nullptr ? &localFullscreenDesc : nullptr, pRestrictToOutput,
                                &fgSwapChain1);
'@
$newFgCall = Normalize-LF @'
                            // The helper DX12 presentation chain must stay windowed/borderless.
                            fgScResult = FGHooks::CreateSwapChainForHwnd(realFactory, dx12Queue, hWnd, &fgDesc,
                                                                        nullptr, pRestrictToOutput, &fgSwapChain1);
'@
if (-not $text.Contains($oldFgCall)) { throw 'Expected FGHooks interop call was not found' }
$text = $text.Replace($oldFgCall, $newFgCall)

$oldFallback = Normalize-LF @'
                            fgScResult =
                                o_CreateSwapChainForHwnd(realFactory, dx12Queue, hWnd, &fgDesc,
                                                         pFullscreenDesc != nullptr ? &localFullscreenDesc : nullptr,
                                                         pRestrictToOutput, &fgSwapChain1);
'@
$newFallback = Normalize-LF @'
                            fgScResult = o_CreateSwapChainForHwnd(realFactory, dx12Queue, hWnd, &fgDesc, nullptr,
                                                                  pRestrictToOutput, &fgSwapChain1);
'@
if (-not $text.Contains($oldFallback)) { throw 'Expected plain DX12 fallback call was not found' }
$text = $text.Replace($oldFallback, $newFallback)

[IO.File]::WriteAllText($path, $text.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# 2) Genshin DX11wDX12 OptiFG inputs
#    0822 already bridges MV/depth, but unlike the native DX12 input path it never
#    supplies a deterministic pre-HUD color image. Feed the already-produced DX12
#    upscaler output directly as HudlessColor. This removes heuristic UI detection
#    from the critical path and prevents real/generated-frame image alternation.
# -----------------------------------------------------------------------------
$inputPath = Join-Path $OptiRoot 'OptiScaler\inputs\FG\Upscaler_Inputs_Dx11wDx12.cpp'
if (-not (Test-Path $inputPath)) { throw "Source file not found: $inputPath" }
$inputText = Normalize-LF ([IO.File]::ReadAllText($inputPath))

$maskOld = 'const auto mask = Dx11WithDx12::ResourceMask::Mv | Dx11WithDx12::ResourceMask::Depth;'
$maskNew = 'const auto mask = Dx11WithDx12::ResourceMask::Mv | Dx11WithDx12::ResourceMask::Depth | Dx11WithDx12::ResourceMask::Output;'
$maskCount = ([regex]::Matches($inputText, [regex]::Escape($maskOld))).Count
if ($maskCount -ne 2) { throw "Expected exactly 2 DX11wDx12 FG resource masks, found $maskCount" }
$inputText = $inputText.Replace($maskOld, $maskNew)

$cfgNeedle = Normalize-LF @'
    auto& cfg = *Config::Instance();
    const auto& ngxParams = *InParameters;
'@
$cfgInsert = Normalize-LF @'
    auto& cfg = *Config::Instance();
    const auto& ngxParams = *InParameters;

    // Genshin is Unity. OptiScaler's newer Unity handling enables ResourceFlip for
    // Upscaler FG input because Unity depth/velocity orientation otherwise produces
    // severe motion smearing. Keep the Genshin-specific 0822 build deterministic.
    static bool genshinInputCompatLogged = false;
    if (!cfg.FGResourceFlip.value_or_default())
        cfg.FGResourceFlip.set_volatile_value(true);

    // DepthScale is a DLSS-D / UE workaround. It corrupts Genshin's normal depth input.
    if (cfg.FGEnableDepthScale.value_or_default())
        cfg.FGEnableDepthScale.set_volatile_value(false);

    if (!genshinInputCompatLogged)
    {
        LOG_INFO("GenshinFGCompat inputs: Unity ResourceFlip=ON, DepthScale=OFF, direct pre-HUD output enabled");
        genshinInputCompatLogged = true;
    }
'@
if (-not $inputText.Contains($cfgNeedle)) { throw 'Expected DX11wDx12 config block was not found' }
$inputText = $inputText.Replace($cfgNeedle, $cfgInsert)

$oldEnd = Normalize-LF @'
void UpscalerInputsDx11wDx12::UpscaleEnd(NVSDK_NGX_Parameter* InParameters, IFeature_Dx11* feature)
{
    if (InParameters == nullptr || feature == nullptr)
        return;

    auto fg = State::Instance().currentFG;

    if (fg == nullptr || State::Instance().activeFgInput != FGInput::Upscaler || _dx12Device == nullptr)
        return;

    if (fg->IsActive() && Config::Instance()->FGEnabled.value_or_default() &&
        State::Instance().currentSwapchain != nullptr)
        LOG_DEBUG("(FG Dx11wDx12) running, frame: {}", feature->FrameCount());
}
'@
$newEnd = Normalize-LF @'
void UpscalerInputsDx11wDx12::UpscaleEnd(NVSDK_NGX_Parameter* InParameters, IFeature_Dx11* feature)
{
    if (InParameters == nullptr || feature == nullptr)
        return;

    auto fg = State::Instance().currentFG;

    if (fg == nullptr || State::Instance().activeFgInput != FGInput::Upscaler || _dx12Device == nullptr)
        return;

    if (fg->IsActive() && Config::Instance()->FGEnabled.value_or_default() &&
        State::Instance().currentSwapchain != nullptr)
    {
        // The DX11wDX12 upscaler cache already owns the just-rendered DX12 output.
        // At this point IFeature_Dx11wDx12::Evaluate has completed the upscaler and
        // synchronized its output back to D3D11, while the cached DX12 resource still
        // contains the pre-UI image. Use it as a deterministic HUDless source.
        auto& cache = Dx11WithDx12::GetUpscalerResourceCache();
        const auto outputIndex = Dx11WithDx12::GetUpscalerFrameIndex() % DX11_WITH_DX12_CACHED_FRAMES;
        auto& cachedOutput = cache.Output[outputIndex];
        const auto preparedFrame = Dx11WithDx12::GetLastPreparedUpscalerFrameId();
        auto cmdList = fg->GetUICommandList();

        if (cachedOutput.Dx12Resource != nullptr && cmdList != nullptr && preparedFrame != 0 &&
            cachedOutput.LastPreparedFrame == preparedFrame)
        {
            const auto desc = cachedOutput.Dx12Resource->GetDesc();

            Dx12Resource hudless {};
            hudless.type = FG_ResourceType::HudlessColor;
            hudless.cmdList = cmdList;
            hudless.resource = cachedOutput.Dx12Resource;
            hudless.left = 0;
            hudless.top = 0;
            hudless.width = desc.Width;
            hudless.height = desc.Height;
            hudless.state = (D3D12_RESOURCE_STATES) Config::Instance()->OutputResourceBarrier.value_or(
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            hudless.validity = FG_ResourceValidity::ValidNow;

            if (fg->SetResource(&hudless))
            {
                static bool directHudlessLogged = false;
                if (!directHudlessLogged)
                {
                    LOG_INFO("GenshinFGCompat HUDless: using cached pre-UI upscaler output {}x{}, format {}",
                             desc.Width, desc.Height, (UINT) desc.Format);
                    directHudlessLogged = true;
                }
            }
            else
            {
                LOG_TRACE("GenshinFGCompat HUDless: SetResource skipped for frame {}", fg->FrameCount());
            }
        }
        else
        {
            LOG_WARN("GenshinFGCompat HUDless unavailable: output={}, cmdList={}, prepared={}, outputFrame={}",
                     (size_t) cachedOutput.Dx12Resource, (size_t) cmdList, preparedFrame,
                     cachedOutput.LastPreparedFrame);
        }

        LOG_DEBUG("(FG Dx11wDx12) running, frame: {}", feature->FrameCount());
    }
}
'@
if (-not $inputText.Contains($oldEnd)) { throw 'Expected DX11wDx12 UpscaleEnd block was not found' }
$inputText = $inputText.Replace($oldEnd, $newEnd)
[IO.File]::WriteAllText($inputPath, $inputText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# 3) Ignore stale/custom FG rectangles for the Genshin DX11wDX12 path.
#    A saved RectLeft/Width/Height (including zero width/height) overrides the
#    correct interpolation rectangle in FSRFG_Dx12 and can visibly offset/corrupt FG.
# -----------------------------------------------------------------------------
$fsrfgPath = Join-Path $OptiRoot 'OptiScaler\framegen\ffx\FSRFG_Dx12.cpp'
if (-not (Test-Path $fsrfgPath)) { throw "Source file not found: $fsrfgPath" }
$fsrfgText = Normalize-LF ([IO.File]::ReadAllText($fsrfgPath))

$rectOld = Normalize-LF @'
        fgConfig.generationRect.left = config->FGRectLeft.value_or(_interpolationLeft[fIndex].value_or(defaultLeft));
        fgConfig.generationRect.top = config->FGRectTop.value_or(_interpolationTop[fIndex].value_or(defaultTop));
        fgConfig.generationRect.width = config->FGRectWidth.value_or(defaultWidth);
        fgConfig.generationRect.height = config->FGRectHeight.value_or(defaultHeight);
'@
$rectNew = Normalize-LF @'
        if (state.swapchainInteropApi == SwapchainInteropApi::Dx11wDx12 &&
            state.activeFgInput == FGInput::Upscaler)
        {
            // Genshin bridge always interpolates the full upscaled frame. Ignore stale
            // custom rectangle values from older experiments/configs.
            fgConfig.generationRect.left = 0;
            fgConfig.generationRect.top = 0;
            fgConfig.generationRect.width = defaultWidth;
            fgConfig.generationRect.height = defaultHeight;
        }
        else
        {
            fgConfig.generationRect.left = config->FGRectLeft.value_or(_interpolationLeft[fIndex].value_or(defaultLeft));
            fgConfig.generationRect.top = config->FGRectTop.value_or(_interpolationTop[fIndex].value_or(defaultTop));
            fgConfig.generationRect.width = config->FGRectWidth.value_or(defaultWidth);
            fgConfig.generationRect.height = config->FGRectHeight.value_or(defaultHeight);
        }
'@
if (-not $fsrfgText.Contains($rectOld)) { throw 'Expected FSRFG generation rectangle block was not found' }
$fsrfgText = $fsrfgText.Replace($rectOld, $rectNew)
[IO.File]::WriteAllText($fsrfgPath, $fsrfgText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# 4) Ship a conservative Genshin FSR-FG preset.
#    No external FPS limiter is enabled. V-Sync is applied at the FG swapchain
#    Present path (SyncInterval 1) to prevent tearing; the display refresh remains
#    the physical presentation ceiling.
# -----------------------------------------------------------------------------
$iniPath = Join-Path $OptiRoot 'OptiScaler.ini'
if (-not (Test-Path $iniPath)) { throw "INI not found: $iniPath" }
$iniText = Normalize-LF ([IO.File]::ReadAllText($iniPath))

function Set-IniValue([string]$content, [string]$section, [string]$key, [string]$value) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($content -split "`n")) { [void]$lines.Add($line) }
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trim = $lines[$i].Trim()
        if ($trim -match '^\[(.+)\]$') {
            $inSection = [string]::Equals($Matches[1], $section, [StringComparison]::OrdinalIgnoreCase)
            continue
        }
        if ($inSection -and $trim -match ('^' + [regex]::Escape($key) + '\s*=')) {
            $lines[$i] = "$key=$value"
            return ($lines -join "`n")
        }
    }
    throw "INI key not found: [$section] $key"
}

$settings = @(
    @('FrameGen','Enabled','true'),
    @('FrameGen','FGInput','upscaler'),
    @('FrameGen','FGOutput','fsrfg'),
    @('FrameGen','FTInput','0'),
    @('FrameGen','DebugView','false'),
    @('FrameGen','DrawUIOverFG','false'),
    @('FrameGen','RectLeft','auto'),
    @('FrameGen','RectTop','auto'),
    @('FrameGen','RectWidth','auto'),
    @('FrameGen','RectHeight','auto'),
    @('FrameGen','AllowedFrameAhead','1'),
    @('FrameGen','HudCutoff','0.0'),

    @('FSRFG','DebugTearLines','false'),
    @('FSRFG','DebugResetLines','false'),
    @('FSRFG','DebugPacingLines','false'),
    @('FSRFG','AllowAsync','false'),
    @('FSRFG','UseMutexForSwapchain','true'),
    @('FSRFG','FramePacingTuning','true'),
    @('FSRFG','FPTSafetyMarginInMs','0.10'),
    @('FSRFG','FPTVarianceFactor','0.10'),
    @('FSRFG','FPTHybridSpin','false'),
    @('FSRFG','FPTHybridSpinTime','2'),
    @('FSRFG','FPTWaitForSingleObjectOnFence','false'),

    @('OptiFG','HUDFix','false'),
    @('OptiFG','HUDLimit','1'),
    @('OptiFG','HUDFixExtended','false'),
    @('OptiFG','HUDFixImmediate','false'),
    @('OptiFG','HUDFixDontUseSwapchainBuffers','false'),
    @('OptiFG','ResourceBlocking','false'),
    @('OptiFG','MakeDepthCopy','true'),
    @('OptiFG','EnableDepthScale','false'),
    @('OptiFG','MakeMVCopy','true'),
    @('OptiFG','ResourceFlip','true'),
    @('OptiFG','ResourceFlipOffset','false'),

    @('V-Sync','OverrideVsync','false'),
    @('V-Sync','ForceVsync','true'),
    @('V-Sync','SyncInterval','1'),
    @('Framerate','FramerateLimit','0')
)

foreach ($setting in $settings) {
    $iniText = Set-IniValue $iniText $setting[0] $setting[1] $setting[2]
}

[IO.File]::WriteAllText($iniPath, $iniText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

Write-Host 'Genshin FSR FG v2 compatibility/HUDless/pacing patch applied successfully.'
