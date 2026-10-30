#!/usr/bin/env python3
# ============================================================================
# tools/m1log_server.py —— M-1 取证阶段的日志接收端（Windows / macOS / Linux 通用）
#
# 为什么需要它：非越狱机器上，Windows 侧抓 iPhone 的 NSLog 很不稳定，
# 而 App 沙盒里的文件又拿不出来。所以观测版 dylib 会把日志批量推到同一局域网
# 的这台电脑上（裸 TCP，不受 ATS 限制）。
#
# 用法（Windows，在 cmd 里）：
#     python tools\m1log_server.py
#     python tools\m1log_server.py --port 8765 --out D:\DeepSeek\hush\_work\m1.log
#
# 然后在手机上设置（LiveContainer / 宿主 App 的 defaults）：
#     rea_m1_upload = "<这台电脑的局域网 IP>:8765"
#     rea_m1_off    = NO
#
# 手机端不需要任何确认：连上就发，发完就断开，每 2 秒一次。
# 断了也不影响 App 运行（dylib 侧只计数，不阻塞主线程）。
# ============================================================================

import threading
import argparse
import datetime
import os
import socket
import socketserver
import sys

RECV_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DEFAULT = os.path.join(os.path.dirname(RECV_DIR), "_work", "m1.log")


def ts():
    return datetime.datetime.now().strftime("%H:%M:%S")


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(10.0)
        chunks = []
        try:
            while True:
                data = sock.recv(65536)
                if not data:
                    break
                chunks.append(data)
        except (socket.timeout, ConnectionResetError, OSError):
            pass
        if not chunks:
            return
        blob = b"".join(chunks).decode("utf-8", "replace")
        peer = "%s" % (self.client_address[0],)
        # 边收边打，方便你盯着屏幕看 App 到底走到哪一步
        for line in blob.splitlines():
            if line.strip():
                print("%s  %s" % (ts(), line))
        with open(self.server.out_path, "a", encoding="utf-8") as f:
            f.write("# ---- batch from %s at %s ----\n" % (peer, ts()))
            f.write(blob)
            if not blob.endswith("\n"):
                f.write("\n")
            f.flush()
        print("%s  收到 %d 字节（来自 %s）" % (ts(), len(blob), peer))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def local_ips():
    ips = []
    try:
        h = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        h.settimeout(0.5)
        h.connect(("8.8.8.8", 80))
        ips.append(h.getsockname()[0])
        h.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips or ["127.0.0.1"]


def discovery_loop(log_port, discover_port, stop):
    """UDP 广播应答：手机端零配置自动找到这台电脑。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("", discover_port))
    except OSError as e:
        print("%s  [警告] 无法监听 UDP %d：%s（手机端需手动设 rea_m1_upload）"
              % (ts(), discover_port, e))
        return
    while not stop.is_set():
        try:
            s.settimeout(1.0)
            data, peer = s.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            break
        if data.strip().startswith(b"M1-DISCOVER"):
            reply = ("M1-HERE %d" % log_port).encode()
            try:
                s.sendto(reply, peer)
                print("%s  发现请求来自 %s → 已告知端口 %d" % (ts(), peer[0], log_port))
            except OSError:
                pass
    s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--discover-port", type=int, default=8766)
    ap.add_argument("--no-discover", action="store_true")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    srv = Server((args.host, args.port), Handler)
    srv.out_path = os.path.abspath(args.out)

    stop = threading.Event()
    if not args.no_discover:
        t = threading.Thread(target=discovery_loop,
                             args=(args.port, args.discover_port, stop), daemon=True)
        t.start()

    print("=" * 78)
    print("M-1 日志接收端已启动")
    print("  监听 TCP : %s:%d" % (args.host, args.port))
    if not args.no_discover:
        print("  监听 UDP : %s:%d（自动发现，手机端零配置）" % (args.host, args.discover_port))
    print("  落盘     : %s" % srv.out_path)
    print("")
    print("  手机端不需要设置任何东西 —— 观测版 dylib 会自动广播找到这里。")
    print("  如果日志里看到 'UPLOAD discover fail'，就在手机上手动设 rea_m1_upload 为下面任意一条：")
    for ip in local_ips():
        print("    %s:%d" % (ip, args.port))
    print("")
    print("  Windows 防火墙第一次会弹窗 —— 必须点「允许访问」（含专用网络）。")
    print("=" * 78)
    print("Ctrl+C 结束。日志会一直追加到上面那个文件里。")
    print("")

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[停止] 日志已保存在 %s" % srv.out_path)
    finally:
        stop.set()
        srv.server_close()


if __name__ == "__main__":
    sys.exit(main())
