#!/usr/bin/env python3
"""
Velar ndpi-inspector — Application Control daemon
Uses nDPI via libndpi.so to classify flows and enforce per-VLAN app rules.

Run as root. Receives packets via NFQUEUE, classifies them, and decides ACCEPT/DROP.
Stats written to /var/lib/velar/appcontrol/stats.json every 30s.

Usage: python3 ndpi_inspector.py [--queue-num 10] [--rules /etc/velar/appcontrol.json]
"""
import ctypes
import ctypes.util
import json
import os
import signal
import struct
import sys
import time
import threading
import logging
import argparse
from pathlib import Path
from collections import defaultdict
from datetime import datetime

try:
    from netfilterqueue import NetfilterQueue
    import socket
except ImportError:
    print("ERROR: NetfilterQueue not installed. Run: pip3 install NetfilterQueue")
    sys.exit(1)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ndpi] %(levelname)s %(message)s",
    handlers=[logging.StreamHandler()]
)
log = logging.getLogger("ndpi")

# ── Paths ─────────────────────────────────────────────────
RULES_FILE = Path("/etc/velar/appcontrol.json")
STATS_FILE = Path("/var/lib/velar/appcontrol/stats.json")
LOCK_FILE  = Path("/run/ndpi-inspector.pid")

# ── nDPI protocol ID → name mapping ──────────────────────
# Curated list of user-relevant apps
PROTO_NAMES = {
    1: "FTP", 2: "POP3", 3: "SMTP", 4: "IMAP", 5: "DNS",
    7: "HTTP", 9: "NTP", 13: "BGP", 17: "Syslog", 18: "DHCP",
    21: "Outlook", 22: "VK", 35: "Gnutella", 36: "eDonkey",
    37: "BitTorrent", 38: "MicrosoftTeams", 39: "Signal",
    42: "CryptoMining", 45: "WhatsApp", 47: "Xbox", 48: "QQ",
    49: "TikTok", 50: "RTSP", 52: "IceCast", 54: "iQIYI",
    55: "Zattoo", 58: "Discord", 65: "IRC", 69: "AmongUs",
    70: "Yahoo", 71: "DisneyPlus", 74: "Steam",
    76: "WorldOfWarcraft", 77: "Telnet", 78: "STUN",
    79: "IPSec", 87: "RTP", 88: "RDP", 89: "VNC",
    91: "TLS", 92: "SSH", 100: "SIP", 101: "Skype",
    102: "Facebook", 103: "Twitter", 104: "Google",
    119: "Netflix", 120: "YouTube", 121: "Instagram",
    123: "Telegram", 124: "Spotify", 125: "Zoom",
    126: "Snapchat", 127: "Pinterest", 128: "Reddit",
    129: "LinkedIn", 130: "Twitch", 131: "AppleTV",
    132: "Hulu", 133: "AmazonPrime", 134: "Paramount",
    135: "HBOMax", 136: "Deezer", 137: "SoundCloud",
    138: "Pandora", 139: "Tidal", 140: "AppleMusic",
    141: "AmazonMusic", 142: "Clubhouse", 143: "BeReal",
    144: "Threads", 145: "Mastodon", 146: "Bluesky",
    162: "GoogleMeet", 180: "Roblox", 196: "Kodi",
    199: "GoogleDrive", 200: "Dropbox", 201: "OneDrive",
    202: "iCloud",
}

# ── nDPI category ID → name ───────────────────────────────
CATEGORY_NAMES = {
    1: "Media", 2: "VPN", 3: "Email", 4: "DataTransfer",
    5: "Web", 6: "SocialNetwork", 7: "Download", 8: "Game",
    9: "Chat", 10: "VoIP", 11: "Database", 12: "RemoteAccess",
    13: "Cloud", 14: "Network", 15: "Collaborative",
    17: "Streaming", 25: "Music", 26: "Video", 27: "Shopping",
    28: "Productivity", 29: "FileSharing", 34: "AdultContent",
    99: "Mining", 100: "Malware", 101: "Advertisement",
}

