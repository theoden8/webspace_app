#ifndef RUNNER_EGRESS_RELAY_H_
#define RUNNER_EGRESS_RELAY_H_

#include <flutter_linux/flutter_linux.h>

// The `egress_relay` channel on Linux (network-interface NETIF-003): `probe`
// answers whether a socket may be bound to a device, `links` lists the
// interfaces, `start` runs the relay (egress_relay_core.h) under the secret
// Dart minted and answers its address. The view owns the relay.
void egress_relay_attach(FlView* view);

#endif  // RUNNER_EGRESS_RELAY_H_
