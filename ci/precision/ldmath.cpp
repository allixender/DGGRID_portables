// long double libm accuracy probe. inputs are exact doubles (identical on every
// LDBL width), widened to long double, results printed as (double) at %.17g and
// %a -> output comparable across platforms, independent of %Lf support.
// compare two platforms or against mpmath with ldmath_compare.py.
// ldmath [n]: n extra pseudo-random inputs per function (default 300).
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cfloat>
#include <sstream>

static const double xs[] = {
  0.0, 1e-9, 1e-5, 0.001, 0.1, 0.25, 0.5, 0.6523581397843682,
  0.7853981633974483, 1.0, 1.0172219678978514, 1.1071487177940904,
  1.2, 1.3, 1.4, 1.5, 1.5707963267948966, 1.6, 2.0, 2.5,
  3.0, 3.141592653589793, 3.2, 4.0, 5.0, 6.0, 6.283185307179586,
  10.0, 100.0, -0.3, -1.1, -2.9, 0.38035386143837, 0.91843818702186776,
  0.20682208259748, 0.0174532925199433, 0.4636476090008061, 2.0344439357957027,
};
static const double us[] = {   // asin/acos domain
  -1.0, -0.999999, -0.99, -0.9, -0.7, -0.5, -0.3, -0.1, -1e-6, 0.0,
  1e-6, 0.01, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7071067811865476,
  0.75, 0.8, 0.85, 0.9, 0.95, 0.99, 0.999, 0.999999, 0.99999999,
  0.9999999999, 1.0, 0.61803398874989485, 0.79465447229176612, 0.18759247408507989,
  0.32491969623290634, 0.96286144003409478, 0.5257311121191336, 0.8506508083520399,
};
static const double ps[][2] = {  // atan2(y,x) / pow(x,y)
  {1,1}, {1,-1}, {-1,-1}, {-1,1}, {0.5,2}, {2,0.5}, {1e-8,1}, {1,1e-8},
  {0.3,0.7}, {0.7,0.3}, {-0.2,-0.9}, {3,4}, {12345.678,0.001},
  {0.6523581397843682,0.75}, {0.1,-0.99}, {0.99,-0.1}, {1e-3,-1},
  {-1e-3,-1}, {5,3}, {0.00001,0.00002}, {0.9,0.4358898943540674},
  {0.5257311121191336,0.8506508083520399}, {1.5,2.5}, {7,1.0/3},
  {2.718281828459045,1.5}, {10,-2.5},
};

#define N(a) (sizeof(a) / sizeof(a[0]))
static void p(const char* fn, long double a, long double b, long double r) {
  std::printf("%s %.17g %.17g %.17g %a\n", fn, (double)a, (double)b, (double)r, (double)r);
}

static unsigned long long rng = 88172645463325252ULL;
static double urand(double lo, double hi) {  // xorshift64, same sequence everywhere
  rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
  return lo + (hi - lo) * (double)(rng >> 11) * 0x1p-53;
}

int main(int argc, char** argv) {
  int nrand = argc > 1 ? std::atoi(argv[1]) : 300;
  std::printf("# LDBL_MANT_DIG %d\n", LDBL_MANT_DIG);
  for (size_t i = 0; i < N(xs); i++) {
    long double x = xs[i];
    p("sinl", x, 0, sinl(x));
    p("cosl", x, 0, cosl(x));
    p("tanl", x, 0, tanl(x));
    p("atanl", x, 0, atanl(x));
    p("sqrtl", x < 0 ? -x : x, 0, sqrtl(x < 0 ? -x : x));
    p("std::sin", x, 0, std::sin(x));
    p("std::cos", x, 0, std::cos(x));
  }
  for (size_t i = 0; i < N(us); i++) {
    long double u = us[i];
    p("asinl", u, 0, asinl(u));
    p("acosl", u, 0, acosl(u));
  }
  for (size_t i = 0; i < N(ps); i++) {
    long double y = ps[i][0], x = ps[i][1];
    p("atan2l", y, x, atan2l(y, x));
    p("powl", y < 0 ? -y : y, x, powl(y < 0 ? -y : y, x));
  }
  for (int i = 0; i < nrand; i++) {
    long double x = urand(-7, 7), u = urand(-1, 1), y = urand(-2, 2), z = urand(-2, 2);
    long double c = 1 - urand(0, 1e-6);  // acos/asin near 1: snyderInv territory
    p("sinl", x, 0, sinl(x));
    p("cosl", x, 0, cosl(x));
    p("tanl", x, 0, tanl(x));
    p("atanl", x, 0, atanl(x));
    p("sqrtl", x < 0 ? -x : x, 0, sqrtl(x < 0 ? -x : x));
    p("asinl", u, 0, asinl(u));
    p("acosl", u, 0, acosl(u));
    p("acosl", c, 0, acosl(c));
    p("asinl", c, 0, asinl(c));
    p("atan2l", y, z, atan2l(y, z));
    p("powl", y < 0 ? -y : y, z, powl(y < 0 ? -y : y, z));
  }
  // parsing paths DGGRID uses for parameters
  const char* s = "-178.4423567890123456";
  long double v1 = strtold(s, nullptr), v2 = 0;
  std::sscanf(s, "%Lf", &v2);
  long double v3 = 0;
  std::istringstream(s) >> v3;
  p("strtold", 0, 0, v1);
  p("sscanf%Lf", 0, 0, v2);
  p("istream>>", 0, 0, v3);
  p("M_PI", 0, 0, M_PI);
  return 0;
}
