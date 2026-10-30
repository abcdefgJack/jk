// {{NAME}} - {{DATE}}  (USACO: reads {{NAME}}.in / writes {{NAME}}.out on the grader, stdin/stdout locally)
#include <bits/stdc++.h>
using namespace std;

#ifdef LOCAL
// declared before either body, so a pair can hold a container and a container can hold pairs
template <class A, class B> ostream& operator<<(ostream& os, const pair<A, B>& p);
template <class C, class = decltype(begin(declval<const C&>())), class = enable_if_t<!is_convertible_v<const C&, string_view>>>
ostream& operator<<(ostream& os, const C& c);
template <class A, class B> ostream& operator<<(ostream& os, const pair<A, B>& p) { return os << '(' << p.first << ", " << p.second << ')'; }
template <class C, class, class> ostream& operator<<(ostream& os, const C& c) {
    os << '{';
    bool first = true;
    for (const auto& x : c) { if (!first) os << ", "; os << x; first = false; }
    return os << '}';
}
void dbg_out() { cerr << endl; }
template <class H, class... T> void dbg_out(const H& h, const T&... t) { cerr << ' ' << h; dbg_out(t...); }
#define dbg(...) cerr << "[" << #__VA_ARGS__ << "]:", dbg_out(__VA_ARGS__)
#else
#define dbg(...)
#endif

using ll = long long;

void setIO(const string& name) {
    ios::sync_with_stdio(false);
    cin.tie(nullptr);
#ifndef LOCAL
    if (!name.empty()) {
        freopen((name + ".in").c_str(), "r", stdin);
        freopen((name + ".out").c_str(), "w", stdout);
    }
#else
    (void)name;
#endif
}

int main() {
    setIO("{{NAME}}");

    return 0;
}
