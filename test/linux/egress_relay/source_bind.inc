// Planted by check.sh: binds a socket to [link]'s IPv4 address instead of
// to the device, which Linux's weak host model routes by destination.
int BindSource(int fd, const std::string& link) {
  struct ifaddrs* all = nullptr;
  if (getifaddrs(&all) != 0) return -1;
  int result = -1;
  for (struct ifaddrs* a = all; a != nullptr; a = a->ifa_next) {
    if (a->ifa_name == nullptr || link != a->ifa_name || a->ifa_addr == nullptr ||
        a->ifa_addr->sa_family != AF_INET) {
      continue;
    }
    sockaddr_in local = *reinterpret_cast<sockaddr_in*>(a->ifa_addr);
    local.sin_port = 0;
    result = bind(fd, reinterpret_cast<sockaddr*>(&local), sizeof(local));
    break;
  }
  freeifaddrs(all);
  return result;
}
