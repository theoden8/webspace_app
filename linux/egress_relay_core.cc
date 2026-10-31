#include "egress_relay_core.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <thread>

namespace egress {

struct Shared {
  std::string secret;
  std::atomic<bool> stopping{false};
  // Every socket a connection holds, so Stop can end it. A thread takes its
  // socket out under the lock before closing it, so Stop never reaches a
  // descriptor that was closed and handed out again.
  std::mutex mu;
  std::set<int> live;
  int listener = -1;
  std::thread acceptor;
};

namespace {

constexpr char kPrefix[] = "ws-egress-1?";
constexpr int kHandshakeMs = 15000;
constexpr int kDialMs = 15000;
constexpr int kResolveMs = 10000;

// SOCKS5 replies (RFC 1928 section 6).
constexpr unsigned char kGeneralFailure = 0x01;
constexpr unsigned char kNetworkUnreachable = 0x03;
constexpr unsigned char kHostUnreachable = 0x04;
constexpr unsigned char kConnectionRefused = 0x05;
constexpr unsigned char kCommandNotSupported = 0x07;
constexpr unsigned char kAddressNotSupported = 0x08;

enum class UpstreamKind { kNone, kSocks5, kHttp };

struct Route {
  std::string link;
  UpstreamKind kind = UpstreamKind::kNone;
  std::string host;
  int port = 0;
  std::string user;
  std::string password;
};

struct Target {
  std::string name;  // a host name, or empty when [address] holds a literal
  sockaddr_storage address{};
  socklen_t length = 0;
  int port = 0;
};

// The families [link] can carry: whether it exists and is up, and which
// address families it holds an address of.
struct LinkState {
  bool present = false;
  bool up = false;
  bool v4 = false;
  bool v6 = false;
  unsigned index = 0;
};

bool ValidLinkName(const std::string& name) {
  if (name.empty() || name.size() >= IFNAMSIZ) return false;
  for (char c : name) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '.' || c == '_' ||
                    c == '-';
    if (!ok) return false;
  }
  return true;
}

LinkState StateOf(const std::string& link) {
  LinkState state;
  struct ifaddrs* all = nullptr;
  if (getifaddrs(&all) != 0) return state;
  for (struct ifaddrs* a = all; a != nullptr; a = a->ifa_next) {
    if (a->ifa_name == nullptr || link != a->ifa_name) continue;
    state.present = true;
    if (a->ifa_flags & IFF_UP) state.up = true;
    if (a->ifa_addr == nullptr) continue;
    if (a->ifa_addr->sa_family == AF_INET) state.v4 = true;
    if (a->ifa_addr->sa_family == AF_INET6) {
      const auto* in6 = reinterpret_cast<const sockaddr_in6*>(a->ifa_addr);
      if (!IN6_IS_ADDR_LINKLOCAL(&in6->sin6_addr)) state.v6 = true;
    }
  }
  freeifaddrs(all);
  state.index = if_nametoindex(link.c_str());
  if (state.index == 0) state.present = false;
  return state;
}

bool Wait(int fd, short events, int timeout_ms) {
  pollfd p{fd, events, 0};
  int r;
  do {
    r = poll(&p, 1, timeout_ms);
  } while (r < 0 && errno == EINTR);
  return r > 0 && (p.revents & events);
}

bool ReadFull(int fd, void* buffer, size_t length) {
  auto* at = static_cast<unsigned char*>(buffer);
  while (length > 0) {
    if (!Wait(fd, POLLIN, kHandshakeMs)) return false;
    const ssize_t n = read(fd, at, length);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    at += n;
    length -= static_cast<size_t>(n);
  }
  return true;
}

bool WriteFull(int fd, const void* buffer, size_t length) {
  const auto* at = static_cast<const unsigned char*>(buffer);
  while (length > 0) {
    const ssize_t n = send(fd, at, length, MSG_NOSIGNAL);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    at += n;
    length -= static_cast<size_t>(n);
  }
  return true;
}

bool WriteString(int fd, const std::string& text) {
  return WriteFull(fd, text.data(), text.size());
}

// A head of an HTTP reply, up to its blank line; false past 16 KiB.
bool ReadHead(int fd, std::string* head) {
  head->clear();
  char c;
  while (head->size() < 16384) {
    if (!ReadFull(fd, &c, 1)) return false;
    head->push_back(c);
    const size_t n = head->size();
    if (n >= 4 && head->compare(n - 4, 4, "\r\n\r\n") == 0) return true;
  }
  return false;
}

bool SecretMatches(const std::string& secret, const std::string& given) {
  if (given.size() != secret.size()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < secret.size(); i++) {
    diff |= static_cast<unsigned char>(secret[i] ^ given[i]);
  }
  return diff == 0;
}

std::string Unescape(const std::string& text) {
  char* raw = g_uri_unescape_string(text.c_str(), nullptr);
  if (raw == nullptr) return std::string();
  std::string out(raw);
  g_free(raw);
  return out;
}

// The route [username] and [password] name, or false for a caller this
// relay does not serve.
bool ParseRoute(const std::string& secret, const std::string& username,
                const std::string& password, Route* route) {
  const size_t dot = password.find('.');
  const std::string given = password.substr(0, dot);
  if (!SecretMatches(secret, given)) return false;
  if (dot != std::string::npos) {
    route->password = Unescape(password.substr(dot + 1));
  }
  const size_t prefix = sizeof(kPrefix) - 1;
  if (username.compare(0, prefix, kPrefix) != 0) return false;
  GError* error = nullptr;
  GHashTable* params =
      g_uri_parse_params(username.c_str() + prefix, -1, "&",
                         G_URI_PARAMS_NONE, &error);
  if (params == nullptr) {
    g_clear_error(&error);
    return false;
  }
  std::map<std::string, std::string> fields;
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init(&it, params);
  while (g_hash_table_iter_next(&it, &key, &value)) {
    fields[static_cast<const char*>(key)] = static_cast<const char*>(value);
  }
  g_hash_table_unref(params);
  route->link = fields["if"];
  if (!ValidLinkName(route->link)) return false;
  const std::string kind = fields["t"];
  if (kind.empty()) return true;
  if (kind == "socks5") {
    route->kind = UpstreamKind::kSocks5;
  } else if (kind == "http") {
    route->kind = UpstreamKind::kHttp;
  } else {
    return false;
  }
  route->host = fields["h"];
  route->port = atoi(fields["p"].c_str());
  route->user = fields["u"];
  return !route->host.empty() && route->port > 0 && route->port <= 65535;
}

bool Literal(const std::string& host, int port, sockaddr_storage* out,
             socklen_t* length) {
  std::memset(out, 0, sizeof(*out));
  auto* in4 = reinterpret_cast<sockaddr_in*>(out);
  if (inet_pton(AF_INET, host.c_str(), &in4->sin_addr) == 1) {
    in4->sin_family = AF_INET;
    in4->sin_port = htons(static_cast<uint16_t>(port));
    *length = sizeof(sockaddr_in);
    return true;
  }
  auto* in6 = reinterpret_cast<sockaddr_in6*>(out);
  std::string bare = host;
  if (bare.size() > 2 && bare.front() == '[' && bare.back() == ']') {
    bare = bare.substr(1, bare.size() - 2);
  }
  if (inet_pton(AF_INET6, bare.c_str(), &in6->sin6_addr) == 1) {
    in6->sin6_family = AF_INET6;
    in6->sin6_port = htons(static_cast<uint16_t>(port));
    *length = sizeof(sockaddr_in6);
    return true;
  }
  return false;
}

bool IsOnion(const std::string& name) {
  const std::string suffix = ".onion";
  std::string lower(name);
  for (char& c : lower) c = static_cast<char>(g_ascii_tolower(c));
  while (!lower.empty() && lower.back() == '.') lower.pop_back();
  return lower.size() >= suffix.size() &&
         lower.compare(lower.size() - suffix.size(), suffix.size(), suffix) ==
             0;
}

// [name] through systemd-resolved, asking only [link]'s servers (NETIF-007):
// the system resolver would ask whichever link the default route names.
bool ResolveOnLink(const std::string& name, const LinkState& link, int port,
                   std::vector<std::pair<sockaddr_storage, socklen_t>>* out) {
  GError* error = nullptr;
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
  if (bus == nullptr) {
    g_clear_error(&error);
    return false;
  }
  const gint32 family = link.v4 && link.v6 ? AF_UNSPEC
                        : link.v4          ? AF_INET
                                           : AF_INET6;
  GVariant* reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.resolve1", "/org/freedesktop/resolve1",
      "org.freedesktop.resolve1.Manager", "ResolveHostname",
      g_variant_new("(isit)", static_cast<gint32>(link.index), name.c_str(),
                    family, static_cast<guint64>(0)),
      G_VARIANT_TYPE("(a(iiay)st)"), G_DBUS_CALL_FLAGS_NO_AUTO_START,
      kResolveMs, nullptr, &error);
  g_object_unref(bus);
  if (reply == nullptr) {
    g_clear_error(&error);
    return false;
  }
  GVariantIter* addresses = nullptr;
  g_variant_get(reply, "(a(iiay)&st)", &addresses, nullptr, nullptr);
  gint32 index, af;
  GVariantIter* bytes = nullptr;
  while (g_variant_iter_next(addresses, "(iiay)", &index, &af, &bytes)) {
    std::vector<unsigned char> raw;
    guchar b;
    while (g_variant_iter_next(bytes, "y", &b)) raw.push_back(b);
    g_variant_iter_free(bytes);
    if (index != static_cast<gint32>(link.index) && index != 0) continue;
    sockaddr_storage address{};
    socklen_t length = 0;
    if (af == AF_INET && link.v4 && raw.size() == 4) {
      auto* in4 = reinterpret_cast<sockaddr_in*>(&address);
      in4->sin_family = AF_INET;
      in4->sin_port = htons(static_cast<uint16_t>(port));
      std::memcpy(&in4->sin_addr, raw.data(), 4);
      length = sizeof(sockaddr_in);
    } else if (af == AF_INET6 && link.v6 && raw.size() == 16) {
      auto* in6 = reinterpret_cast<sockaddr_in6*>(&address);
      in6->sin6_family = AF_INET6;
      in6->sin6_port = htons(static_cast<uint16_t>(port));
      std::memcpy(&in6->sin6_addr, raw.data(), 16);
      length = sizeof(sockaddr_in6);
    } else {
      continue;
    }
    out->emplace_back(address, length);
  }
  g_variant_iter_free(addresses);
  g_variant_unref(reply);
  return !out->empty();
}

