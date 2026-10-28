// Drives the Linux runner's `screen_share` channel (SHARE-018) as Dart does,
// through a fake binary messenger: start, frame pulls, stop, and the
// desktop's own Stop. The source under test is included whole
// (SCREEN_SHARE_SOURCE), so check.sh can build it from a planted mistake.
//
//   harness share|declined|desktop_stops
#include <gdk/gdk.h>
// No window to parent the portal's dialog to.
#undef GDK_WINDOWING_X11
#include SCREEN_SHARE_SOURCE

#include <cstdio>
#include <deque>
#include <string>

G_DECLARE_FINAL_TYPE(FakeMessenger, fake_messenger, FAKE, MESSENGER, GObject)

struct _FakeMessenger {
  GObject parent_instance;
  FlBinaryMessengerMessageHandler handler;
  gpointer handler_data;
  std::deque<GBytes*>* responses;
  int invoked;
};

static void fake_messenger_iface_init(FlBinaryMessengerInterface* iface);

G_DEFINE_TYPE_WITH_CODE(FakeMessenger, fake_messenger, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(fl_binary_messenger_get_type(),
                                              fake_messenger_iface_init))

static void set_handler(FlBinaryMessenger* m, const gchar*,
                        FlBinaryMessengerMessageHandler handler,
                        gpointer user_data, GDestroyNotify) {
  FAKE_MESSENGER(m)->handler = handler;
  FAKE_MESSENGER(m)->handler_data = user_data;
}

static gboolean send_response(FlBinaryMessenger* m,
                              FlBinaryMessengerResponseHandle*,
                              GBytes* response, GError**) {
  FAKE_MESSENGER(m)->responses->push_back(g_bytes_ref(response));
  return TRUE;
}

// The runner's one call into Dart is `ended`.
static void send_on_channel(FlBinaryMessenger* m, const gchar*, GBytes*,
                            GCancellable*, GAsyncReadyCallback, gpointer) {
  FAKE_MESSENGER(m)->invoked++;
}

static GBytes* send_finish(FlBinaryMessenger*, GAsyncResult*, GError**) {
  return nullptr;
}
static void resize_channel(FlBinaryMessenger*, const gchar*, int64_t) {}
static void set_warns(FlBinaryMessenger*, const gchar*, bool) {}
static void shutdown_messenger(FlBinaryMessenger*) {}

static void fake_messenger_iface_init(FlBinaryMessengerInterface* iface) {
  iface->set_message_handler_on_channel = set_handler;
  iface->send_response = send_response;
  iface->send_on_channel = send_on_channel;
  iface->send_on_channel_finish = send_finish;
  iface->resize_channel = resize_channel;
  iface->set_warns_on_channel_overflow = set_warns;
  iface->shutdown = shutdown_messenger;
}

static void fake_messenger_class_init(FakeMessengerClass*) {}
static void fake_messenger_init(FakeMessenger*) {}

static FakeMessenger* messenger;
static FlStandardMessageCodec* codec;
static int failures = 0;

static void check(bool ok, const char* what) {
  printf("%s %s\n", ok ? "PASS" : "FAIL", what);
  if (!ok) failures++;
}

static GBytes* encode(FlValue* value) {
  g_autoptr(GError) error = nullptr;
  return fl_message_codec_encode_message(FL_MESSAGE_CODEC(codec), value,
                                         &error);
}

