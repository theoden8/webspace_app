#include "screen_share.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>

namespace {

constexpr char kChannel[] = "org.codeberg.theoden8.webspace/screen_share";
constexpr char kPortalBus[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
constexpr char kScreenCast[] = "org.freedesktop.portal.ScreenCast";
constexpr char kRequest[] = "org.freedesktop.portal.Request";
constexpr char kSession[] = "org.freedesktop.portal.Session";

// ScreenCast's source types and cursor modes, as the portal numbers them.
constexpr guint32 kMonitor = 1;
constexpr guint32 kWindow = 2;
constexpr guint32 kCursorEmbedded = 2;

constexpr guint kPullWaitMs = 1500;
// From the portal's yes to the stream's first format.
constexpr guint kStreamWaitMs = 10000;
constexpr char kJpegQuality[] = "60";
// The largest side a stream may report, as the EnumFormat offers it.
constexpr uint32_t kMaxSide = 8192;

struct Request {
  int max_width;
  int max_height;
  int max_long_side;
  int fps;
};

struct Size {
  int width;
  int height;
};

// The source scaled down, never up, to the page's caps and the app's
// long-side cap, in even pixels for the video encoder the page feeds it to.
// The same rule as `ScreenShareService.fit` on Android.
Size fit(Size source, const Request& request) {
  double scale = 1.0;
  const int long_side = std::max(source.width, source.height);
  if (request.max_long_side > 0 && request.max_long_side < long_side) {
    scale = std::min(scale,
                     static_cast<double>(request.max_long_side) / long_side);
  }
  if (request.max_width > 0 && request.max_width < source.width) {
    scale =
        std::min(scale, static_cast<double>(request.max_width) / source.width);
  }
  if (request.max_height > 0 && request.max_height < source.height) {
    scale = std::min(scale,
                     static_cast<double>(request.max_height) / source.height);
  }
  auto even = [](double v) {
    return std::max(2, static_cast<int>(std::lround(v)) / 2 * 2);
  };
  return {even(source.width * scale), even(source.height * scale)};
}

// What the PipeWire thread tells the main thread about the stream it runs,
// numbered with its share so a word about an ended share is dropped.
struct Word {
  enum Kind { kReady, kFrame, kGone } kind;
  guint64 share;
  Size size;
  int seq;
  GBytes* jpeg;
};

gboolean deliver(gpointer data);

void forget(gpointer data) {
  Word* word = static_cast<Word*>(data);
  if (word->jpeg != nullptr) g_bytes_unref(word->jpeg);
  delete word;
}

// Always through an idle source, never run in place, so a word sent while
// the main thread is opening or closing the stream waits until it is done.
void tell(Word* word) {
  g_idle_add_full(G_PRIORITY_DEFAULT, deliver, word, forget);
}

// One PipeWire stream of the node the portal handed over, on a thread loop
// of its own. Every field is read and written on that thread, or by the
// main thread while it holds the loop's lock, which is how the stream is
// opened and closed (BUG-007: one monitor).
class Stream {
 public:
  Stream(guint64 share, const Request& request)
      : share_(share),
        request_(request),
        interval_us_(G_USEC_PER_SEC / std::max(1, request.fps)) {}
  ~Stream();

  // Takes [fd], the portal's PipeWire remote.
  bool open(int fd, uint32_t node);

 private:
  static void on_core_error(void* data, uint32_t id, int seq, int res,
                            const char* message);
  static void on_state_changed(void* data, enum pw_stream_state old,
                               enum pw_stream_state state, const char* error);
  static void on_param_changed(void* data, uint32_t id,
                               const struct spa_pod* param);
  static void on_process(void* data);
  static void on_timer(void* data, uint64_t expirations);

  bool connect(int fd, uint32_t node);
  void negotiated(const struct spa_pod* param);
  void take(const struct spa_buffer* buffer);
  void schedule();
  void encode();
  void gone();

  const guint64 share_;
  const Request request_;
  const gint64 interval_us_;
  struct pw_thread_loop* loop_ = nullptr;
  struct pw_context* context_ = nullptr;
  struct pw_core* core_ = nullptr;
  struct pw_stream* stream_ = nullptr;
  struct spa_source* timer_ = nullptr;
  struct spa_hook core_listener_ = {};
  struct spa_hook stream_listener_ = {};

  // The negotiated format: its size and where red, green and blue sit in
  // each four-byte pixel.
  Size source_ = {0, 0};
  int red_ = 0;
  int green_ = 1;
  int blue_ = 2;
  // The size frames go to the page at, fixed by the first format.
  Size out_ = {0, 0};
  // The newest frame as RGB at its own size, and that frame scaled into
  // [out_] when the two differ.
  GdkPixbuf* held_ = nullptr;
  GdkPixbuf* scaled_ = nullptr;
  bool fresh_ = false;
  bool scheduled_ = false;
  bool told_gone_ = false;
  gint64 last_at_ = 0;
  int seq_ = 0;
};

Stream::~Stream() {
  if (loop_ != nullptr) {
    pw_thread_loop_lock(loop_);
    if (timer_ != nullptr) {
      pw_loop_destroy_source(pw_thread_loop_get_loop(loop_), timer_);
    }
    if (stream_ != nullptr) {
      spa_hook_remove(&stream_listener_);
      pw_stream_disconnect(stream_);
      pw_stream_destroy(stream_);
    }
    if (core_ != nullptr) {
      spa_hook_remove(&core_listener_);
      pw_core_disconnect(core_);
    }
    pw_thread_loop_unlock(loop_);
    pw_thread_loop_stop(loop_);
  }
  if (context_ != nullptr) pw_context_destroy(context_);
  if (loop_ != nullptr) pw_thread_loop_destroy(loop_);
  g_clear_object(&held_);
  g_clear_object(&scaled_);
}

bool Stream::open(int fd, uint32_t node) {
  static const bool initialized = (pw_init(nullptr, nullptr), true);
  (void)initialized;
  loop_ = pw_thread_loop_new("webspace-screen-share", nullptr);
  if (loop_ != nullptr) {
    context_ = pw_context_new(pw_thread_loop_get_loop(loop_), nullptr, 0);
  }
  if (context_ == nullptr || pw_thread_loop_start(loop_) < 0) {
    close(fd);
    return false;
  }
  pw_thread_loop_lock(loop_);
  const bool connected = connect(fd, node);
  pw_thread_loop_unlock(loop_);
  return connected;
}

bool Stream::connect(int fd, uint32_t node) {
  static const struct pw_core_events core_events = [] {
    struct pw_core_events events = {};
    events.version = PW_VERSION_CORE_EVENTS;
    events.error = on_core_error;
    return events;
  }();
  static const struct pw_stream_events stream_events = [] {
    struct pw_stream_events events = {};
    events.version = PW_VERSION_STREAM_EVENTS;
    events.state_changed = on_state_changed;
    events.param_changed = on_param_changed;
    events.process = on_process;
    return events;
  }();

  core_ = pw_context_connect_fd(context_, fd, nullptr, 0);
  if (core_ == nullptr) return false;
  pw_core_add_listener(core_, &core_listener_, &core_events, this);
  stream_ = pw_stream_new(
      core_, "webspace-screen-share",
      // Only the node the user picked: never linked again to another
      // source when that one goes.
      pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY,
                        "Capture", PW_KEY_MEDIA_ROLE, "Screen",
                        PW_KEY_NODE_DONT_RECONNECT, "true", nullptr));
  if (stream_ == nullptr) return false;
  pw_stream_add_listener(stream_, &stream_listener_, &stream_events, this);
  timer_ = pw_loop_add_timer(pw_thread_loop_get_loop(loop_), on_timer, this);
  if (timer_ == nullptr) return false;

  uint8_t buffer[1024];
  struct spa_pod_builder builder;
  spa_pod_builder_init(&builder, buffer, sizeof(buffer));
  struct spa_rectangle min_size = {1, 1};
  struct spa_rectangle default_size = {1920, 1080};
  struct spa_rectangle max_size = {kMaxSide, kMaxSide};
  struct spa_fraction no_rate = {0, 1};
  struct spa_fraction min_rate = {1, 1};
  struct spa_fraction asked_rate = {static_cast<uint32_t>(request_.fps), 1};
  struct spa_fraction max_rate = {360, 1};
  struct spa_pod_frame frame;
  spa_pod_builder_push_object(&builder, &frame, SPA_TYPE_OBJECT_Format,
                              SPA_PARAM_EnumFormat);
  // Only formats with no modifier, so the compositor sends memory this
  // process can read rather than a GPU buffer. Any frame rate is taken, a
  // compositor's variable one or a source's fixed one, and the asked rate
  // only suggested: the encoder holds frames to it either way.
  spa_pod_builder_add(
      &builder, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
      SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
      SPA_FORMAT_VIDEO_format,
      SPA_POD_CHOICE_ENUM_Id(9, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
                             SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx,
                             SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_xRGB,
                             SPA_VIDEO_FORMAT_ARGB, SPA_VIDEO_FORMAT_xBGR,
                             SPA_VIDEO_FORMAT_ABGR),
      SPA_FORMAT_VIDEO_size,
      SPA_POD_CHOICE_RANGE_Rectangle(&default_size, &min_size, &max_size),
      SPA_FORMAT_VIDEO_framerate,
      SPA_POD_CHOICE_RANGE_Fraction(&no_rate, &no_rate, &max_rate),
      SPA_FORMAT_VIDEO_maxFramerate,
      SPA_POD_CHOICE_RANGE_Fraction(&asked_rate, &min_rate, &max_rate), 0);
  const struct spa_pod* params[] = {
      static_cast<const spa_pod*>(spa_pod_builder_pop(&builder, &frame))};
  return pw_stream_connect(stream_, PW_DIRECTION_INPUT, node,
                           static_cast<enum pw_stream_flags>(
                               PW_STREAM_FLAG_AUTOCONNECT |
                               PW_STREAM_FLAG_MAP_BUFFERS),
                           params, 1) == 0;
}

void Stream::on_core_error(void* data, uint32_t id, int /*seq*/, int res,
                           const char* message) {
  if (id != PW_ID_CORE) return;
  g_warning("Screen share: PipeWire error %d: %s", res, message);
  static_cast<Stream*>(data)->gone();
}

void Stream::on_state_changed(void* data, enum pw_stream_state old,
                              enum pw_stream_state state, const char* error) {
  if (state == PW_STREAM_STATE_ERROR) {
    g_warning("Screen share: PipeWire stream failed: %s", error);
  }
  if (state == PW_STREAM_STATE_ERROR ||
      (state == PW_STREAM_STATE_UNCONNECTED &&
       old != PW_STREAM_STATE_UNCONNECTED)) {
    static_cast<Stream*>(data)->gone();
  }
}

void Stream::on_param_changed(void* data, uint32_t id,
                              const struct spa_pod* param) {
  if (param == nullptr || id != SPA_PARAM_Format) return;
  static_cast<Stream*>(data)->negotiated(param);
}

void Stream::negotiated(const struct spa_pod* param) {
  uint32_t media_type = 0;
  uint32_t media_subtype = 0;
  struct spa_video_info_raw info = {};
  if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
      media_type != SPA_MEDIA_TYPE_video ||
      media_subtype != SPA_MEDIA_SUBTYPE_raw ||
      spa_format_video_raw_parse(param, &info) < 0) {
    return;
  }
  switch (info.format) {
    case SPA_VIDEO_FORMAT_RGBx:
    case SPA_VIDEO_FORMAT_RGBA:
      red_ = 0, green_ = 1, blue_ = 2;
      break;
    case SPA_VIDEO_FORMAT_BGRx:
    case SPA_VIDEO_FORMAT_BGRA:
      red_ = 2, green_ = 1, blue_ = 0;
      break;
    case SPA_VIDEO_FORMAT_xRGB:
    case SPA_VIDEO_FORMAT_ARGB:
      red_ = 1, green_ = 2, blue_ = 3;
      break;
    case SPA_VIDEO_FORMAT_xBGR:
    case SPA_VIDEO_FORMAT_ABGR:
      red_ = 3, green_ = 2, blue_ = 1;
      break;
    default:
      return;
  }
  if (info.size.width < 1 || info.size.width > kMaxSide ||
      info.size.height < 1 || info.size.height > kMaxSide) {
    return;
  }
  source_ = {static_cast<int>(info.size.width),
             static_cast<int>(info.size.height)};