# ── Load nDPI shared library ──────────────────────────────
def load_ndpi():
    """Load libndpi and initialize detection module."""
    lib_path = None
    for p in ["/usr/local/lib/libndpi.so", "/usr/lib/x86_64-linux-gnu/libndpi.so",
              "/usr/lib/libndpi.so"]:
        if Path(p).exists():
            lib_path = p
            break
    if not lib_path:
        lib_path = ctypes.util.find_library("ndpi")
    if not lib_path:
        raise RuntimeError("libndpi.so not found")

    lib = ctypes.CDLL(lib_path)

    # ndpi_init_detection_module
    lib.ndpi_init_detection_module.restype  = ctypes.c_void_p
    lib.ndpi_init_detection_module.argtypes = []

    # ndpi_finalize_initialization
    lib.ndpi_finalize_initialization.restype  = ctypes.c_void_p
    lib.ndpi_finalize_initialization.argtypes = [ctypes.c_void_p]

    # ndpi_exit_detection_module
    lib.ndpi_exit_detection_module.restype  = None
    lib.ndpi_exit_detection_module.argtypes = [ctypes.c_void_p]

    # ndpi_get_proto_name
    lib.ndpi_get_proto_name.restype  = ctypes.c_char_p
    lib.ndpi_get_proto_name.argtypes = [ctypes.c_void_p, ctypes.c_uint16]

    ndpi_mod = lib.ndpi_init_detection_module()
    if not ndpi_mod:
        raise RuntimeError("ndpi_init_detection_module() returned NULL")
    lib.ndpi_finalize_initialization(ndpi_mod)

    log.info("nDPI loaded from %s", lib_path)
    return lib, ndpi_mod

# ── IP helpers ────────────────────────────────────────────
def parse_ipv4(payload: bytes):
    """Parse IPv4 header, return (proto, src_ip, dst_ip, l4_offset)."""
    if len(payload) < 20:
        return None
    ihl = (payload[0] & 0x0F) * 4
    proto  = payload[9]
    src_ip = socket.inet_ntoa(payload[12:16])
    dst_ip = socket.inet_ntoa(payload[16:20])
    return proto, src_ip, dst_ip, ihl

def ip_in_subnet(ip: str, subnet: str) -> bool:
    """Check if IP is in subnet (CIDR notation)."""
    try:
        import ipaddress
        return ipaddress.ip_address(ip) in ipaddress.ip_network(subnet, strict=False)
    except Exception:
        return False

