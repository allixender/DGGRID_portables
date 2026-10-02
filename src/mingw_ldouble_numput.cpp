// Workaround for `ostream << long double` on x86 MinGW with zig's libc++.
//
// zig builds libc++ without -D__USE_MINGW_ANSI_STDIO=1 (llvm-mingw adds it for
// i686/x86_64, see its build-libcxx.sh), so num_put<char>::do_put(long double)
// ends in UCRT's vsnprintf, which reads the 80-bit x87 argument of "%Lg" as a
// 64-bit double -> prints garbage like 4.72715e-312. This file installs a
// num_put<char> facet whose long double overload formats with mingw-w64's
// __mingw_snprintf instead, as the global locale (inherited by every stream
// constructed afterwards) and on the standard streams.
//
// Mirrors libc++'s __num_put formatting: same printf conversion selection
// (C++ [facet.num.put.virtuals]), fill/width/adjustfield, locale decimal point.
// Thousands grouping is not applied (DGGRID only uses the classic locale).
// std::to_string(long double) is NOT covered (no facet involved).

#if defined(__MINGW32__) && (defined(__x86_64__) || defined(__i386__))

#include <cstdio>
#include <iostream>
#include <locale>
#include <string>

extern "C" int __cdecl __mingw_snprintf(char*, size_t, const char*, ...);

namespace {

class LongDoubleNumPut : public std::num_put<char> {
 public:
  explicit LongDoubleNumPut(size_t refs = 0) : std::num_put<char>(refs) {}

 protected:
  using std::num_put<char>::do_put;

  iter_type do_put(iter_type out, std::ios_base& io, char_type fill,
                   long double v) const override {
    const std::ios_base::fmtflags fl = io.flags();
    const std::ios_base::fmtflags ff = fl & std::ios_base::floatfield;
    const bool upper = (fl & std::ios_base::uppercase) != 0;

    char fmt[16];
    char* f = fmt;
    *f++ = '%';
    if (fl & std::ios_base::showpos) *f++ = '+';
    if (fl & std::ios_base::showpoint) *f++ = '#';
    const bool hex = ff == (std::ios_base::fixed | std::ios_base::scientific);
    if (!hex) { *f++ = '.'; *f++ = '*'; }
    *f++ = 'L';
    if (ff == std::ios_base::fixed) *f++ = upper ? 'F' : 'f';
    else if (ff == std::ios_base::scientific) *f++ = upper ? 'E' : 'e';
    else if (hex) *f++ = upper ? 'A' : 'a';
    else *f++ = upper ? 'G' : 'g';
    *f = '\0';

    const int prec = static_cast<int>(io.precision());
    std::string s(64, '\0');
    int n = hex ? __mingw_snprintf(&s[0], s.size(), fmt, v)
                : __mingw_snprintf(&s[0], s.size(), fmt, prec, v);
    if (n < 0) n = 0;
    if (static_cast<size_t>(n) >= s.size()) {  // e.g. fixed with huge exponents
      s.assign(static_cast<size_t>(n) + 1, '\0');
      n = hex ? __mingw_snprintf(&s[0], s.size(), fmt, v)
              : __mingw_snprintf(&s[0], s.size(), fmt, prec, v);
    }
    s.resize(static_cast<size_t>(n));

    const char dp = std::use_facet<std::numpunct<char> >(io.getloc()).decimal_point();
    if (dp != '.') {
      for (size_t i = 0; i < s.size(); ++i)
        if (s[i] == '.') { s[i] = dp; break; }
    }

    // padding, as libc++ does for floats: left / right / internal (after a
    // leading sign, else after a leading 0x)
    const std::streamsize w = io.width(0);
    const size_t pad = w > 0 && static_cast<size_t>(w) > s.size()
                           ? static_cast<size_t>(w) - s.size() : 0;
    const std::ios_base::fmtflags adj = fl & std::ios_base::adjustfield;
    size_t split = 0;  // fill goes here
    if (adj == std::ios_base::left) {
      split = s.size();
    } else if (adj == std::ios_base::internal && !s.empty()) {
      if (s[0] == '+' || s[0] == '-')
        split = 1;
      else if (s.size() > 1 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        split = 2;
    }
    for (size_t i = 0; i < split; ++i) *out++ = s[i];
    for (size_t i = 0; i < pad; ++i) *out++ = fill;
    for (size_t i = split; i < s.size(); ++i) *out++ = s[i];
    return out;
  }
};

struct Install {
  Install() {
    const std::locale loc(std::locale(), new LongDoubleNumPut);
    std::locale::global(loc);
    std::cout.imbue(loc);
    std::cerr.imbue(loc);
    std::clog.imbue(loc);
  }
};

const Install install;

}  // namespace

#endif