  uint8_t buffer[256];
  struct spa_pod_builder builder;
  spa_pod_builder_init(&builder, buffer, sizeof(buffer));
  struct spa_pod_frame frame;
  spa_pod_builder_push_object(&builder, &frame, SPA_TYPE_OBJECT_ParamBuffers,
                              SPA_PARAM_Buffers);
  spa_pod_builder_add(&builder, SPA_PARAM_BUFFERS_dataType,
                      SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) |
                                               (1 << SPA_DATA_MemFd)),
                      0);
  const struct spa_pod* params[] = {
      static_cast<const spa_pod*>(spa_pod_builder_pop(&builder, &frame))};
  pw_stream_update_params(stream_, params, 1);

  if (out_.width == 0) {
    out_ = fit(source_, request_);
    tell(new Word{Word::kReady, share_, out_, 0, nullptr});
  }
}

void Stream::on_process(void* data) {
  Stream* self = static_cast<Stream*>(data);
  struct pw_buffer* newest = nullptr;
  while (struct pw_buffer* next = pw_stream_dequeue_buffer(self->stream_)) {
    if (newest != nullptr) pw_stream_queue_buffer(self->stream_, newest);
    newest = next;
  }
  if (newest == nullptr) return;
  self->take(newest->buffer);
  pw_stream_queue_buffer(self->stream_, newest);
  self->schedule();
}

