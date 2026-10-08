import 'package:webspace/web_view_model.dart';

WebViewModel modelFromJson(Map<String, dynamic> json) =>
    WebViewModel.fromJson(json, stateSetterF: null);
