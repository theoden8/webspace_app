#include "window_capture.h"

#ifndef NDEBUG

#include <cairo.h>

static const char* kWindowCaptureChannel =
    "org.codeberg.theoden8.webspace/window_capture";

static cairo_status_t append_png(void* closure, const unsigned char* data,
                                 unsigned int length) {
  g_byte_array_append(static_cast<GByteArray*>(closure), data, length);
  return CAIRO_STATUS_SUCCESS;
}

// Drawn into an image, not read back from the display server: FlView paints
// through gdk_cairo_draw_from_gl, which reads its GL frame back for any cairo
// target, and the WPE view is a texture inside that frame. So the capture
// works on X11 and Wayland alike, with the window off screen or covered.
static FlMethodResponse* capture(GtkWindow* window) {
  GtkWidget* widget = GTK_WIDGET(window);
  const int scale = gtk_widget_get_scale_factor(widget);
  cairo_surface_t* surface = cairo_image_surface_create(
      CAIRO_FORMAT_ARGB32, gtk_widget_get_allocated_width(widget) * scale,
      gtk_widget_get_allocated_height(widget) * scale);
  cairo_surface_set_device_scale(surface, scale, scale);
  cairo_t* cr = cairo_create(surface);
  gtk_widget_draw(widget, cr);
  cairo_destroy(cr);
  g_autoptr(GByteArray) png = g_byte_array_new();
  const cairo_status_t status =
      cairo_surface_write_to_png_stream(surface, append_png, png);
  cairo_surface_destroy(surface);
  if (status != CAIRO_STATUS_SUCCESS) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "capture_failed", cairo_status_to_string(status), nullptr));
  }
  g_autoptr(FlValue) bytes = fl_value_new_uint8_list(png->data, png->len);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(bytes));
}

static FlMethodResponse* resize(GtkWindow* window, FlValue* args) {
  FlValue* width = nullptr;
  FlValue* height = nullptr;
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    width = fl_value_lookup_string(args, "width");
    height = fl_value_lookup_string(args, "height");
  }
  if (width == nullptr || fl_value_get_type(width) != FL_VALUE_TYPE_FLOAT ||
      height == nullptr || fl_value_get_type(height) != FL_VALUE_TYPE_FLOAT) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad_args", "resize takes width and height", nullptr));
  }
  gtk_window_resize(window, static_cast<gint>(fl_value_get_float(width)),
                    static_cast<gint>(fl_value_get_float(height)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void method_call_cb(FlMethodChannel* /*channel*/, FlMethodCall* call,
                           gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "resize") == 0) {
    response = resize(window, fl_method_call_get_args(call));
  } else if (g_strcmp0(method, "capture") == 0) {
    response = capture(window);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("Failed to send window_capture response: %s", error->message);
  }
}

void window_capture_attach(FlView* view, GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kWindowCaptureChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, window,
                                            nullptr);
  // The window owns the channel, so both go together.
  g_object_set_data_full(G_OBJECT(window), kWindowCaptureChannel, channel,
                         g_object_unref);
}

#endif  // NDEBUG