// Copies the buffer's pixels out as RGB, since the buffer goes back to the
// compositor before the frame is encoded.
void Stream::take(const struct spa_buffer* buffer) {
  if (source_.width <= 0 || buffer->n_datas < 1) return;
  const struct spa_data& data = buffer->datas[0];
  if (data.data == nullptr || data.chunk == nullptr) return;
  // The chunk is memory the producer shares and may rewrite while it is
  // read: each field is read once, and only that copy is checked and used.
  const uint32_t offset = __atomic_load_n(&data.chunk->offset, __ATOMIC_RELAXED);
  const uint32_t size = __atomic_load_n(&data.chunk->size, __ATOMIC_RELAXED);
  const int32_t chunk_stride =
      __atomic_load_n(&data.chunk->stride, __ATOMIC_RELAXED);
  const int32_t flags = __atomic_load_n(&data.chunk->flags, __ATOMIC_RELAXED);
  if ((flags & SPA_CHUNK_FLAG_CORRUPTED) != 0 || size == 0) return;
  const int width = source_.width;
  const int height = source_.height;
  const int64_t row = static_cast<int64_t>(width) * 4;
  const int64_t stride = chunk_stride != 0 ? chunk_stride : row;
  if (stride < row) return;
  const uint64_t end = static_cast<uint64_t>(offset) +
                       static_cast<uint64_t>(stride) * (height - 1) +
                       static_cast<uint64_t>(row);
  if (end > data.maxsize) return;
  if (held_ == nullptr || gdk_pixbuf_get_width(held_) != width ||
      gdk_pixbuf_get_height(held_) != height) {
    g_clear_object(&held_);
    held_ = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, width, height);
    if (held_ == nullptr) return;
  }
  const uint8_t* source = static_cast<const uint8_t*>(data.data) + offset;
  guchar* pixels = gdk_pixbuf_get_pixels(held_);
  const int rowstride = gdk_pixbuf_get_rowstride(held_);
  for (int y = 0; y < height; y++) {
    const uint8_t* s = source + static_cast<size_t>(y) * stride;
    guchar* d = pixels + static_cast<size_t>(y) * rowstride;
    for (int x = 0; x < width; x++, s += 4, d += 3) {
      d[0] = s[red_];
      d[1] = s[green_];
      d[2] = s[blue_];
    }
  }
  fresh_ = true;
}

