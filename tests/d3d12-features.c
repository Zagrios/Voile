/* Prints what a Direct3D 12 game learns about the GPU before it picks its
 * features: the adapter DXGI reports, the ray tracing tier D3D12 reports, and
 * whether DLSS answers through nvngx.dll, found as NVIDIA's NGX loader finds
 * it. Exits 1 when no D3D12 device can be created.
 *
 * x86_64-w64-mingw32-clang -O2 -o d3d12-features.exe d3d12-features.c -ld3d12 -ldxgi -ldxguid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>

/* NGX's parameter interface, in the order MSVC lays out its overloaded
 * virtual methods, as DXMT's nvngx.hpp declares it. Only Get(int) is used. */
typedef struct ngx_parameter ngx_parameter;
typedef struct
{
    void *set[8];
    unsigned int (*get_void)(ngx_parameter *, const char *, void **);
    unsigned int (*get_d3d12)(ngx_parameter *, const char *, void **);
    unsigned int (*get_double)(ngx_parameter *, const char *, double *);
    unsigned int (*get_uint)(ngx_parameter *, const char *, unsigned int *);
    unsigned int (*get_int)(ngx_parameter *, const char *, int *);
} ngx_parameter_vtbl;
struct ngx_parameter { const ngx_parameter_vtbl *vtbl; };

typedef unsigned int (*ngx_init)(unsigned long long, const wchar_t *, ID3D12Device *, const void *, unsigned int);
typedef unsigned int (*ngx_capabilities)(ngx_parameter **);

static void print_dlss(ID3D12Device *device)
{
    WCHAR folder[MAX_PATH] = L"C:\\windows\\system32", path[MAX_PATH], data[MAX_PATH];
    DWORD size = sizeof(folder);
    LSTATUS status;
    HMODULE ngx;
    ngx_init init;
    ngx_capabilities capabilities;
    ngx_parameter *parameters = NULL;
    unsigned int result;
    int available = -1, init_result = -1;

    /* NVIDIA's driver names its folder there; Proton points it at system32. */
    if ((status = RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore",
            L"FullPath", RRF_RT_REG_SZ, NULL, folder, &size)))
        printf("NGXCore FullPath: none (%ld), trying system32\n", status);
    else
        printf("NGXCore FullPath: %ls\n", folder);
    swprintf(path, MAX_PATH, L"%ls\\nvngx.dll", folder);
    if (!(ngx = LoadLibraryW(path)))
    {
        printf("DLSS: nvngx.dll does not load (%lu)\n", GetLastError());
        return;
    }
    init = (ngx_init)GetProcAddress(ngx, "NVSDK_NGX_D3D12_Init");
    capabilities = (ngx_capabilities)GetProcAddress(ngx, "NVSDK_NGX_D3D12_GetCapabilityParameters");
    if (!init || !capabilities)
    {
        printf("DLSS: nvngx.dll lacks the D3D12 entry points\n");
        return;
    }
    GetTempPathW(MAX_PATH, data);
    result = init(0x4F42454CULL, data, device, NULL, 0x14);
    printf("NVSDK_NGX_D3D12_Init: 0x%08x\n", result);
    if (result != 1) return;
    result = capabilities(&parameters);
    printf("NVSDK_NGX_D3D12_GetCapabilityParameters: 0x%08x\n", result);
    if (result != 1 || !parameters) return;
    parameters->vtbl->get_int(parameters, "SuperSampling.Available", &available);
    parameters->vtbl->get_int(parameters, "SuperSampling.FeatureInitResult", &init_result);
    printf("DLSS: SuperSampling.Available = %d, FeatureInitResult = 0x%08x\n", available, init_result);
}

int main(void)
{
    IDXGIFactory4 *factory;
    IDXGIAdapter1 *adapter;
    DXGI_ADAPTER_DESC1 description;
    ID3D12Device *device;
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5 = {0};
    HRESULT hr;

    if (FAILED(hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory)))
    {
        printf("CreateDXGIFactory1 failed: 0x%08lx\n", hr);
        return 1;
    }
    if (FAILED(hr = IDXGIFactory4_EnumAdapters1(factory, 0, &adapter)))
    {
        printf("EnumAdapters1 failed: 0x%08lx\n", hr);
        return 1;
    }
    IDXGIAdapter1_GetDesc1(adapter, &description);
    printf("Adapter: %ls\n", description.Description);
    printf("Vendor 0x%04x, device 0x%04x, subsystem 0x%08x, revision %u\n",
        description.VendorId, description.DeviceId, description.SubSysId, description.Revision);
    if (FAILED(hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_12_0,
            &IID_ID3D12Device, (void **)&device)))
    {
        printf("D3D12CreateDevice failed: 0x%08lx\n", hr);
        return 1;
    }
    hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS5, &options5, sizeof(options5));
    if (FAILED(hr))
        printf("OPTIONS5 failed: 0x%08lx\n", hr);
    else
        printf("Ray tracing tier: %d.%d\n", options5.RaytracingTier / 10, options5.RaytracingTier % 10);
    print_dlss(device);
    return 0;
}