void Track(Shared* shared, int fd) {
  std::lock_guard<std::mutex> lock(shared->mu);
  shared->live.insert(fd);
}

void Release(Shared* shared, int fd) {
  if (fd < 0) return;
  {
    std::lock_guard<std::mutex> lock(shared->mu);
    shared->live.erase(fd);
  }
  close(fd);
}

// A socket to [to] that leaves by [link] and by nothing else (NETIF-003),
// or -1 with [reply] saying why.
int DialOnLink(Shared* shared, const std::string& link,
               const sockaddr_storage& to, socklen_t length,
               unsigned char* reply) {
  const int fd = socket(to.ss_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    *reply = kGeneralFailure;
    return -1;
  }
  Track(shared, fd);
  if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, link.c_str(),
                 static_cast<socklen_t>(link.size())) != 0) {
    *reply = kNetworkUnreachable;
    Release(shared, fd);
    return -1;
  }
  const int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  int error = 0;
  if (connect(fd, reinterpret_cast<const sockaddr*>(&to), length) != 0) {
    error = errno;
    if (error == EINPROGRESS) {
      error = ETIMEDOUT;
      if (Wait(fd, POLLOUT, kDialMs)) {
        socklen_t size = sizeof(error);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size);
      }
    }
  }
  if (error != 0) {
    *reply = error == ECONNREFUSED                         ? kConnectionRefused
             : (error == ENETUNREACH || error == ENETDOWN) ? kNetworkUnreachable
                                                           : kHostUnreachable;
    Release(shared, fd);
    return -1;
  }
  fcntl(fd, F_SETFL, flags);
  return fd;
}