// Encodes the newest frame at most [fps] times a second. A frame that
// arrives sooner waits for its turn rather than being dropped, so the last
// change on a screen that then goes still is still sent.
void Stream::schedule() {
  if (!fresh_ || scheduled_) return;
  const gint64 due = last_at_ + interval_us_;
  const gint64 now = g_get_monotonic_time();
  if (now >= due) {
    encode();
    return;
  }
  const gint64 wait = due - now;
  struct timespec value = {static_cast<time_t>(wait / G_USEC_PER_SEC),
                           static_cast<long>((wait % G_USEC_PER_SEC) * 1000)};
  pw_loop_update_timer(pw_thread_loop_get_loop(loop_), timer_, &value,
                       nullptr, false);
  scheduled_ = true;
}

void Stream::on_timer(void* data, uint64_t /*expirations*/) {
  Stream* self = static_cast<Stream*>(data);
  self->scheduled_ = false;
  self->encode();
}

void Stream::encode() {
  if (!fresh_ || held_ == nullptr) return;
  fresh_ = false;
  last_at_ = g_get_monotonic_time();
  GdkPixbuf* frame = held_;
  const int width = gdk_pixbuf_get_width(held_);
  const int height = gdk_pixbuf_get_height(held_);
  if (width != out_.width || height != out_.height) {
    if (scaled_ == nullptr) {
      scaled_ = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, out_.width,
                               out_.height);
      if (scaled_ == nullptr) return;
    }
    // The page's surface keeps the size it started at, so a window
    // resized while shared is letterboxed into it.
    const double scale =
        std::min(static_cast<double>(out_.width) / width,
                 static_cast<double>(out_.height) / height);
    const int w = std::max(
        1, std::min(out_.width, static_cast<int>(std::lround(width * scale))));
    const int h = std::max(
        1,
        std::min(out_.height, static_cast<int>(std::lround(height * scale))));
    const int x = (out_.width - w) / 2;
    const int y = (out_.height - h) / 2;
    gdk_pixbuf_fill(scaled_, 0x000000ff);
    gdk_pixbuf_scale(held_, scaled_, x, y, w, h, x, y, scale, scale,
                     GDK_INTERP_BILINEAR);
    frame = scaled_;
  }
  gchar* jpeg = nullptr;
  gsize length = 0;
  g_autoptr(GError) error = nullptr;
  if (!gdk_pixbuf_save_to_buffer(frame, &jpeg, &length, "jpeg", &error,
                                 "quality", kJpegQuality, nullptr)) {
    g_warning("Screen share: JPEG encoding failed: %s", error->message);
    return;
  }
  tell(new Word{Word::kFrame, share_, out_, ++seq_,
                g_bytes_new_take(jpeg, length)});
}

void Stream::gone() {
  if (told_gone_) return;
  told_gone_ = true;
  tell(new Word{Word::kGone, share_, {0, 0}, 0, nullptr});
}

// The window the portal's dialog belongs to, where the display server lets
// a client name it without an export round trip.
std::string parent_window(GtkWidget* widget) {
#ifdef GDK_WINDOWING_X11
  GdkWindow* window = gtk_widget_get_window(gtk_widget_get_toplevel(widget));
  if (window != nullptr && GDK_IS_X11_WINDOW(window)) {
    gchar* handle = g_strdup_printf(
        "x11:%lx", static_cast<unsigned long>(gdk_x11_window_get_xid(window)));
    std::string name(handle);
    g_free(handle);
    return name;
  }
#endif
  return "";
}

