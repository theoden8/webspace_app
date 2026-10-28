#ifndef RUNNER_SCREEN_SHARE_H_
#define RUNNER_SCREEN_SHARE_H_

#include <flutter_linux/flutter_linux.h>

// The `screen_share` channel on Linux (SHARE-018): the calls of Android's
// ScreenSharePlugin.kt and macos/Runner/ScreenSharePlugin.swift (`start`,
// `frame`, `stop`, and `ended` back to Dart), served from the desktop
// portal's ScreenCast and the PipeWire stream it hands over. The view owns
// the channel, and a share running when it goes ends with it.
void screen_share_attach(FlView* view);

#endif  // RUNNER_SCREEN_SHARE_H_