// The first address of [host] that [link] reaches; a name is resolved on the
// link only.
int DialHost(Shared* shared, const std::string& host, int port,
             const std::string& link, const LinkState& state,
             unsigned char* reply) {
  std::vector<std::pair<sockaddr_storage, socklen_t>> candidates;
  sockaddr_storage literal{};
  socklen_t length = 0;
  if (Literal(host, port, &literal, &length)) {
    const bool v6 = literal.ss_family == AF_INET6;
    if ((v6 && !state.v6) || (!v6 && !state.v4)) {
      *reply = kNetworkUnreachable;
      return -1;
    }
    candidates.emplace_back(literal, length);
  } else if (IsOnion(host)) {
    // Only Tor resolves an onion name, and Tor is not on this route
    // (LEAK-016).
    *reply = kHostUnreachable;
    return -1;
  } else if (!ResolveOnLink(host, state, port, &candidates)) {
    *reply = kHostUnreachable;
    return -1;
  }
  *reply = kHostUnreachable;
  for (const auto& c : candidates) {
    const int fd = DialOnLink(shared, link, c.first, c.second, reply);
    if (fd >= 0) return fd;
  }
  return -1;
}

void AppendTarget(std::vector<unsigned char>* out, const Target& target) {
  if (!target.name.empty()) {
    out->push_back(0x03);
    out->push_back(static_cast<unsigned char>(target.name.size()));
    out->insert(out->end(), target.name.begin(), target.name.end());
  } else if (target.address.ss_family == AF_INET) {
    const auto* in4 = reinterpret_cast<const sockaddr_in*>(&target.address);
    const auto* b = reinterpret_cast<const unsigned char*>(&in4->sin_addr);
    out->push_back(0x01);
    out->insert(out->end(), b, b + 4);
  } else {
    const auto* in6 = reinterpret_cast<const sockaddr_in6*>(&target.address);
    const auto* b = reinterpret_cast<const unsigned char*>(&in6->sin6_addr);
    out->push_back(0x04);
    out->insert(out->end(), b, b + 16);
  }
  out->push_back(static_cast<unsigned char>(target.port >> 8));
  out->push_back(static_cast<unsigned char>(target.port & 0xff));
}

