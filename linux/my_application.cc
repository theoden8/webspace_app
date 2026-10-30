#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string.h>

#include "egress_relay.h"
#include "flutter/generated_plugin_registrant.h"
#include "screen_share.h"
#include "window_capture.h"

// LIR-004: webspace:// inbound URL captured at cold-start (argv) or via
// GApplication::open (warm xdg-open hits). Stored on the application
// struct, drained by the Dart side via the share_intent channel.
static const char* kShareChannel =
    "org.codeberg.theoden8.webspace/share_intent";

// NOTIF-018: lib/services/desktop_window.dart tells this runner whether a
// close hides the window, and asks it to show the window again.
static const char* kDesktopWindowChannel =
    "org.codeberg.theoden8.webspace/desktop_window";

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  char* pending_share_url;
  FlMethodChannel* share_channel;
  FlMethodChannel* desktop_window_channel;
  gboolean keep_running_when_closed;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void my_application_set_pending_share_url(MyApplication* self,
                                                 const char* url) {
  if (self->pending_share_url) {
    g_free(self->pending_share_url);
    self->pending_share_url = nullptr;
  }
  if (url == nullptr) return;
  if (g_str_has_prefix(url, "webspace://") == FALSE) return;
  self->pending_share_url = g_strdup(url);
}

static void share_method_call_handler(FlMethodChannel* /*channel*/,
                                      FlMethodCall* method_call,
                                      gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "consumeLaunchUrl") == 0) {
    g_autoptr(FlValue) value = self->pending_share_url
                                   ? fl_value_new_string(self->pending_share_url)
                                   : fl_value_new_null();
    if (self->pending_share_url) {
      g_free(self->pending_share_url);
      self->pending_share_url = nullptr;
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (g_strcmp0(method, "consumeLaunchHtml") == 0) {
    // No HTML share path on Linux yet; xdg-open delivers URI strings only.
    g_autoptr(FlValue) value = fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send share-intent response: %s", error->message);
  }
}

// The one window this process builds, or null before activate builds it.
static GtkWindow* my_application_window(MyApplication* self) {
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(self));
  return windows != nullptr ? GTK_WINDOW(windows->data) : nullptr;
}

// Connected before FlView's own handler, which asks Flutter to exit: with
// the setting on, the close hides the window and the app keeps running
// (NOTIF-018).
static gboolean window_delete_event_cb(GtkWidget* window, GdkEvent* /*event*/,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (!self->keep_running_when_closed) return FALSE;
  gtk_widget_hide(window);
  return TRUE;
}

static void desktop_window_method_call_handler(FlMethodChannel* /*channel*/,
                                               FlMethodCall* method_call,
                                               gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "setKeepRunningWhenClosed") == 0) {
    FlValue* keep = args != nullptr &&
                            fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                        ? fl_value_lookup_string(args, "keep")
                        : nullptr;
    if (keep == nullptr || fl_value_get_type(keep) != FL_VALUE_TYPE_BOOL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_args", "setKeepRunningWhenClosed takes keep", nullptr));
    } else {
      self->keep_running_when_closed = fl_value_get_bool(keep);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "show") == 0) {
    GtkWindow* window = my_application_window(self);
    if (window != nullptr) gtk_window_present(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send desktop-window response: %s", error->message);
  }
}

// Implements GApplication::activate. PLATFORM-011: a second launch reaches
// the running instance here, and brings back the window it already has.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (GtkWindow* existing = my_application_window(self)) {
    gtk_window_present(existing);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event_cb),
                   self);

  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Webspace");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Webspace");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  screen_share_attach(view);
  egress_relay_attach(view);
#ifndef NDEBUG
  window_capture_attach(view, window);
#endif

  // Register the share-intent channel after the engine is up.
  if (self->share_channel == nullptr) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    self->share_channel = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        kShareChannel, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(
        self->share_channel, share_method_call_handler, self, nullptr);
  }
  if (self->desktop_window_channel == nullptr) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    self->desktop_window_channel = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        kDesktopWindowChannel, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(
        self->desktop_window_channel, desktop_window_method_call_handler, self,
        nullptr);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open. Triggered when GApplication's default
// command-line handling sees one or more URI arguments and the
// G_APPLICATION_HANDLES_OPEN flag is set. Each `file` is a `GFile`; for
// non-file URIs (e.g. webspace://) GApplication still represents them as
// GFile pointers — `g_file_get_uri` round-trips the original URI string.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* /*hint*/) {
  MyApplication* self = MY_APPLICATION(application);
  for (gint i = 0; i < n_files; i++) {
    g_autofree gchar* uri = g_file_get_uri(files[i]);
    if (uri == nullptr) continue;
    my_application_set_pending_share_url(self, uri);
  }
  // GApplication suppresses ::activate when ::open fires, so we have to
  // ensure a window exists. Activate explicitly: idempotent because activate
  // brings back the window this process already has (PLATFORM-011).
  g_application_activate(application);
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  gchar** argv = *arguments;
  gint argc = 0;
  while (argv && argv[argc] != nullptr) ++argc;

  // Detect a `webspace://...` first positional argument and route through
  // GApplication::open. Forward the rest to dart_entrypoint_arguments as
  // before.
  gchar* webspace_uri = nullptr;
  for (gint i = 1; i < argc; ++i) {
    if (g_str_has_prefix(argv[i], "webspace://")) {
      webspace_uri = argv[i];
      break;
    }
  }
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  if (webspace_uri != nullptr) {
    g_autoptr(GFile) file = g_file_new_for_uri(webspace_uri);
    GFile* files[] = {file};
    g_application_open(application, files, 1, "");
  } else {
    g_application_activate(application);
  }
  *exit_status = 0;

  return TRUE;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->pending_share_url, g_free);
  g_clear_object(&self->share_channel);
  g_clear_object(&self->desktop_window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

// PLATFORM-011: unique, so a second launch hands its activation, or its
// webspace:// URI, to the instance already running and exits.
MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