// Sends a method call (its name, then its arguments, each a standard-codec
// value) and runs the main loop until it is answered or [timeout_s] passes.
static FlValue* call(const char* method, FlValue* args, int timeout_s) {
  g_autoptr(FlValue) owned_args = args;
  g_autoptr(FlValue) name = fl_value_new_string(method);
  g_autoptr(GBytes) a = encode(name);
  g_autoptr(GBytes) b = encode(owned_args);
  GByteArray* joined = g_byte_array_new();
  gsize n = 0;
  const guint8* d = static_cast<const guint8*>(g_bytes_get_data(a, &n));
  g_byte_array_append(joined, d, n);
  d = static_cast<const guint8*>(g_bytes_get_data(b, &n));
  g_byte_array_append(joined, d, n);
  g_autoptr(GBytes) message = g_byte_array_free_to_bytes(joined);
  const size_t before = messenger->responses->size();
  g_autoptr(FlBinaryMessengerResponseHandle) handle =
      FL_BINARY_MESSENGER_RESPONSE_HANDLE(g_object_new(
          fl_binary_messenger_response_handle_get_type(), nullptr));
  messenger->handler(FL_BINARY_MESSENGER(messenger), kChannel, message, handle,
                     messenger->handler_data);
  const gint64 until = g_get_monotonic_time() + timeout_s * G_USEC_PER_SEC;
  while (messenger->responses->size() == before &&
         g_get_monotonic_time() < until) {
    g_main_context_iteration(nullptr, TRUE);
  }
  if (messenger->responses->size() == before) return nullptr;
  GBytes* response = messenger->responses->back();
  d = static_cast<const guint8*>(g_bytes_get_data(response, &n));
  if (n < 1 || d[0] != 0) return nullptr;
  g_autoptr(GBytes) value = g_bytes_new(d + 1, n - 1);
  g_autoptr(GError) error = nullptr;
  return fl_message_codec_decode_message(FL_MESSAGE_CODEC(codec), value,
                                         &error);
}

static void spin(int ms) {
  const gint64 until = g_get_monotonic_time() + ms * 1000;
  while (g_get_monotonic_time() < until) {
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(1000);
  }
}

static FlValue* start_args() {
  FlValue* args = fl_value_new_map();
  fl_value_set_string_take(args, "maxWidth", fl_value_new_int(0));
  fl_value_set_string_take(args, "maxHeight", fl_value_new_int(0));
  fl_value_set_string_take(args, "maxLongSide", fl_value_new_int(1280));
  fl_value_set_string_take(args, "fps", fl_value_new_int(5));
  return args;
}

static FlValue* frame_args(int after) {
  FlValue* args = fl_value_new_map();
  fl_value_set_string_take(args, "after", fl_value_new_int(after));
  return args;
}

static bool is_map(FlValue* v) {
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_MAP;
}

static bool ended(FlValue* v) {
  return is_map(v) && fl_value_lookup_string(v, "ended") != nullptr;
}

// The source is videotestsrc's SMPTE bars; the second of seven is yellow:
// red and green high, blue low. A swapped channel order makes it cyan.
static bool second_bar_is_yellow(FlValue* jpeg) {
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  if (!gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(jpeg),
                               fl_value_get_length(jpeg), nullptr) ||
      !gdk_pixbuf_loader_close(loader, nullptr)) {
    return false;
  }
  GdkPixbuf* image = gdk_pixbuf_loader_get_pixbuf(loader);
  const int x = gdk_pixbuf_get_width(image) * 3 / 14;
  const int y = gdk_pixbuf_get_height(image) / 4;
  const guchar* p = gdk_pixbuf_get_pixels(image) +
                    y * gdk_pixbuf_get_rowstride(image) +
                    x * gdk_pixbuf_get_n_channels(image);
  printf("second bar r=%d g=%d b=%d\n", p[0], p[1], p[2]);
  return p[0] > 160 && p[1] > 160 && p[2] < 96;
}

struct Pulled {
  int frames = 0;
  int last_seq = 0;
  bool newer_each_time = true;
  bool ended = false;
  bool yellow = false;
  double rate = 0;
};

