// {{NAME}} - {{DATE}}
#include <bits/stdc++.h>
using namespace std;

#ifdef LOCAL
template <class A, class B> ostream& operator<<(ostream& os, const pair<A, B>& p) { return os << '(' << p.first << ", " << p.second << ')'; }
template <class C, class = decltype(begin(declval<const C&>())), class = enable_if_t<!is_same_v<C, string>>>
ostream& operator<<(ostream& os, const C& c) {
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
using pii = pair<int, int>;
using pll = pair<ll, ll>;
#define all(x) (x).begin(), (x).end()
#define sz(x) (int)(x).size()

void solve() {

}

int main() {
    ios::sync_with_stdio(false);
    cin.tie(nullptr);
    int t = 1;
    // cin >> t;
    while (t--) solve();
    return 0;
}
