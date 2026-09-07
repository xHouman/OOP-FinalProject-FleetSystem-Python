param(
    [Parameter(Mandatory=$true)]
    [string]$OptiRoot
)

$ErrorActionPreference = 'Stop'
$path = Join-Path $OptiRoot 'OptiScaler\hooks\DxgiFactory_Hooks.cpp'
if (-not (Test-Path $path)) { throw "Source file not found: $path" }

$text = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")

$old = @'
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

$new = @'
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

    // D3D12 HWND swapchains use flip model. FLIP_DISCARD is the least restrictive
    // choice for this interop presentation chain.
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.Stereo = FALSE;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;

    // Keep only the waitable-object flag if the game requested it. Other DX11-era
    // flags can make a D3D12 flip-model CreateSwapChainForHwnd call fail.
    desc.Flags &= DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

    // Flip-model swapchains do not accept sRGB/typeless back-buffer formats. Map
    // them to resource-compatible non-sRGB presentation formats.
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

$needle = @'
                    if (realScResult == S_OK && PrepareDx12InteropDesc1(fgDesc))
                    {
                        {
'@
$insert = @'
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

$oldFgCall = @'
                            fgScResult = FGHooks::CreateSwapChainForHwnd(
                                realFactory, dx12Queue, hWnd, &fgDesc,
                                pFullscreenDesc != nullptr ? &localFullscreenDesc : nullptr, pRestrictToOutput,
                                &fgSwapChain1);
'@
$newFgCall = @'
                            // The helper DX12 presentation chain must stay windowed/borderless.
                            fgScResult = FGHooks::CreateSwapChainForHwnd(realFactory, dx12Queue, hWnd, &fgDesc,
                                                                        nullptr, pRestrictToOutput, &fgSwapChain1);
'@
if (-not $text.Contains($oldFgCall)) { throw 'Expected FGHooks interop call was not found' }
$text = $text.Replace($oldFgCall, $newFgCall)

$oldFallback = @'
                            fgScResult =
                                o_CreateSwapChainForHwnd(realFactory, dx12Queue, hWnd, &fgDesc,
                                                         pFullscreenDesc != nullptr ? &localFullscreenDesc : nullptr,
                                                         pRestrictToOutput, &fgSwapChain1);
'@
$newFallback = @'
                            fgScResult = o_CreateSwapChainForHwnd(realFactory, dx12Queue, hWnd, &fgDesc, nullptr,
                                                                  pRestrictToOutput, &fgSwapChain1);
'@
if (-not $text.Contains($oldFallback)) { throw 'Expected plain DX12 fallback call was not found' }
$text = $text.Replace($oldFallback, $newFallback)

[IO.File]::WriteAllText($path, $text.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
Write-Host 'Genshin FSR FG compatibility patch applied successfully.'
