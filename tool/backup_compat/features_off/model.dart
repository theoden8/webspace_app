import 'package:webspace/web_view_model.dart';

/// Before every argument past the first was named, `fromJson` took the state
/// setter positionally. The call is dynamic so this file also compiles where
/// it is named, which is the tree it sits in.
WebViewModel modelFromJson(Map<String, dynamic> json) =>
    (WebViewModel.fromJson as dynamic)(json, null) as WebViewModel;
