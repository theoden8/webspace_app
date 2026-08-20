import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Native favicon rendering: bytes over HTTP, cached on disk. Unchanged from
/// when this was inline in UnifiedFaviconImage.
Widget faviconNetworkImage({
  required String url,
  required double size,
  required WidgetBuilder placeholder,
  required WidgetBuilder error,
}) =>
    CachedNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      placeholder: (context, _) => placeholder(context),
      errorWidget: (context, _, _) => error(context),
    );