// The channel's side of a share, on the main thread only: the portal
// session as it is asked for, the stream once the portal hands it over, and
// the frames the page pulls.
class Host {
 public:
  Host(FlView* view, FlMethodChannel* channel);
  ~Host();

  void handle(FlMethodCall* call);
  void heard(const Word& word);

 private:
  // Where a share is: each step waits on one portal call or reply.
  enum class Step { kProperties, kCreate, kSelect, kStart, kRemote, kStream };

  struct Share {
    guint64 id = 0;
    Request request = {0, 0, 0, 0};
    // The Dart call waiting for the share to start, null once answered.
    FlMethodCall* start = nullptr;
    // Cancelled when the share ends, so no reply of the portal's reaches
    // a share that is gone.
    GCancellable* cancellable = nullptr;
    Step step = Step::kProperties;
    guint32 source_types = 0;
    guint32 cursor_modes = 0;
    guint32 version = 0;
    // The Request object whose Response the share waits on.
    std::string request_path;
    guint response = 0;
    std::string expected_session;
    std::string session;
    guint closed = 0;
    guint32 node = 0;
    guint stream_wait = 0;
    std::unique_ptr<Stream> stream;
    bool live = false;
  };

  // A portal call answered by a Request object, and the object's path.
  struct Asked {
    Host* host;
    std::string path;
  };

  static void on_properties(GObject* source, GAsyncResult* result,
                            gpointer user_data);
  static void on_asked(GObject* source, GAsyncResult* result,
                       gpointer user_data);
  static void on_remote(GObject* source, GAsyncResult* result,
                        gpointer user_data);
  static void on_response(GDBusConnection* bus, const gchar* sender,
                          const gchar* path, const gchar* interface,
                          const gchar* signal, GVariant* parameters,
                          gpointer user_data);
  static void on_closed(GDBusConnection* bus, const gchar* sender,
                        const gchar* path, const gchar* interface,
                        const gchar* signal, GVariant* parameters,
                        gpointer user_data);
  static gboolean on_stream_wait(gpointer user_data);
  static gboolean on_pull_wait(gpointer user_data);

  void start(FlMethodCall* call);
  void create_session(GVariant* properties);
  void select_sources();
  void start_capture();
  void answered(guint32 code, GVariant* results);
  void open_remote();
  void stream_from(int fd);
  void ask(Step step, const char* method, GVariant* parameters,
           const std::string& token);
  void listen(const std::string& path);
  void answer_start(FlValue* reply);
  void fail(const char* why);
  void end(bool notify);

  void frame(FlMethodCall* call);
  void offer(int seq, GBytes* jpeg);
  void answer_waiting(FlValue* reply);

  std::string next_token();
  std::string request_path(const std::string& token) const;
  std::string portal_path(const char* kind, const std::string& token) const;

  FlView* view_;
  FlMethodChannel* channel_;
  GDBusConnection* bus_ = nullptr;
  std::unique_ptr<Share> share_;
  guint64 shares_ = 0;
  guint tokens_ = 0;

  // The newest frame of the live share, and the page's pull waiting for one
  // after [waiting_after_].
  GBytes* latest_ = nullptr;
  int latest_seq_ = 0;
  FlMethodCall* waiting_ = nullptr;
  int waiting_after_ = 0;
  guint waiting_timer_ = 0;
};

Host* the_host = nullptr;

gboolean deliver(gpointer data) {
  if (the_host != nullptr) the_host->heard(*static_cast<Word*>(data));
  return G_SOURCE_REMOVE;
}

int int_arg(FlValue* args, const char* key, int fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT
             ? static_cast<int>(fl_value_get_int(value))
             : fallback;
}

void respond(FlMethodCall* call, FlValue* reply) {
  g_autoptr(FlValue) owned = reply;
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(call, owned, &error)) {
    g_warning("Failed to answer screen_share: %s", error->message);
  }
}

FlValue* ended_reply() {
  FlValue* reply = fl_value_new_map();
  fl_value_set_string_take(reply, "ended", fl_value_new_bool(TRUE));
  return reply;
}

FlValue* seq_reply(int seq) {
  FlValue* reply = fl_value_new_map();
  fl_value_set_string_take(reply, "seq", fl_value_new_int(seq));
  return reply;
}

FlValue* frame_reply(int seq, GBytes* jpeg) {
  FlValue* reply = seq_reply(seq);
  gsize length = 0;
  const uint8_t* bytes =
      static_cast<const uint8_t*>(g_bytes_get_data(jpeg, &length));
  fl_value_set_string_take(reply, "jpeg",
                           fl_value_new_uint8_list(bytes, length));
  return reply;
}

Host::Host(FlView* view, FlMethodChannel* channel)
    : view_(view), channel_(channel) {
  g_autoptr(GError) error = nullptr;
  bus_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus_ == nullptr) {
    g_warning("Screen share: no session bus: %s", error->message);
  }
  the_host = this;
}