// Pulls frames as the shim does, each after the last it got, for [seconds].
static Pulled pull(int seconds) {
  Pulled pulled;
  gint64 first_at = 0;
  const gint64 until = g_get_monotonic_time() + seconds * G_USEC_PER_SEC;
  while (g_get_monotonic_time() < until) {
    g_autoptr(FlValue) f = call("frame", frame_args(pulled.last_seq), 5);
    if (!is_map(f)) break;
    if (ended(f)) {
      pulled.ended = true;
      break;
    }
    const int seq =
        static_cast<int>(fl_value_get_int(fl_value_lookup_string(f, "seq")));
    FlValue* jpeg = fl_value_lookup_string(f, "jpeg");
    if (jpeg != nullptr) {
      if (seq <= pulled.last_seq) pulled.newer_each_time = false;
      if (pulled.frames++ == 0) {
        first_at = g_get_monotonic_time();
        pulled.yellow = second_bar_is_yellow(jpeg);
      }
    }
    pulled.last_seq = seq;
  }
  const double elapsed =
      first_at == 0 ? 0 : (g_get_monotonic_time() - first_at) / 1e6;
  pulled.rate = elapsed > 0 ? (pulled.frames - 1) / elapsed : 0;
  printf("%d frames, %.1f a second\n", pulled.frames, pulled.rate);
  return pulled;
}

int main(int argc, char** argv) {
  const std::string scenario = argc > 1 ? argv[1] : "share";
  messenger = FAKE_MESSENGER(g_object_new(fake_messenger_get_type(), nullptr));
  messenger->responses = new std::deque<GBytes*>();
  codec = fl_standard_message_codec_new();
  g_autoptr(FlStandardMethodCodec) method_codec =
      fl_standard_method_codec_new();
  FlMethodChannel* channel =
      fl_method_channel_new(FL_BINARY_MESSENGER(messenger), kChannel,
                            FL_METHOD_CODEC(method_codec));
  Host* host = new Host(nullptr, channel);
  fl_method_channel_set_method_call_handler(channel, method_call_cb, host,
                                            nullptr);

  g_autoptr(FlValue) started = call("start", start_args(), 20);
  if (scenario == "declined") {
    check(started != nullptr &&
              fl_value_get_type(started) == FL_VALUE_TYPE_NULL,
          "a cancelled dialog answers start with null");
    g_autoptr(FlValue) f = call("frame", frame_args(0), 5);
    check(ended(f), "and a pull reads that no share runs");
  } else {
    check(is_map(started), "a picked source answers start with a size");
    if (!is_map(started)) {
      delete host;
      return 1;
    }
    check(fl_value_get_int(fl_value_lookup_string(started, "width")) == 640 &&
              fl_value_get_int(fl_value_lookup_string(started, "height")) ==
                  480,
          "the size is the stream's, under the cap");
    if (scenario == "desktop_stops") {
      const Pulled pulled = pull(6);
      check(pulled.frames > 0, "frames arrive before the desktop's Stop");
      check(pulled.ended, "the desktop's Stop ends the pulls");
      spin(300);
      check(messenger->invoked == 1, "and Dart is told the share ended");
    } else {
      const Pulled pulled = pull(5);
      check(!pulled.ended, "the share runs until stopped");
      check(pulled.newer_each_time, "each frame is newer than the last");
      check(pulled.yellow, "the colours are the screen's");
      check(pulled.frames >= 10 && pulled.rate < 7,
            "frames keep coming at the asked 5 a second, not the source's 30");
      g_autoptr(FlValue) stopped = call("stop", nullptr, 5);
      check(stopped != nullptr, "stop is answered");
      g_autoptr(FlValue) after = call("frame", frame_args(0), 5);
      check(ended(after), "after stop a pull reads ended");
      check(messenger->invoked == 0, "a stop Dart asked for is not told back");
      g_autoptr(FlValue) again = call("start", start_args(), 20);
      check(is_map(again), "a second share starts");
      g_autoptr(FlValue) frame = call("frame", frame_args(0), 5);
      check(is_map(frame) && fl_value_lookup_string(frame, "jpeg") != nullptr,
            "and streams");
    }
  }
  delete host;
  spin(300);
  printf("%s\n", failures == 0 ? "ALL PASS" : "FAILED");
  return failures == 0 ? 0 : 1;
}
