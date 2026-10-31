// Drives the egress relay (linux/egress_relay_core.cc, NETIF-002 to
// NETIF-007) as a site's webview does: a SOCKS5 client presenting the
// credential lib/services/egress_route.dart writes. check.sh runs one
// scenario per process, against the source it names, and reads the exit
// status: 0 when the relay did what the scenario requires.
#include EGRESS_SOURCE

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr char kSecret[] = "0123456789abcdef0123456789abcdef";

int Fail(const std::string& why) {
  std::printf("FAIL %s\n", why.c_str());
  return 1;
}

int Listen(int* port) {
  const int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a));
  listen(fd, 8);
  socklen_t n = sizeof(a);
  getsockname(fd, reinterpret_cast<sockaddr*>(&a), &n);
  *port = ntohs(a.sin_port);
  return fd;
}

int Connect(const std::string& host, int port) {
  const int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(static_cast<uint16_t>(port));
  inet_pton(AF_INET, host.c_str(), &a.sin_addr);
  if (connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

void Echo(int fd) {
  char b[4096];
  ssize_t n;
  while ((n = read(fd, b, sizeof(b))) > 0) {
    if (write(fd, b, static_cast<size_t>(n)) != n) break;
  }
  close(fd);
}

// What an upstream saw of the request the relay made of it.
struct Seen {
  std::string target;
  std::string credential;
};

// A SOCKS5 upstream that echoes once connected.
void SocksUpstream(int listener, Seen* seen) {
  const int fd = accept(listener, nullptr, nullptr);
  unsigned char b[512];
  if (!egress::ReadFull(fd, b, 2) || !egress::ReadFull(fd, b + 2, b[1])) {
    close(fd);
    return;
  }
  const unsigned char pick[] = {0x05, 0x02};
  egress::WriteFull(fd, pick, 2);
  unsigned char v, n;
  egress::ReadFull(fd, &v, 1);
  egress::ReadFull(fd, &n, 1);
  std::string user(n, '\0');
  egress::ReadFull(fd, &user[0], n);
  egress::ReadFull(fd, &n, 1);
  std::string password(n, '\0');
  if (n > 0) egress::ReadFull(fd, &password[0], n);
  seen->credential = user + ":" + password;
  const unsigned char ok[] = {0x01, 0x00};
  egress::WriteFull(fd, ok, 2);
  egress::ReadFull(fd, b, 4);
  if (b[3] == 0x03) {
    egress::ReadFull(fd, &n, 1);
    std::string name(n, '\0');
    egress::ReadFull(fd, &name[0], n);
    egress::ReadFull(fd, b, 2);
    seen->target = name + ":" + std::to_string((b[0] << 8) | b[1]);
  } else {
    seen->target = "an address";
    egress::ReadFull(fd, b, b[3] == 0x04 ? 18 : 6);
  }
  const unsigned char done[] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
  egress::WriteFull(fd, done, sizeof(done));
  Echo(fd);
}

// An HTTP CONNECT upstream that echoes once connected.
void HttpUpstream(int listener, Seen* seen) {
  const int fd = accept(listener, nullptr, nullptr);
  std::string head;
  if (!egress::ReadHead(fd, &head)) {
    close(fd);
    return;
  }
  std::istringstream lines(head);
  std::string line;
  std::getline(lines, line);
  seen->target = line.substr(0, line.find(" HTTP/"));
  while (std::getline(lines, line)) {
    const std::string key = "Proxy-Authorization: Basic ";
    if (line.compare(0, key.size(), key) != 0) continue;
    std::string encoded = line.substr(key.size());
    while (!encoded.empty() && encoded.back() == '\r') encoded.pop_back();
    gsize length = 0;
    guchar* raw = g_base64_decode(encoded.c_str(), &length);
    seen->credential.assign(reinterpret_cast<char*>(raw), length);
    g_free(raw);
  }
  egress::WriteString(fd, "HTTP/1.1 200 Connection Established\r\n\r\n");
  Echo(fd);
}

struct Request {
  std::string user;
  std::string password;
  std::string name;  // or empty for [address]
  std::string address;
  int port = 0;
};

// The relay's SOCKS5 reply to [r], or -1 when it refused the credential
// itself. [out] is the tunnel when the reply is 0.
int Ask(const egress::Relay& relay, const Request& r, int* out) {
  *out = -1;
  const int fd = Connect(relay.host(), relay.port());
  if (fd < 0) return -2;
  const unsigned char hello[] = {0x05, 0x01, 0x02};
  unsigned char b[512];
  egress::WriteFull(fd, hello, 3);
  if (!egress::ReadFull(fd, b, 2) || b[1] != 0x02) {
    close(fd);
    return -1;
  }
  std::vector<unsigned char> login{0x01,
                                   static_cast<unsigned char>(r.user.size())};
  login.insert(login.end(), r.user.begin(), r.user.end());
  login.push_back(static_cast<unsigned char>(r.password.size()));
  login.insert(login.end(), r.password.begin(), r.password.end());
  egress::WriteFull(fd, login.data(), login.size());
  if (!egress::ReadFull(fd, b, 2) || b[1] != 0x00) {
    close(fd);
    return -1;
  }
  std::vector<unsigned char> ask{0x05, 0x01, 0x00};
  if (!r.name.empty()) {
    ask.push_back(0x03);
    ask.push_back(static_cast<unsigned char>(r.name.size()));
    ask.insert(ask.end(), r.name.begin(), r.name.end());
  } else {
    in_addr a{};
    inet_pton(AF_INET, r.address.c_str(), &a);
    const auto* p = reinterpret_cast<const unsigned char*>(&a);
    ask.push_back(0x01);
    ask.insert(ask.end(), p, p + 4);
  }
  ask.push_back(static_cast<unsigned char>(r.port >> 8));
  ask.push_back(static_cast<unsigned char>(r.port & 0xff));
  egress::WriteFull(fd, ask.data(), ask.size());
  if (!egress::ReadFull(fd, b, 10)) {
    close(fd);
    return -3;
  }
  if (b[1] != 0x00) {
    close(fd);
    return b[1];
  }
  *out = fd;
  return 0;
}

bool Echoes(int fd) {
  const std::string ping = "ping through the link";
  egress::WriteString(fd, ping);
  std::string back(ping.size(), '\0');
  const bool ok = egress::ReadFull(fd, &back[0], back.size()) && back == ping;
  close(fd);
  return ok;
}

std::string User(const std::string& link, const std::string& rest = "") {
  return std::string("ws-egress-1?if=") + link + rest;
}

// The device the kernel tried to reach [address] on, from the neighbour
// table: a SYN that leaves by a link asks there who holds the address.
std::string NeighbourDevice(const std::string& address) {
  std::ifstream arp("/proc/net/arp");
  std::string line;
  std::getline(arp, line);
  while (std::getline(arp, line)) {
    std::istringstream fields(line);
    std::string ip, type, flags, mac, mask, device;
    fields >> ip >> type >> flags >> mac >> mask >> device;
    if (ip == address) return device;
  }
  return "";
}

}  // namespace

// Each line of test/fixtures/egress_credentials.tsv, which the Dart side is
// held to writing, read back into the route it names.
int Vectors() {
  const char* path = std::getenv("WS_EGRESS_VECTORS");
  if (path == nullptr) return Fail("no vectors named");
  std::ifstream file(path);
  std::string line;
  int read = 0;
  while (std::getline(file, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::vector<std::string> f;
    std::istringstream cells(line);
    std::string cell;
    while (std::getline(cells, cell, '\t')) f.push_back(cell == "-" ? "" : cell);
    if (f.size() != 10) return Fail("a vector without ten columns: " + line);
    egress::Route route;
    if (!egress::ParseRoute(f[1], f[8], f[9], &route)) {
      return Fail("refused the " + f[0] + " vector");
    }
    const std::string kind = route.kind == egress::UpstreamKind::kSocks5 ? "socks5"
                             : route.kind == egress::UpstreamKind::kHttp ? "http"
                                                                          : "";
    const std::string port = route.port == 0 ? "" : std::to_string(route.port);
    if (route.link != f[2] || kind != f[3] || route.host != f[4] ||
        port != f[5] || route.user != f[6] || route.password != f[7]) {
      return Fail("read the " + f[0] + " vector as " + route.link + "|" + kind +
                  "|" + route.host + "|" + port + "|" + route.user + "|" +
                  route.password);
    }
    read++;
  }
  return read > 0 ? 0 : Fail("no vectors read");
}

int Run(int argc, char** argv) {
  if (argc < 2) return Fail("no scenario");
  const std::string scenario = argv[1];
  if (scenario == "vectors") return Vectors();
  std::string error;
  auto relay = egress::Relay::Start(kSecret, &error);
  if (!relay) return Fail("the relay did not start: " + error);
  if (relay->host() == "127.0.0.1") return Fail("the relay took 127.0.0.1");

  int echo_port = 0;
  const int echo = Listen(&echo_port);
  std::thread([echo] {
    for (;;) {
      const int c = accept(echo, nullptr, nullptr);
      if (c < 0) return;
      std::thread(Echo, c).detach();
    }
  }).detach();

  int tunnel = -1;
  Request r;
  r.password = kSecret;
  if (scenario == "direct") {
    r.user = User("lo");
    r.address = "127.0.0.1";
    r.port = echo_port;
    const int reply = Ask(*relay, r, &tunnel);
    if (reply != 0) return Fail("refused a reachable host: " + std::to_string(reply));
    return Echoes(tunnel) ? 0 : Fail("the tunnel did not carry the bytes");
  }
  if (scenario == "bad_secret") {
    r.user = User("lo");
    r.password = "fedcba9876543210fedcba9876543210";
    r.address = "127.0.0.1";
    r.port = echo_port;
    return Ask(*relay, r, &tunnel) == -1 ? 0 : Fail("served a wrong secret");
  }
  if (scenario == "absent") {
    r.user = User("ws-absent9");
    r.address = "127.0.0.1";
    r.port = echo_port;
    const int reply = Ask(*relay, r, &tunnel);
    return reply == 0x03 ? 0 : Fail("an absent link answered " + std::to_string(reply));
  }
  if (scenario == "dns_on_link") {
    r.user = User("lo");
    r.name = "echo.test";
    r.port = echo_port;
    const int reply = Ask(*relay, r, &tunnel);
    if (reply != 0) return Fail("did not resolve on the link: " + std::to_string(reply));
    return Echoes(tunnel) ? 0 : Fail("the resolved tunnel did not carry the bytes");
  }
  if (scenario == "no_resolver") {
    r.user = User("lo");
    r.name = "echo.test";
    r.port = echo_port;
    const int reply = Ask(*relay, r, &tunnel);
    return reply == 0x04 ? 0 : Fail("a name with no resolver answered " + std::to_string(reply));
  }
  if (scenario == "onion") {
    r.user = User("lo");
    r.name = "expyuzz4wqqyqhjn.onion";
    r.port = 80;
    const int reply = Ask(*relay, r, &tunnel);
    return reply == 0x04 ? 0 : Fail("an onion name answered " + std::to_string(reply));
  }
  if (scenario == "socks_upstream" || scenario == "http_upstream") {
    const bool socks = scenario == "socks_upstream";
    int up_port = 0;
    const int up = Listen(&up_port);
    Seen seen;
    std::thread serve(socks ? SocksUpstream : HttpUpstream, up, &seen);
    r.user = User("lo", std::string("&t=") + (socks ? "socks5" : "http") +
                            "&h=127.0.0.1&p=" + std::to_string(up_port) +
                            "&u=alice");
    r.password = std::string(kSecret) + ".s3cret%2Ex";
    r.name = "site.test";
    r.port = 443;
    const int reply = Ask(*relay, r, &tunnel);
    if (reply != 0) {
      serve.detach();
      return Fail("the upstream route answered " + std::to_string(reply));
    }
    const bool carried = Echoes(tunnel);
    serve.join();
    const std::string target = socks ? "site.test:443" : "CONNECT site.test:443";
    if (seen.target != target) return Fail("the upstream was asked for " + seen.target);
    if (seen.credential != "alice:s3cret.x") {
      return Fail("the upstream was given " + seen.credential);
    }
    return carried ? 0 : Fail("the upstream tunnel did not carry the bytes");
  }
  if (scenario == "leaves_by" || scenario == "down") {
    const char* a = std::getenv("WS_LINK_A");
    const char* b = std::getenv("WS_LINK_B");
    if (a == nullptr || b == nullptr) return Fail("no links named");
    r.user = User(a);
    r.address = "198.51.100.7";
    r.port = 9;
    int reply = -4;
    std::thread ask([&] { reply = Ask(*relay, r, &tunnel); });
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    const std::string device = NeighbourDevice(r.address);
    if (scenario == "down") {
      ask.join();
      if (!device.empty()) return Fail("a down link sent towards " + device);
      return reply == 0x03 ? 0 : Fail("a down link answered " + std::to_string(reply));
    }
    ask.detach();
    if (device != a) {
      return Fail("the connection left by " +
                  (device.empty() ? std::string("no link") : device) +
                  ", not " + a);
    }
    return 0;
  }
  return Fail("unknown scenario " + scenario);
}

// Exits without unwinding: a scenario may leave a dial in flight on a
// thread, which the relay's destructor would race.
int main(int argc, char** argv) {
  const int status = Run(argc, argv);
  std::fflush(stdout);
  _exit(status);
}
