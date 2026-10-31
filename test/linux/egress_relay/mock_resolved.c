// A stand-in for systemd-resolved on the bus check.sh runs: ResolveHostname
// answers `echo.test` with 127.0.0.1 only when asked on the loopback link's
// index, as resolved answers only from the servers of the link it is asked
// on. A lookup on any other link, or on none (index 0), finds no servers.
// It also answers any onion name, as a VPN's hijacking resolver might, so a
// relay that asks it about one is caught dialling.
#include <gio/gio.h>
#include <net/if.h>
#include <string.h>
#include <sys/socket.h>

static const gchar kXml[] =
    "<node><interface name='org.freedesktop.resolve1.Manager'>"
    "<method name='ResolveHostname'>"
    "<arg type='i' direction='in'/><arg type='s' direction='in'/>"
    "<arg type='i' direction='in'/><arg type='t' direction='in'/>"
    "<arg type='a(iiay)' direction='out'/><arg type='s' direction='out'/>"
    "<arg type='t' direction='out'/>"
    "</method></interface></node>";

static void on_call(GDBusConnection* connection, const gchar* sender,
                    const gchar* path, const gchar* interface,
                    const gchar* method, GVariant* parameters,
                    GDBusMethodInvocation* invocation, gpointer data) {
  gint32 index, family;
  const gchar* name;
  guint64 flags;
  g_variant_get(parameters, "(i&sit)", &index, &name, &family, &flags);
  const gint32 lo = (gint32)if_nametoindex("lo");
  const size_t n = strlen(name);
  const gboolean onion = n > 6 && strcmp(name + n - 6, ".onion") == 0;
  if (index != lo || (strcmp(name, "echo.test") != 0 && !onion) ||
      (family != AF_UNSPEC && family != AF_INET)) {
    g_dbus_method_invocation_return_dbus_error(
        invocation, "org.freedesktop.resolve1.NoNameServers",
        "No appropriate name servers or networks for name found");
    return;
  }
  GVariantBuilder addresses;
  g_variant_builder_init(&addresses, G_VARIANT_TYPE("a(iiay)"));
  const guchar loopback[] = {127, 0, 0, 1};
  g_variant_builder_add(
      &addresses, "(ii@ay)", lo, AF_INET,
      g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, loopback, 4, 1));
  g_dbus_method_invocation_return_value(
      invocation,
      g_variant_new("(a(iiay)st)", &addresses, name, (guint64)0));
}

static const GDBusInterfaceVTable kVtable = {on_call, NULL, NULL, {0}};

static void on_bus(GDBusConnection* connection, const gchar* name,
                   gpointer data) {
  GDBusNodeInfo* info = g_dbus_node_info_new_for_xml(kXml, NULL);
  g_dbus_connection_register_object(connection, "/org/freedesktop/resolve1",
                                    info->interfaces[0], &kVtable, NULL, NULL,
                                    NULL);
  g_dbus_node_info_unref(info);
}

int main(void) {
  GMainLoop* loop = g_main_loop_new(NULL, FALSE);
  g_bus_own_name(G_BUS_TYPE_SESSION, "org.freedesktop.resolve1",
                 G_BUS_NAME_OWNER_FLAGS_NONE, on_bus, NULL, NULL, NULL, NULL);
  g_main_loop_run(loop);
  return 0;
}
