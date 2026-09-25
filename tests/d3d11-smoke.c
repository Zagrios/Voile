/* Creates a D3D11 device and swap chain, presents 120 frames and prints what
 * it got. wined3d on macOS stops below feature level 11_0; D3DMetal and DXMT
 * reach it.
 *
 * x86_64-w64-mingw32-clang -O2 -o d3d11-smoke.exe d3d11-smoke.c -ld3d11 -ldxgi -ldxguid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

int main(void)
{
    WNDCLASSW class = {
        .lpfnWndProc = DefWindowProcW,
        .hInstance = GetModuleHandleW(NULL),
        .lpszClassName = L"ForgeSmoke",
    };
    RegisterClassW(&class);
    HWND window = CreateWindowW(L"ForgeSmoke", L"Forge D3D11 smoke test",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT, 640, 360,
        NULL, NULL, class.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC description = {
        .BufferDesc = { .Width = 640, .Height = 360, .Format = DXGI_FORMAT_R8G8B8A8_UNORM },
        .SampleDesc = { .Count = 1 },
        .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .OutputWindow = window,
        .Windowed = TRUE,
        .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD,
    };
    IDXGISwapChain *swap_chain;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    D3D_FEATURE_LEVEL level;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
        D3D11_SDK_VERSION, &description, &swap_chain, &device, &level, &context);
    if (FAILED(hr)) {
        printf("D3D11CreateDeviceAndSwapChain failed: 0x%08lx\n", hr);
        return 1;
    }

    IDXGIDevice *dxgi;
    IDXGIAdapter *adapter;
    DXGI_ADAPTER_DESC adapter_description;
    ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi);
    IDXGIDevice_GetAdapter(dxgi, &adapter);
    IDXGIAdapter_GetDesc(adapter, &adapter_description);
    printf("Adapter: %ls\n", adapter_description.Description);
    printf("Feature level: %d_%d\n", level >> 12, (level >> 8) & 0xf);

    ID3D11Texture2D *back_buffer;
    ID3D11RenderTargetView *target;
    IDXGISwapChain_GetBuffer(swap_chain, 0, &IID_ID3D11Texture2D, (void **)&back_buffer);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back_buffer, NULL, &target);
    for (int frame = 0; frame < 120; frame++) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
            DispatchMessageW(&message);
        float color[4] = { 0.1f, 0.4f * frame / 120, 0.8f, 1.0f };
        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(context, target, color);
        hr = IDXGISwapChain_Present(swap_chain, 1, 0);
        if (FAILED(hr)) {
            printf("Present failed: 0x%08lx\n", hr);
            return 1;
        }
    }
    printf("Presented 120 frames\n");
    return 0;
}