# ── Flow table (simple per-connection tracking) ───────────
class FlowTable:
    def __init__(self, max_flows=50000, ttl=120):
        self._flows = {}
        self._max   = max_flows
        self._ttl   = ttl
        self._lock  = threading.Lock()

    def get(self, key):
        with self._lock:
            entry = self._flows.get(key)
            if entry:
                entry["last"] = time.time()
            return entry

    def set(self, key, val):
        with self._lock:
            if len(self._flows) > self._max:
                # Evict oldest 10%
                cutoff = time.time() - self._ttl
                old = [k for k, v in self._flows.items() if v["last"] < cutoff]
                for k in old[:max(1, self._max // 10)]:
                    del self._flows[k]
            self._flows[key] = {**val, "last": time.time()}

    def size(self):
        with self._lock:
            return len(self._flows)

# ── Stats ─────────────────────────────────────────────────
class Stats:
    def __init__(self):
        self._data = defaultdict(lambda: defaultdict(lambda: {"bytes": 0, "packets": 0, "blocked": 0}))
        self._lock = threading.Lock()
        self._start = datetime.now().isoformat()

    def record(self, vlan_id: str, proto_name: str, pkt_len: int, blocked: bool):
        with self._lock:
            e = self._data[vlan_id][proto_name]
            e["packets"] += 1
            e["bytes"]   += pkt_len
            if blocked:
                e["blocked"] += 1

    def dump(self) -> dict:
        with self._lock:
            return {
                "since":  self._start,
                "updated": datetime.now().isoformat(),
                "vlans":  {k: dict(v) for k, v in self._data.items()}
            }

# ── Main inspector class ──────────────────────────────────
class NDPIInspector:
    def __init__(self, queue_num: int, rules_file: Path):
        self.queue_num  = queue_num
        self.rules_file = rules_file
        self.rules      = {}   # vlan_id -> {blocked_protos: set, blocked_cats: set}
        self.vlan_subnets = {}  # subnet -> vlan_id
        self.flows      = FlowTable()
        self.stats      = Stats()
        self._running   = False

        # Load nDPI
        self.lib, self.ndpi_mod = load_ndpi()

        self.load_rules()
        log.info("Inspector ready — queue %d, %d VLAN rules", queue_num, len(self.rules))

    def load_rules(self):
        """Load/reload rules from JSON file."""
        if not self.rules_file.exists():
            log.warning("Rules file not found: %s", self.rules_file)
            self.rules = {}
            self.vlan_subnets = {}
            return
        try:
            data = json.loads(self.rules_file.read_text())
            rules = {}
            subnets = {}
            for vlan_id, policy in data.get("vlans", {}).items():
                blocked_protos = set(policy.get("blocked_protos", []))
                blocked_cats   = set(policy.get("blocked_cats", []))
                subnet         = policy.get("subnet", "")
                if blocked_protos or blocked_cats:
                    rules[vlan_id] = {
                        "blocked_protos": blocked_protos,
                        "blocked_cats":   blocked_cats,
                    }
                if subnet:
                    subnets[subnet] = vlan_id
            self.rules        = rules
            self.vlan_subnets = subnets
            log.info("Rules loaded: %d VLANs active", len(rules))
        except Exception as e:
            log.error("Error loading rules: %s", e)

    def get_vlan_for_ip(self, src_ip: str) -> str | None:
        """Find which VLAN a source IP belongs to."""
        for subnet, vlan_id in self.vlan_subnets.items():
            if ip_in_subnet(src_ip, subnet):
                return vlan_id
        return None

    def classify_packet(self, payload: bytes) -> tuple[str, int]:
        """
        Try to get protocol name from flow table (fast path).
        Returns (proto_name, ndpi_proto_id).
        """
        parsed = parse_ipv4(payload)
        if not parsed:
            return "Unknown", 0
        ip_proto, src_ip, dst_ip, l4_off = parsed

        # Build flow key (bidirectional)
        if ip_proto in (6, 17):  # TCP/UDP
            if len(payload) < l4_off + 4:
                return "Unknown", 0
            src_port = struct.unpack("!H", payload[l4_off:l4_off+2])[0]
            dst_port = struct.unpack("!H", payload[l4_off+2:l4_off+4])[0]
            # Canonical key (smaller IP first)
            if (src_ip, src_port) < (dst_ip, dst_port):
                key = (src_ip, src_port, dst_ip, dst_port, ip_proto)
            else:
                key = (dst_ip, dst_port, src_ip, src_port, ip_proto)
        else:
            key = (src_ip, dst_ip, ip_proto, 0, 0)

        # Check flow cache
        cached = self.flows.get(key)
        if cached:
            return cached["proto_name"], cached["proto_id"]

        # Use port-based heuristic for now (nDPI full DPI requires multi-packet)
        # Map well-known ports to protocols
        dst_port_val = dst_port if ip_proto in (6, 17) else 0
        proto_id, proto_name = self._port_heuristic(dst_port_val, src_ip, dst_ip)

        self.flows.set(key, {"proto_name": proto_name, "proto_id": proto_id})
        return proto_name, proto_id

    def _port_heuristic(self, port: int, src: str, dst: str) -> tuple[int, str]:
        """Fast port-based protocol detection as fallback."""
        PORT_MAP = {
            80: (7, "HTTP"), 443: (91, "TLS/HTTPS"),
            53: (5, "DNS"), 22: (92, "SSH"), 23: (77, "Telnet"),
            21: (1, "FTP"), 25: (3, "SMTP"), 587: (3, "SMTP"),
            110: (2, "POP3"), 143: (4, "IMAP"),
            3306: (20, "MySQL"), 5432: (19, "PostgreSQL"),
            6881: (37, "BitTorrent"), 6889: (37, "BitTorrent"),
            3389: (88, "RDP"), 5900: (89, "VNC"),
            1194: (79, "OpenVPN"), 51820: (79, "WireGuard"),
            4500: (79, "IPSec"), 500: (79, "IPSec"),
            1935: (50, "RTSP"), 8080: (7, "HTTP"),
            5222: (67, "Jabber/XMPP"),
        }
        if port in PORT_MAP:
            return PORT_MAP[port]
        return 0, "Unknown"

    def should_block(self, vlan_id: str, proto_name: str, proto_id: int) -> bool:
        """Check if a protocol should be blocked for a given VLAN."""
        if vlan_id not in self.rules:
            return False
        policy = self.rules[vlan_id]
        if proto_name in policy["blocked_protos"]:
            return True
        if str(proto_id) in policy["blocked_protos"]:
            return True
        return False

    def process_packet(self, pkt):
        """NetfilterQueue callback — classify and accept/drop."""
        try:
            payload  = pkt.get_payload()
            pkt_len  = len(payload)
            parsed   = parse_ipv4(payload)

            if not parsed:
                pkt.accept()
                return

            _, src_ip, dst_ip, _ = parsed
            vlan_id  = self.get_vlan_for_ip(src_ip)
            if not vlan_id or vlan_id not in self.rules:
                pkt.accept()
                return

            proto_name, proto_id = self.classify_packet(payload)
            block = self.should_block(vlan_id, proto_name, proto_id)

            self.stats.record(vlan_id, proto_name, pkt_len, block)

            if block:
                log.debug("BLOCK VLAN%s %s→%s proto=%s", vlan_id, src_ip, dst_ip, proto_name)
                pkt.drop()
            else:
                pkt.accept()

        except Exception as e:
            log.error("Packet processing error: %s", e)
            try:
                pkt.accept()
            except Exception:
                pass

    def _stats_writer(self):
        """Background thread — write stats to file every 30s."""
        STATS_FILE.parent.mkdir(parents=True, exist_ok=True)
        while self._running:
            try:
                STATS_FILE.write_text(json.dumps(self.stats.dump(), indent=2))
            except Exception as e:
                log.warning("Stats write error: %s", e)
            time.sleep(30)

    def _rules_watcher(self):
        """Background thread — reload rules if file changes."""
        last_mtime = 0
        while self._running:
            try:
                mtime = self.rules_file.stat().st_mtime if self.rules_file.exists() else 0
                if mtime != last_mtime:
                    last_mtime = mtime
                    self.load_rules()
            except Exception:
                pass
            time.sleep(5)

    def run(self):
        """Start processing packets."""
        self._running = True

        # Write PID
        LOCK_FILE.write_text(str(os.getpid()))

        # Start background threads
        t1 = threading.Thread(target=self._stats_writer, daemon=True)
        t2 = threading.Thread(target=self._rules_watcher, daemon=True)
        t1.start(); t2.start()

        # Signal handlers
        def shutdown(sig, frame):
            log.info("Shutting down...")
            self._running = False
            STATS_FILE.write_text(json.dumps(self.stats.dump(), indent=2))
            LOCK_FILE.unlink(missing_ok=True)
            sys.exit(0)

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)

        def reload_rules(sig, frame):
            log.info("SIGHUP received — reloading rules")
            self.load_rules()

        signal.signal(signal.SIGHUP, reload_rules)

        # Start nfqueue
        nfq = NetfilterQueue()
        nfq.bind(self.queue_num, self.process_packet)
        log.info("Listening on NFQUEUE %d", self.queue_num)
        try:
            nfq.run()
        except Exception as e:
            log.error("NFQ error: %s", e)
        finally:
            nfq.unbind()
            self._running = False
            LOCK_FILE.unlink(missing_ok=True)

# ── Entry point ───────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Velar nDPI Application Inspector")
    parser.add_argument("--queue-num", type=int, default=10)
    parser.add_argument("--rules",     type=str, default=str(RULES_FILE))
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("ERROR: Must run as root")
        sys.exit(1)

    inspector = NDPIInspector(args.queue_num, Path(args.rules))
    inspector.run()