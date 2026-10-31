#include "egress_relay.h"

#include <memory>
#include <string>

#include "egress_relay_core.h"

namespace {

constexpr char kChannel[] = "org.codeberg.theoden8.webspace/egress_relay";

struct Host {
  FlMethodChannel* channel;
  std::unique_ptr<egress::Relay> relay;
};

FlMethodResponse* links() {
  g_autoptr(FlValue) list = fl_value_new_list();
  for (const auto& link : egress::Links()) {
    g_autoptr(FlValue) entry = fl_value_new_map();
    fl_value_set_string_take(entry, "name",
                             fl_value_new_string(link.name.c_str()));
    fl_value_set_string_take(entry, "up", fl_value_new_bool(link.up));
    g_autoptr(FlValue) addresses = fl_value_new_list();
    for (const auto& a : link.addresses) {
      fl_value_append_take(addresses, fl_value_new_string(a.c_str()));
    }
    fl_value_set_string(entry, "addresses", addresses);
    fl_value_append(list, entry);
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
}

FlMethodResponse* start(Host* host, FlValue* args) {
  FlValue* secret = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                        ? fl_value_lookup_string(args, "secret")
                        : nullptr;
  if (secret == nullptr || fl_value_get_type(secret) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad_args", "start takes a secret", nullptr));
  }
  if (host->relay) host->relay->Stop();
  std::string error;
  host->relay = egress::Relay::Start(fl_value_get_string(secret), &error);
  if (!host->relay) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("unbound", error.c_str(), nullptr));
  }
  g_autoptr(FlValue) endpoint = fl_value_new_map();
  fl_value_set_string_take(endpoint, "host",
                           fl_value_new_string(host->relay->host().c_str()));
  fl_value_set_string_take(endpoint, "port",
                           fl_value_new_int(host->relay->port()));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(endpoint));
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                    gpointer user_data) {
  auto* host = static_cast<Host*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "probe") == 0) {
    g_autoptr(FlValue) ok = fl_value_new_bool(egress::CanBindDevice());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(ok));
  } else if (g_strcmp0(method, "links") == 0) {
    response = links();
  } else if (g_strcmp0(method, "start") == 0) {
    response = start(host, fl_method_call_get_args(call));
  } else if (g_strcmp0(method, "stop") == 0) {
    if (host->relay) host->relay->Stop();
    host->relay.reset();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

void destroy_host(gpointer data) {
  auto* host = static_cast<Host*>(data);
  g_object_unref(host->channel);
  delete host;
}

}  // namespace

void egress_relay_attach(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannel,
      FL_METHOD_CODEC(codec));
  Host* host = new Host{channel, nullptr};
  fl_method_channel_set_method_call_handler(channel, method_call_cb, host,
                                            nullptr);
  g_object_set_data_full(G_OBJECT(view), kChannel, host, destroy_host);
}