std::string TargetText(const Target& target) {
  if (!target.name.empty()) return target.name;
  char text[INET6_ADDRSTRLEN] = {0};
  if (target.address.ss_family == AF_INET) {
    inet_ntop(AF_INET,
              &reinterpret_cast<const sockaddr_in*>(&target.address)->sin_addr,
              text, sizeof(text));
    return text;
  }
  inet_ntop(AF_INET6,
            &reinterpret_cast<const sockaddr_in6*>(&target.address)->sin6_addr,
            text, sizeof(text));
  return std::string("[") + text + "]";
}

// [target] through the route's upstream, which the relay reached over the
// link (NETIF-005); the upstream resolves a name itself.
bool ThroughUpstream(int fd, const Route& route, const Target& target,
                     unsigned char* reply) {
  *reply = kGeneralFailure;
  if (route.kind == UpstreamKind::kHttp) {
    const std::string authority =
        TargetText(target) + ":" + std::to_string(target.port);
    std::string request = "CONNECT " + authority + " HTTP/1.1\r\nHost: " +
                          authority + "\r\n";
    if (!route.user.empty()) {
      const std::string pair = route.user + ":" + route.password;
      gchar* encoded = g_base64_encode(
          reinterpret_cast<const guchar*>(pair.data()), pair.size());
      request += std::string("Proxy-Authorization: Basic ") + encoded + "\r\n";
      g_free(encoded);
    }
    request += "\r\n";
    std::string head;
    if (!WriteString(fd, request) || !ReadHead(fd, &head)) return false;
    const bool ok = head.compare(0, 12, "HTTP/1.1 200") == 0 ||
                    head.compare(0, 12, "HTTP/1.0 200") == 0;
    if (!ok) *reply = kConnectionRefused;
    return ok;
  }
  const bool auth = !route.user.empty();
  const unsigned char hello[] = {0x05, 0x01,
                                 static_cast<unsigned char>(auth ? 0x02 : 0x00)};
  unsigned char choice[2];
  if (!WriteFull(fd, hello, sizeof(hello)) || !ReadFull(fd, choice, 2)) {
    return false;
  }
  if (choice[0] != 0x05 || choice[1] != hello[2]) return false;
  if (auth) {
    if (route.user.size() > 255 || route.password.size() > 255) return false;
    std::vector<unsigned char> login{0x01};
    login.push_back(static_cast<unsigned char>(route.user.size()));
    login.insert(login.end(), route.user.begin(), route.user.end());
    login.push_back(static_cast<unsigned char>(route.password.size()));
    login.insert(login.end(), route.password.begin(), route.password.end());
    unsigned char status[2];
    if (!WriteFull(fd, login.data(), login.size()) ||
        !ReadFull(fd, status, 2) || status[1] != 0x00) {
      return false;
    }
  }
  std::vector<unsigned char> request{0x05, 0x01, 0x00};
  AppendTarget(&request, target);
  unsigned char head[4];
  if (!WriteFull(fd, request.data(), request.size()) ||
      !ReadFull(fd, head, 4)) {
    return false;
  }
  if (head[1] != 0x00) {
    *reply = head[1];
    return false;
  }
  size_t rest = 0;
  if (head[3] == 0x01) {
    rest = 4;
  } else if (head[3] == 0x04) {
    rest = 16;
  } else if (head[3] == 0x03) {
    unsigned char n;
    if (!ReadFull(fd, &n, 1)) return false;
    rest = n;
  } else {
    return false;
  }
  std::vector<unsigned char> bound(rest + 2);
  return ReadFull(fd, bound.data(), bound.size());
}

