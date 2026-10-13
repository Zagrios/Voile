/* A 32-bit program that turns on forced exec permission, as Wine's loader does
 * when it loads a module without NX_COMPAT, then makes a few syscalls and exits
 * 0. Wine used to set the 64-bit syscall dispatcher pointer page at 7ffe4000
 * PROT_NONE at that moment, and the next syscall died with "stack overflow" on
 * the WoW64 64-bit stack.
 *
 * i686-w64-mingw32-clang -O2 -o wow64-force-exec.exe wow64-force-exec.c
 */
#include <windows.h>
#include <stdio.h>

#define PROCESS_EXECUTE_FLAGS 34
#define EXECUTE_OPTION_ENABLE 0x2
#define MEMORY_BASIC_INFORMATION_CLASS 0

typedef LONG (WINAPI *query_process)(HANDLE, ULONG, void *, ULONG, ULONG *);
typedef LONG (WINAPI *set_process)(HANDLE, ULONG, void *, ULONG);
typedef LONG (WINAPI *query_memory)(HANDLE, const void *, ULONG, void *, SIZE_T, SIZE_T *);

static query_memory query_virtual_memory;

static DWORD WINAPI worker(void *event)
{
    Sleep(10);
    return SetEvent(event) ? 0 : 1;
}

static int check_region(const char *name, const void *address, DWORD state, DWORD protect)
{
    MEMORY_BASIC_INFORMATION info;
    LONG status = query_virtual_memory(GetCurrentProcess(), address, MEMORY_BASIC_INFORMATION_CLASS,
        &info, sizeof(info), NULL);
    if (status) {
        printf("NtQueryVirtualMemory(%p) failed: 0x%08lx\n", address, status);
        return 0;
    }
    printf("%s %p: base %p size 0x%lx state 0x%lx protect 0x%lx\n", name, address, info.BaseAddress,
        (unsigned long)info.RegionSize, info.State, info.Protect);
    if (state && (info.State != state || info.Protect != protect)) {
        printf("%s: expected state 0x%lx protect 0x%lx\n", name, state, protect);
        return 0;
    }
    return 1;
}

int main(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    query_process query_information_process = (query_process)GetProcAddress(ntdll, "NtQueryInformationProcess");
    set_process set_information_process = (set_process)GetProcAddress(ntdll, "NtSetInformationProcess");
    query_virtual_memory = (query_memory)GetProcAddress(ntdll, "NtQueryVirtualMemory");
    ULONG flags = EXECUTE_OPTION_ENABLE;
    LONG status;

    setvbuf(stdout, NULL, _IONBF, 0);
    status = set_information_process(GetCurrentProcess(), PROCESS_EXECUTE_FLAGS, &flags, sizeof(flags));
    printf("NtSetInformationProcess(ProcessExecuteFlags, ENABLE): 0x%08lx\n", status);
    if (status) return 1;

    /* Each call below goes through the 64-bit syscall stubs. */
    flags = 0;
    status = query_information_process(GetCurrentProcess(), PROCESS_EXECUTE_FLAGS, &flags, sizeof(flags), NULL);
    printf("ProcessExecuteFlags: 0x%08lx 0x%lx\n", status, flags);
    if (status || !(flags & EXECUTE_OPTION_ENABLE)) return 1;

    char *page = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    DWORD old;
    if (!page) return 1;
    page[0] = 1;
    if (!VirtualProtect(page, 0x1000, PAGE_READONLY, &old) || old != PAGE_READWRITE) return 1;
    if (!VirtualProtect(page, 0x1000, PAGE_EXECUTE_READ, &old) || old != PAGE_READONLY) return 1;
    if (page[0] != 1 || !VirtualFree(page, 0, MEM_RELEASE)) return 1;
    printf("VirtualAlloc, VirtualProtect, VirtualFree: ok\n");

    if (!check_region("KUSER_SHARED_DATA", (void *)0x7ffe0000, MEM_COMMIT, PAGE_READONLY)) return 1;
    check_region("dispatcher page", (void *)0x7ffe4000, 0, 0);
    printf("NtMajorVersion %lu, NtMinorVersion %lu\n", *(volatile ULONG *)0x7ffe026c,
        *(volatile ULONG *)0x7ffe0270);

    HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
    HANDLE thread = CreateThread(NULL, 0, worker, event, 0, NULL);
    DWORD code = 1;
    if (!event || !thread) return 1;
    if (WaitForSingleObject(event, 5000) || WaitForSingleObject(thread, 5000)) return 1;
    GetExitCodeThread(thread, &code);
    CloseHandle(thread);
    CloseHandle(event);
    if (code) return 1;
    Sleep(50);
    printf("thread, event, Sleep: ok\n");
    return 0;
}