Host::~Host() {
  end(false);
  answer_waiting(ended_reply());
  if (the_host == this) the_host = nullptr;
  g_clear_object(&bus_);
  g_object_unref(channel_);
}

void Host::handle(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "start") == 0) {
    start(call);
  } else if (g_strcmp0(method, "frame") == 0) {
    frame(call);
  } else if (g_strcmp0(method, "stop") == 0) {
    end(false);
    respond(call, nullptr);
  } else {
    g_autoptr(GError) error = nullptr;
    fl_method_call_respond_not_implemented(call, &error);
  }
}

// MARK: Starting

void Host::start(FlMethodCall* call) {
  if (share_ != nullptr && share_->start != nullptr) {
    respond(call, nullptr);
    return;
  }
  end(false);
  if (bus_ == nullptr) {
    respond(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  share_ = std::make_unique<Share>();
  share_->id = ++shares_;
  share_->request = {int_arg(args, "maxWidth", 0),
                     int_arg(args, "maxHeight", 0),
                     int_arg(args, "maxLongSide", 1280),
                     std::min(std::max(int_arg(args, "fps", 10), 1), 30)};
  share_->start = FL_METHOD_CALL(g_object_ref(call));
  share_->cancellable = g_cancellable_new();
  share_->step = Step::kProperties;
  g_dbus_connection_call(bus_, kPortalBus, kPortalPath,
                         "org.freedesktop.DBus.Properties", "GetAll",
                         g_variant_new("(s)", kScreenCast),
                         G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE, -1,
                         share_->cancellable, on_properties, this);
}

void Host::on_properties(GObject* source, GAsyncResult* result,
                         gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return;
  Host* host = static_cast<Host*>(user_data);
  if (reply == nullptr) {
    host->fail(error->message);
    return;
  }
  g_autoptr(GVariant) properties = g_variant_get_child_value(reply, 0);
  host->create_session(properties);
}

void Host::create_session(GVariant* properties) {
  g_variant_lookup(properties, "AvailableSourceTypes", "u",
                   &share_->source_types);
  g_variant_lookup(properties, "AvailableCursorModes", "u",
                   &share_->cursor_modes);
  g_variant_lookup(properties, "version", "u", &share_->version);
  const std::string token = next_token();
  const std::string session_token = next_token();
  share_->expected_session = portal_path("session", session_token);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "session_handle_token",
                        g_variant_new_string(session_token.c_str()));
  ask(Step::kCreate, "CreateSession", g_variant_new("(a{sv})", &options),
      token);
}

// One display or one window, which the portal's own dialog lets the user
// pick; that pick is the grant, and only for what was picked.
void Host::select_sources() {
  guint32 types = share_->source_types & (kMonitor | kWindow);
  if (types == 0) types = kMonitor;
  const std::string token = next_token();
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(types));
  g_variant_builder_add(&options, "{sv}", "multiple",
                        g_variant_new_boolean(FALSE));
  if (share_->version >= 2 && (share_->cursor_modes & kCursorEmbedded) != 0) {
    g_variant_builder_add(&options, "{sv}", "cursor_mode",
                          g_variant_new_uint32(kCursorEmbedded));
  }
  ask(Step::kSelect, "SelectSources",
      g_variant_new("(oa{sv})", share_->session.c_str(), &options), token);
}

void Host::start_capture() {
  const std::string token = next_token();
  const std::string parent = parent_window(GTK_WIDGET(view_));
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  ask(Step::kStart, "Start",
      g_variant_new("(osa{sv})", share_->session.c_str(), parent.c_str(),
                    &options),
      token);
}

// Listens on the Request object's path before the call goes out, so the
// portal's answer cannot arrive first.
void Host::ask(Step step, const char* method, GVariant* parameters,
               const std::string& token) {
  share_->step = step;
  const std::string path = request_path(token);
  listen(path);
  g_dbus_connection_call(bus_, kPortalBus, kPortalPath, kScreenCast, method,
                         parameters, G_VARIANT_TYPE("(o)"),
                         G_DBUS_CALL_FLAGS_NONE, -1, share_->cancellable,
                         on_asked, new Asked{this, path});
}

void Host::on_asked(GObject* source, GAsyncResult* result,
                    gpointer user_data) {
  std::unique_ptr<Asked> asked(static_cast<Asked*>(user_data));
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return;
  if (reply == nullptr) {
    asked->host->fail(error->message);
    return;
  }
  const gchar* path = nullptr;
  g_variant_get(reply, "(&o)", &path);
  // Every portal since handle_token answers on the path it names.
  if (asked->path != path) asked->host->fail("unexpected Request path");
}

void Host::listen(const std::string& path) {
  share_->request_path = path;
  share_->response = g_dbus_connection_signal_subscribe(
      bus_, kPortalBus, kRequest, "Response", path.c_str(), nullptr,
      G_DBUS_SIGNAL_FLAGS_NONE, on_response, this, nullptr);
}