void Answer(int client, unsigned char code) {
  const unsigned char reply[] = {0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
  WriteFull(client, reply, sizeof(reply));
}

// Copies both ways until both sides are done.
void Pump(int a, int b) {
  bool a_open = true, b_open = true;
  char buffer[16384];
  while (a_open || b_open) {
    pollfd fds[2] = {{a_open ? a : -1, POLLIN, 0}, {b_open ? b : -1, POLLIN, 0}};
    const int r = poll(fds, 2, -1);
    if (r < 0) {
      if (errno == EINTR) continue;
      return;
    }
    for (int i = 0; i < 2; i++) {
      if (fds[i].fd < 0 || fds[i].revents == 0) continue;
      const int from = i == 0 ? a : b;
      const int to = i == 0 ? b : a;
      const ssize_t n = read(from, buffer, sizeof(buffer));
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) {
        shutdown(to, SHUT_WR);
        (i == 0 ? a_open : b_open) = false;
        if (n < 0) return;
        continue;
      }
      if (!WriteFull(to, buffer, static_cast<size_t>(n))) return;
    }
  }
}

bool ReadTarget(int client, Target* target) {
  unsigned char head[4];
  if (!ReadFull(client, head, 4) || head[0] != 0x05) return false;
  if (head[1] != 0x01) {
    Answer(client, kCommandNotSupported);
    return false;
  }
  if (head[3] == 0x01 || head[3] == 0x04) {
    const bool v6 = head[3] == 0x04;
    unsigned char raw[16];
    if (!ReadFull(client, raw, v6 ? 16 : 4)) return false;
    if (v6) {
      auto* in6 = reinterpret_cast<sockaddr_in6*>(&target->address);
      in6->sin6_family = AF_INET6;
      std::memcpy(&in6->sin6_addr, raw, 16);
      target->length = sizeof(sockaddr_in6);
    } else {
      auto* in4 = reinterpret_cast<sockaddr_in*>(&target->address);
      in4->sin_family = AF_INET;
      std::memcpy(&in4->sin_addr, raw, 4);
      target->length = sizeof(sockaddr_in);
    }
  } else if (head[3] == 0x03) {
    unsigned char n;
    if (!ReadFull(client, &n, 1) || n == 0) return false;
    target->name.resize(n);
    if (!ReadFull(client, &target->name[0], n)) return false;
  } else {
    Answer(client, kAddressNotSupported);
    return false;
  }
  unsigned char port[2];
  if (!ReadFull(client, port, 2)) return false;
  target->port = (port[0] << 8) | port[1];
  if (target->address.ss_family == AF_INET) {
    reinterpret_cast<sockaddr_in*>(&target->address)->sin_port =
        htons(static_cast<uint16_t>(target->port));
  } else if (target->address.ss_family == AF_INET6) {
    reinterpret_cast<sockaddr_in6*>(&target->address)->sin6_port =
        htons(static_cast<uint16_t>(target->port));
  }
  return target->port > 0;
}

