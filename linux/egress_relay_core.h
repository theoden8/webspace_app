#ifndef RUNNER_EGRESS_RELAY_CORE_H_
#define RUNNER_EGRESS_RELAY_CORE_H_

#include <memory>
#include <string>
#include <vector>

// The relay a site bound to a network interface rides (network-interface
// NETIF-003, NETIF-004): a SOCKS5 server on a random loopback address whose
// every outbound socket is bound to the interface the caller's credential
// names, before it connects. Free of Flutter so the test harness drives it as
// the channel does (test/linux/egress_relay/).
//
// The credential carries the whole route, so the relay keeps no table:
//   username  ws-egress-1?if=<link>[&t=socks5|http&h=<host>&p=<port>[&u=<user>]]
//   password  <secret>[.<upstream password>]
// each value percent-encoded; `lib/services/egress_route.dart` writes it.
namespace egress {

// A link as getifaddrs reports it, for the interface picker (NETIF-010).
struct Link {
  std::string name;
  bool up = false;
  std::vector<std::string> addresses;
};

std::vector<Link> Links();

// Whether this process may bind a socket to a device: Linux 5.7 and later
// let an unprivileged process do it, earlier ones need CAP_NET_RAW.
bool CanBindDevice();

struct Shared;

class Relay {
 public:
  // Listens on a random 127/8 address; every caller presents [secret].
  static std::unique_ptr<Relay> Start(const std::string& secret,
                                      std::string* error);
  ~Relay();

  const std::string& host() const { return host_; }
  int port() const { return port_; }

  // Ends the listener and every connection it carried.
  void Stop();

 private:
  Relay() = default;

  std::shared_ptr<Shared> shared_;
  std::string host_;
  int port_ = 0;
};

}  // namespace egress

#endif  // RUNNER_EGRESS_RELAY_CORE_H_
