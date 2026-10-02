// wasm32-wasi only: zig's libc++abi for wasm is built without exception support, so
// __cxa_allocate_exception / __cxa_throw are missing at link time. dglib throws in a
// few places (and libc++ on bad_alloc); here any throw aborts, i.e. traps the instance.
#include <cstdio>
#include <cstdlib>

extern "C" void* __cxa_allocate_exception(unsigned long)
{
   std::fputs("dglib: C++ exception thrown, no exception support on wasm -> abort\n", stderr);
   std::abort();
}

extern "C" void __cxa_throw(void*, void*, void (*)(void*))
{
   std::abort();
}
