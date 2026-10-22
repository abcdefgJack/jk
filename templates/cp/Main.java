// {{NAME}} - {{DATE}}
import java.io.*;
import java.util.*;

public class Main {
    static final FastReader in = new FastReader(System.in);
    static final PrintWriter out = new PrintWriter(new BufferedWriter(new OutputStreamWriter(System.out)));

    static void solve() throws IOException {

    }

    public static void main(String[] args) throws IOException {
        int t = 1;
        // t = in.nextInt();
        while (t-- > 0) solve();
        out.flush();
    }

    static final class FastReader {
        private final DataInputStream din;
        private final byte[] buf = new byte[1 << 16];
        private int len = 0, ptr = 0;

        FastReader(InputStream is) { din = new DataInputStream(is); }

        private int read() throws IOException {
            if (ptr == len) { len = din.read(buf, 0, buf.length); ptr = 0; if (len <= 0) return -1; }
            return buf[ptr++];
        }

        String next() throws IOException {
            int c = read();
            while (c != -1 && c <= ' ') c = read();
            StringBuilder sb = new StringBuilder();
            while (c > ' ') { sb.append((char) c); c = read(); }
            return sb.toString();
        }

        int nextInt() throws IOException { return (int) nextLong(); }

        long nextLong() throws IOException {
            int c = read();
            while (c <= ' ') c = read();
            boolean neg = c == '-';
            if (neg) c = read();
            long r = 0;
            while (c >= '0' && c <= '9') { r = r * 10 + (c - '0'); c = read(); }
            return neg ? -r : r;
        }

        double nextDouble() throws IOException { return Double.parseDouble(next()); }
    }
}
