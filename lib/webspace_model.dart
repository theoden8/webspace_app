import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// Special ID for the "All" webspace that contains all sites
const String kAllWebspaceId = '__all_webspace__';

class Webspace {
  String id; // Unique identifier for the webspace
  String name; // Display name for the webspace
  List<int> siteIndices; // Indices of WebViewModels that belong to this webspace
  String? language; // Language code (e.g., 'en', 'es'), null = system default

  Webspace({
    String? id,
    required this.name,
    List<int>? siteIndices,
    this.language,
  })  : id = id ?? _uuid.v4(),
        siteIndices = siteIndices ?? [];

  // Serialization methods
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'siteIndices': siteIndices,
        'language': language,
      };

  factory Webspace.fromJson(Map<String, dynamic> json) {
    return Webspace(
      id: json['id'],
      name: json['name'],
      siteIndices: (json['siteIndices'] as List<dynamic>).map((e) => e as int).toList(),
      language: json['language'],
    );
  }

  // Create a copy of this webspace with updated fields
  // Use clearLanguage: true to explicitly set language to null (system default)
  Webspace copyWith({
    String? id,
    String? name,
    List<int>? siteIndices,
    String? language,
    bool clearLanguage = false,
  }) {
    return Webspace(
      id: id ?? this.id,
      name: name ?? this.name,
      siteIndices: siteIndices ?? this.siteIndices,
      language: clearLanguage ? null : (language ?? this.language),
    );
  }

  // Check if this is the special "All" webspace
  bool get isAll => id == kAllWebspaceId;

  // Factory method to create the "All" webspace
  factory Webspace.all() {
    return Webspace(
      id: kAllWebspaceId,
      name: 'All',
      siteIndices: [], // Will be populated dynamically
    );
  }
}