void Host::on_response(GDBusConnection* /*bus*/, const gchar* /*sender*/,
                       const gchar* /*path*/, const gchar* /*interface*/,
                       const gchar* /*signal*/, GVariant* parameters,
                       gpointer user_data) {
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ua{sv})"))) return;
  guint32 code = 0;
  g_autoptr(GVariant) results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &code, &results);
  static_cast<Host*>(user_data)->answered(code, results);
}

void Host::answered(guint32 code, GVariant* results) {
  if (share_ == nullptr) return;
  g_dbus_connection_signal_unsubscribe(bus_, share_->response);
  share_->response = 0;
  if (code != 0) {
    fail(code == 1 ? "the user declined" : "the portal ended the request");
    return;
  }
  switch (share_->step) {
    case Step::kCreate: {
      const gchar* session = nullptr;
      if (!g_variant_lookup(results, "session_handle", "&s", &session) &&
          !g_variant_lookup(results, "session_handle", "&o", &session)) {
        fail("no session handle");
        return;
      }
      // Every later call names it as an object path: one the portal did
      // not make from this session's token is refused, not passed on.
      if (share_->expected_session != session) {
        fail("unexpected session handle");
        return;
      }
      share_->session = session;
      share_->closed = g_dbus_connection_signal_subscribe(
          bus_, kPortalBus, kSession, "Closed", share_->session.c_str(),
          nullptr, G_DBUS_SIGNAL_FLAGS_NONE, on_closed, this, nullptr);
      select_sources();
      return;
    }
    case Step::kSelect:
      start_capture();
      return;
    case Step::kStart: {
      g_autoptr(GVariant) streams = g_variant_lookup_value(
          results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
      if (streams == nullptr || g_variant_n_children(streams) < 1) {
        fail("nothing was picked");
        return;
      }
      g_autoptr(GVariant) properties = nullptr;
      g_variant_get_child(streams, 0, "(u@a{sv})", &share_->node, &properties);
      open_remote();
      return;
    }
    case Step::kProperties:
    case Step::kRemote:
    case Step::kStream:
      return;
  }
}

void Host::open_remote() {
  share_->step = Step::kRemote;
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_dbus_connection_call_with_unix_fd_list(
      bus_, kPortalBus, kPortalPath, kScreenCast, "OpenPipeWireRemote",
      g_variant_new("(oa{sv})", share_->session.c_str(), &options),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      share_->cancellable, on_remote, this);
}

void Host::on_remote(GObject* source, GAsyncResult* result,
                     gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  GUnixFDList* fds = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_finish(
      G_DBUS_CONNECTION(source), &fds, result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return;
  Host* host = static_cast<Host*>(user_data);
  if (reply == nullptr || fds == nullptr) {
    if (fds != nullptr) g_object_unref(fds);
    host->fail(error != nullptr ? error->message : "no PipeWire remote");
    return;
  }
  gint32 index = -1;
  g_variant_get(reply, "(h)", &index);
  const int fd = index >= 0 && index < g_unix_fd_list_get_length(fds)
                     ? g_unix_fd_list_get(fds, index, &error)
                     : -1;
  g_object_unref(fds);
  if (fd < 0) {
    host->fail(error != nullptr ? error->message : "no such fd in the reply");
    return;
  }
  host->stream_from(fd);
}

void Host::stream_from(int fd) {
  share_->step = Step::kStream;
  std::unique_ptr<Stream> stream(new Stream(share_->id, share_->request));
  if (!stream->open(fd, share_->node)) {
    fail("PipeWire refused the stream");
    return;
  }
  share_->stream = std::move(stream);
  share_->stream_wait = g_timeout_add(kStreamWaitMs, on_stream_wait, this);
}

gboolean Host::on_stream_wait(gpointer user_data) {
  Host* host = static_cast<Host*>(user_data);
  host->share_->stream_wait = 0;
  host->fail("the stream sent no picture");
  return G_SOURCE_REMOVE;
}

void Host::heard(const Word& word) {
  if (share_ == nullptr || share_->id != word.share) return;
  switch (word.kind) {
    case Word::kReady: {
      if (share_->start == nullptr) return;
      if (share_->stream_wait != 0) g_source_remove(share_->stream_wait);
      share_->stream_wait = 0;
      share_->live = true;
      FlValue* size = fl_value_new_map();
      fl_value_set_string_take(size, "width",
                               fl_value_new_int(word.size.width));
      fl_value_set_string_take(size, "height",
                               fl_value_new_int(word.size.height));
      answer_start(size);
      return;
    }
    case Word::kFrame:
      if (share_->live) offer(word.seq, word.jpeg);
      return;
    case Word::kGone:
      fail("the stream ended");
      return;
  }
}

void Host::answer_start(FlValue* reply) {
  FlMethodCall* call = share_->start;
  share_->start = nullptr;
  respond(call, reply);
  g_object_unref(call);
}

void Host::fail(const char* why) {
  g_debug("Screen share did not start or ended: %s", why);
  end(true);
}

// MARK: Ending

// Ends the share, if one runs or is being asked for. A share the user or
// the compositor ended is told to Dart with [notify]; one Dart ended is not.
void Host::end(bool notify) {
  if (share_ == nullptr) return;
  std::unique_ptr<Share> share = std::move(share_);
  g_cancellable_cancel(share->cancellable);
  g_object_unref(share->cancellable);
  if (share->response != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, share->response);
    // Takes down the portal's dialog, if it is still up.
    g_dbus_connection_call(bus_, kPortalBus, share->request_path.c_str(),
                           kRequest, "Close", nullptr, nullptr,
                           G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr,
                           nullptr);
  }
  if (share->closed != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, share->closed);
  }
  if (share->stream_wait != 0) g_source_remove(share->stream_wait);
  share->stream.reset();
  if (!share->session.empty()) {
    g_dbus_connection_call(bus_, kPortalBus, share->session.c_str(), kSession,
                           "Close", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE,
                           -1, nullptr, nullptr, nullptr);
  }
  if (share->start != nullptr) {
    respond(share->start, nullptr);
    g_object_unref(share->start);
  }
  g_clear_pointer(&latest_, g_bytes_unref);
  latest_seq_ = 0;
  answer_waiting(ended_reply());
  if (notify && share->live) {
    fl_method_channel_invoke_method(channel_, "ended", nullptr, nullptr,
                                    nullptr, nullptr);
  }
}

