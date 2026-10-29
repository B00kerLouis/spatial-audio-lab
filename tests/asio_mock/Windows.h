#pragma once
// Test-only Windows API model. Never included in production builds.
#include <cstddef>
#include <cstdint>
#include <string>

using DWORD = std::uint32_t;
using HRESULT = std::int32_t;
using HKEY = void*;
using HANDLE = void*;
using HWND = void*;
struct CLSID { std::wstring text; };
constexpr bool FALSE = false;
constexpr DWORD WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258;
constexpr long ERROR_SUCCESS = 0, ERROR_FILE_NOT_FOUND = 2, ERROR_NO_MORE_ITEMS = 259;
constexpr DWORD KEY_READ = 1, RRF_RT_REG_SZ = 2, CLSCTX_INPROC_SERVER = 1;
inline HKEY HKEY_LOCAL_MACHINE = reinterpret_cast<HKEY>(1);
inline bool FAILED(HRESULT value) { return value < 0; }

long RegCloseKey(HKEY);
long RegGetValueW(HKEY, const wchar_t*, const wchar_t*, DWORD, DWORD*, void*, DWORD*);
long RegOpenKeyExW(HKEY, const wchar_t*, DWORD, DWORD, HKEY*);
long RegQueryInfoKeyW(HKEY, wchar_t*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, void*);
long RegEnumKeyExW(HKEY, DWORD, wchar_t*, DWORD*, DWORD*, wchar_t*, DWORD*, void*);
HRESULT CLSIDFromString(const wchar_t*, CLSID*);
HRESULT CoCreateInstance(const CLSID&, void*, DWORD, const CLSID&, void**);
HWND GetDesktopWindow();
HANDLE CreateEventW(void*, bool, bool, const wchar_t*);
bool CloseHandle(HANDLE);
bool SetEvent(HANDLE);
DWORD WaitForSingleObject(HANDLE, DWORD);
void Sleep(DWORD);
std::uint64_t GetTickCount64();
DWORD GetPrivateProfileStringW(const wchar_t*, const wchar_t*, const wchar_t*, wchar_t*, DWORD, const char*);