bool Authenticate(int client, const std::string& secret, Route* route) {
  unsigned char hello[2];
  if (!ReadFull(client, hello, 2) || hello[0] != 0x05 || hello[1] == 0) {
    return false;
  }
  unsigned char methods[255];
  if (!ReadFull(client, methods, hello[1])) return false;
  bool offered = false;
  for (int i = 0; i < hello[1]; i++) offered |= methods[i] == 0x02;
  if (!offered) {
    // No credential, no route: an unattributable caller is refused rather
    // than dialled by the default route (LEAK-009).
    const unsigned char none[] = {0x05, 0xff};
    WriteFull(client, none, sizeof(none));
    return false;
  }
  const unsigned char pick[] = {0x05, 0x02};
  if (!WriteFull(client, pick, sizeof(pick))) return false;
  unsigned char version, length;
  if (!ReadFull(client, &version, 1) || version != 0x01 ||
      !ReadFull(client, &length, 1)) {
    return false;
  }
  std::string user(length, '\0');
  if (length > 0 && !ReadFull(client, &user[0], length)) return false;
  if (!ReadFull(client, &length, 1)) return false;
  std::string password(length, '\0');
  if (length > 0 && !ReadFull(client, &password[0], length)) return false;
  const bool ok = ParseRoute(secret, user, password, route);
  const unsigned char status[] = {0x01, static_cast<unsigned char>(ok ? 0 : 1)};
  WriteFull(client, status, sizeof(status));
  return ok;
}

void Serve(std::shared_ptr<Shared> shared, int client) {
  int upstream = -1;
  Route route;
  Target target;
  if (Authenticate(client, shared->secret, &route) &&
      ReadTarget(client, &target)) {
    const LinkState state = StateOf(route.link);
    unsigned char reply = kNetworkUnreachable;
    if (!state.present || !state.up || !(state.v4 || state.v6)) {
      // The interface the site names is gone or down: refuse, never the
      // default route (NETIF-002).
      Answer(client, kNetworkUnreachable);
    } else if (route.kind == UpstreamKind::kNone) {
      upstream = target.name.empty()
                     ? DialHost(shared.get(), TargetText(target), target.port,
                                route.link, state, &reply)
                     : DialHost(shared.get(), target.name, target.port,
                                route.link, state, &reply);
      if (upstream < 0) Answer(client, reply);
    } else {
      upstream = DialHost(shared.get(), route.host, route.port, route.link,
                          state, &reply);
      if (upstream >= 0 && !ThroughUpstream(upstream, route, target, &reply)) {
        Release(shared.get(), upstream);
        upstream = -1;
      }
      if (upstream < 0) Answer(client, reply);
    }
    if (upstream >= 0) {
      Answer(client, 0x00);
      Pump(client, upstream);
    }
  }
  Release(shared.get(), upstream);
  Release(shared.get(), client);
}

