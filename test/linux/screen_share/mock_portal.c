// A stand-in for xdg-desktop-portal's ScreenCast, enough to drive
// linux/screen_share.cc: its properties, CreateSession, SelectSources, Start
// (answered with PORTAL_START_CODE, 0 for a pick and 1 for a cancelled
// dialog, and the stream PORTAL_NODE), and OpenPipeWireRemote (a socket to
// $XDG_RUNTIME_DIR/pipewire-0). With PORTAL_CLOSE_AFTER=n it closes the
// session n seconds after Start, as the desktop's own Stop does. Every call
// it takes is printed.
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static const char *kXml =
    "<node>"
    " <interface name='org.freedesktop.portal.ScreenCast'>"
    "  <method name='CreateSession'><arg type='a{sv}' direction='in'/>"
    "   <arg type='o' direction='out'/></method>"
    "  <method name='SelectSources'><arg type='o' direction='in'/>"
    "   <arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>"
    "  <method name='Start'><arg type='o' direction='in'/><arg type='s' direction='in'/>"
    "   <arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>"
    "  <method name='OpenPipeWireRemote'><arg type='o' direction='in'/>"
    "   <arg type='a{sv}' direction='in'/><arg type='h' direction='out'/></method>"
    "  <property name='AvailableSourceTypes' type='u' access='read'/>"
    "  <property name='AvailableCursorModes' type='u' access='read'/>"
    "  <property name='version' type='u' access='read'/>"
    " </interface>"
    " <interface name='org.freedesktop.portal.Session'><method name='Close'/></interface>"
    " <interface name='org.freedesktop.portal.Request'><method name='Close'/></interface>"
    "</node>";

static GDBusNodeInfo *info;
static GDBusConnection *bus;
static char session_path[256];
static char session_owner[128];

typedef struct {
  char *dest;
  char *path;
  guint32 code;
  GVariant *results;
} Answer;

static const GDBusInterfaceVTable *vtable_ref(void);

static void expose(const char *path, int iface) {
  g_dbus_connection_register_object(bus, path, info->interfaces[iface], vtable_ref(), NULL,
                                    NULL, NULL);
}

static gboolean emit_answer(gpointer data) {
  Answer *a = data;
  g_dbus_connection_emit_signal(bus, a->dest, a->path, "org.freedesktop.portal.Request",
                                "Response", g_variant_new("(u@a{sv})", a->code, a->results),
                                NULL);
  printf("portal: Response %u on %s\n", a->code, a->path);
  fflush(stdout);
  g_free(a->dest);
  g_free(a->path);
  g_free(a);
  return G_SOURCE_REMOVE;
}

static gboolean emit_closed(gpointer data) {
  (void)data;
  g_dbus_connection_emit_signal(bus, session_owner, session_path,
                                "org.freedesktop.portal.Session", "Closed",
                                g_variant_new("(a{sv})", NULL), NULL);
  printf("portal: the desktop closed the session\n");
  fflush(stdout);
  return G_SOURCE_REMOVE;
}

static char *sender_part(const char *sender) {
  char *s = g_strdup(sender + 1);
  for (char *c = s; *c; c++)
    if (*c == '.') *c = '_';
  return s;
}

static char *request_for(const char *sender, GVariant *options) {
  const char *token = "t";
  g_variant_lookup(options, "handle_token", "&s", &token);
  char *part = sender_part(sender);
  char *path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", part, token);
  g_free(part);
  return path;
}

// Answers on the Request object a moment after the call returns, as the
// portal does once its dialog is done.
static void answer_later(const char *sender, const char *path, guint32 code,
                         GVariant *results) {
  expose(path, 2);
  Answer *a = g_new0(Answer, 1);
  a->dest = g_strdup(sender);
  a->path = g_strdup(path);
  a->code = code;
  a->results = g_variant_ref_sink(results);
  g_timeout_add(50, emit_answer, a);
}

static int pipewire_socket(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  struct sockaddr_un addr = {0};
  addr.sun_family = AF_UNIX;
  snprintf(addr.sun_path, sizeof addr.sun_path, "%s/pipewire-0", g_getenv("XDG_RUNTIME_DIR"));
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    perror("portal: connect to pipewire");
    close(fd);
    return -1;
  }
  return fd;
}

static int env_int(const char *name) {
  const char *value = g_getenv(name);
  return value != NULL && *value != 0 ? atoi(value) : -1;
}

