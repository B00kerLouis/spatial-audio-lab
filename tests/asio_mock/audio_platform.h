#pragma once
#include <cwctype>
#include <string>
namespace dolby {
inline std::wstring Lowercase(std::wstring value) {
    for (auto& c : value) c = static_cast<wchar_t>(std::towlower(c));
    return value;
}
}