void AcceptLoop(std::shared_ptr<Shared> shared) {
  while (!shared->stopping.load()) {
    const int client = accept4(shared->listener, nullptr, nullptr, SOCK_CLOEXEC);
    if (client < 0) {
      if (errno == EINTR || errno == ECONNABORTED) continue;
      return;
    }
    if (shared->stopping.load()) {
      close(client);
      return;
    }
    Track(shared.get(), client);
    std::thread(Serve, shared, client).detach();
  }
}

}  // namespace

std::vector<Link> Links() {
  std::vector<Link> out;
  std::map<std::string, size_t> at;
  struct ifaddrs* all = nullptr;
  if (getifaddrs(&all) != 0) return out;
  for (struct ifaddrs* a = all; a != nullptr; a = a->ifa_next) {
    if (a->ifa_name == nullptr) continue;
    auto found = at.find(a->ifa_name);
    if (found == at.end()) {
      found = at.emplace(a->ifa_name, out.size()).first;
      out.push_back(Link{a->ifa_name, false, {}});
    }
    Link& link = out[found->second];
    if (a->ifa_flags & IFF_UP) link.up = true;
    if (a->ifa_addr == nullptr) continue;
    char text[INET6_ADDRSTRLEN] = {0};
    if (a->ifa_addr->sa_family == AF_INET) {
      inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(a->ifa_addr)->sin_addr,
                text, sizeof(text));
      link.addresses.push_back(text);
    } else if (a->ifa_addr->sa_family == AF_INET6) {
      inet_ntop(AF_INET6,
                &reinterpret_cast<sockaddr_in6*>(a->ifa_addr)->sin6_addr, text,
                sizeof(text));
      link.addresses.push_back(text);
    }
  }
  freeifaddrs(all);
  return out;
}

bool CanBindDevice() {
  const int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return false;
  const bool ok = setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, "lo", 2) == 0;
  close(fd);
  return ok;
}

std::unique_ptr<Relay> Relay::Start(const std::string& secret,
                                    std::string* error) {
  if (secret.size() < 16 || secret.find('.') != std::string::npos) {
    *error = "the secret is too short or holds a dot";
    return nullptr;
  }
  auto shared = std::make_shared<Shared>();
  shared->secret = secret;
  const int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    *error = strerror(errno);
    return nullptr;
  }
  // Not 127.0.0.1: an unguessable address in 127/8 is not one something else
  // on the machine already listens on (PROXY-024).
  unsigned char random[3] = {0, 0, 1};
  if (getrandom(random, sizeof(random), 0) != sizeof(random)) {
    close(fd);
    *error = "no randomness for the address";
    return nullptr;
  }
  if (random[2] == 0 || random[2] == 255) random[2] = 7;
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr =
      htonl((127u << 24) | (random[0] << 16) | (random[1] << 8) | random[2]);
  if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      listen(fd, 64) != 0) {
    *error = strerror(errno);
    close(fd);
    return nullptr;
  }
  socklen_t length = sizeof(address);
  getsockname(fd, reinterpret_cast<sockaddr*>(&address), &length);
  char text[INET_ADDRSTRLEN] = {0};
  inet_ntop(AF_INET, &address.sin_addr, text, sizeof(text));
  shared->listener = fd;
  std::unique_ptr<Relay> relay(new Relay());
  relay->shared_ = shared;
  relay->host_ = text;
  relay->port_ = ntohs(address.sin_port);
  shared->acceptor = std::thread(AcceptLoop, shared);
  return relay;
}

void Relay::Stop() {
  if (!shared_ || shared_->stopping.exchange(true)) return;
  shutdown(shared_->listener, SHUT_RDWR);
  if (shared_->acceptor.joinable()) shared_->acceptor.join();
  close(shared_->listener);
  std::lock_guard<std::mutex> lock(shared_->mu);
  for (int fd : shared_->live) shutdown(fd, SHUT_RDWR);
}

Relay::~Relay() { Stop(); }

}  // namespace egress