static void call(GDBusConnection *c, const char *sender, const char *path, const char *iface,
                 const char *method, GVariant *params, GDBusMethodInvocation *inv, gpointer ud) {
  (void)c;
  (void)ud;
  printf("portal: %s.%s on %s\n", iface, method, path);
  fflush(stdout);
  if (g_str_equal(method, "Close")) {
    g_dbus_method_invocation_return_value(inv, NULL);
    return;
  }
  if (g_str_equal(method, "CreateSession")) {
    g_autoptr(GVariant) options = g_variant_get_child_value(params, 0);
    char *req = request_for(sender, options);
    const char *token = "s";
    g_variant_lookup(options, "session_handle_token", "&s", &token);
    char *part = sender_part(sender);
    snprintf(session_path, sizeof session_path,
             "/org/freedesktop/portal/desktop/session/%s/%s", part, token);
    snprintf(session_owner, sizeof session_owner, "%s", sender);
    g_free(part);
    expose(session_path, 1);
    g_dbus_method_invocation_return_value(inv, g_variant_new("(o)", req));
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&b, "{sv}", "session_handle", g_variant_new_string(session_path));
    answer_later(sender, req, 0, g_variant_builder_end(&b));
    g_free(req);
    return;
  }
  if (g_str_equal(method, "SelectSources")) {
    g_autoptr(GVariant) options = g_variant_get_child_value(params, 1);
    guint32 types = 0, cursor = 0;
    g_variant_lookup(options, "types", "u", &types);
    g_variant_lookup(options, "cursor_mode", "u", &cursor);
    printf("portal: types=%u cursor_mode=%u\n", types, cursor);
    char *req = request_for(sender, options);
    g_dbus_method_invocation_return_value(inv, g_variant_new("(o)", req));
    answer_later(sender, req, 0, g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0));
    g_free(req);
    return;
  }
  if (g_str_equal(method, "Start")) {
    g_autoptr(GVariant) options = g_variant_get_child_value(params, 2);
    char *req = request_for(sender, options);
    g_dbus_method_invocation_return_value(inv, g_variant_new("(o)", req));
    const int code = env_int("PORTAL_START_CODE") < 0 ? 0 : env_int("PORTAL_START_CODE");
    // The streams ride even a cancelled answer, so only the code says no.
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&props, "{sv}", "size", g_variant_new("(ii)", 640, 480));
    GVariantBuilder streams;
    g_variant_builder_init(&streams, G_VARIANT_TYPE("a(ua{sv})"));
    g_variant_builder_add(&streams, "(ua{sv})", (guint32)env_int("PORTAL_NODE"), &props);
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&b, "{sv}", "streams", g_variant_builder_end(&streams));
    answer_later(sender, req, (guint32)code, g_variant_builder_end(&b));
    g_free(req);
    if (code == 0 && env_int("PORTAL_CLOSE_AFTER") >= 0) {
      g_timeout_add_seconds((guint)env_int("PORTAL_CLOSE_AFTER"), emit_closed, NULL);
    }
    return;
  }
  if (g_str_equal(method, "OpenPipeWireRemote")) {
    int fd = pipewire_socket();
    if (fd < 0) {
      g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.Failed",
                                                 "no pipewire");
      return;
    }
    g_autoptr(GUnixFDList) fds = g_unix_fd_list_new();
    int index = g_unix_fd_list_append(fds, fd, NULL);
    close(fd);
    g_dbus_method_invocation_return_value_with_unix_fd_list(inv, g_variant_new("(h)", index),
                                                             fds);
    return;
  }
  g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.UnknownMethod",
                                             method);
}

static GVariant *get(GDBusConnection *c, const char *sender, const char *path, const char *iface,
                     const char *prop, GError **error, gpointer ud) {
  (void)c;
  (void)sender;
  (void)path;
  (void)iface;
  (void)error;
  (void)ud;
  if (g_str_equal(prop, "AvailableSourceTypes")) return g_variant_new_uint32(3);
  if (g_str_equal(prop, "AvailableCursorModes")) return g_variant_new_uint32(7);
  return g_variant_new_uint32(5);
}

static const GDBusInterfaceVTable vtable = {call, get, NULL, {0}};

static const GDBusInterfaceVTable *vtable_ref(void) { return &vtable; }

int main(void) {
  info = g_dbus_node_info_new_for_xml(kXml, NULL);
  bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
  if (bus == NULL) return 1;
  expose("/org/freedesktop/portal/desktop", 0);
  g_bus_own_name_on_connection(bus, "org.freedesktop.portal.Desktop",
                               G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
  printf("portal: ready\n");
  fflush(stdout);
  g_main_loop_run(g_main_loop_new(NULL, FALSE));
  return 0;
}