// The user stopped it from the desktop's own indicator, or the compositor
// did.
void Host::on_closed(GDBusConnection* /*bus*/, const gchar* /*sender*/,
                     const gchar* /*path*/, const gchar* /*interface*/,
                     const gchar* /*signal*/, GVariant* /*parameters*/,
                     gpointer user_data) {
  Host* host = static_cast<Host*>(user_data);
  if (host->share_ == nullptr) return;
  host->share_->session.clear();
  host->end(true);
}

// MARK: Frames

void Host::offer(int seq, GBytes* jpeg) {
  g_clear_pointer(&latest_, g_bytes_unref);
  latest_ = g_bytes_ref(jpeg);
  latest_seq_ = seq;
  if (waiting_ != nullptr && seq > waiting_after_) {
    answer_waiting(frame_reply(seq, jpeg));
  }
}

// The newest frame after the page's, or the same seq once [kPullWaitMs]
// passes with none, so a still screen costs a round trip a second and a
// half.
void Host::frame(FlMethodCall* call) {
  const int after = int_arg(fl_method_call_get_args(call), "after", 0);
  if (share_ == nullptr || !share_->live) {
    respond(call, ended_reply());
    return;
  }
  if (waiting_ != nullptr) answer_waiting(seq_reply(waiting_after_));
  if (latest_ != nullptr && latest_seq_ > after) {
    respond(call, frame_reply(latest_seq_, latest_));
    return;
  }
  waiting_ = FL_METHOD_CALL(g_object_ref(call));
  waiting_after_ = after;
  waiting_timer_ = g_timeout_add(kPullWaitMs, on_pull_wait, this);
}

gboolean Host::on_pull_wait(gpointer user_data) {
  Host* host = static_cast<Host*>(user_data);
  host->waiting_timer_ = 0;
  host->answer_waiting(seq_reply(host->waiting_after_));
  return G_SOURCE_REMOVE;
}

void Host::answer_waiting(FlValue* reply) {
  if (waiting_ == nullptr) {
    fl_value_unref(reply);
    return;
  }
  FlMethodCall* call = waiting_;
  waiting_ = nullptr;
  if (waiting_timer_ != 0) g_source_remove(waiting_timer_);
  waiting_timer_ = 0;
  respond(call, reply);
  g_object_unref(call);
}

// MARK: Names

std::string Host::next_token() {
  return "webspace" + std::to_string(++tokens_);
}

// Where the portal puts the Request object for [token]: the caller's unique
// bus name, its colon dropped and its dots made underscores.
std::string Host::request_path(const std::string& token) const {
  return portal_path("request", token);
}

// The object the portal makes for [token] under [kind] ("request",
// "session"): the caller's unique bus name, its colon dropped and its dots
// made underscores.
std::string Host::portal_path(const char* kind,
                              const std::string& token) const {
  std::string sender = g_dbus_connection_get_unique_name(bus_) + 1;
  std::replace(sender.begin(), sender.end(), '.', '_');
  return std::string(kPortalPath) + "/" + kind + "/" + sender + "/" + token;
}

void method_call_cb(FlMethodChannel* /*channel*/, FlMethodCall* call,
                    gpointer user_data) {
  static_cast<Host*>(user_data)->handle(call);
}

void destroy_host(gpointer data) { delete static_cast<Host*>(data); }

}  // namespace

void screen_share_attach(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannel,
      FL_METHOD_CODEC(codec));
  Host* host = new Host(view, channel);
  fl_method_channel_set_method_call_handler(channel, method_call_cb, host,
                                            nullptr);
  g_object_set_data_full(G_OBJECT(view), kChannel, host, destroy_host);
}
