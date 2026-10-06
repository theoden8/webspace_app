/// What a site may do with the credentials the user types (HTTPAUTH-004).
enum HttpAuthMemory {
  /// Nothing is read from or written to the device: archive-tier sites,
  /// whose `siteId` must not appear in app-tier secure storage (ARCH-001).
  off,

  /// Saved credentials answer challenges, but nothing new is saved:
  /// incognito sites, the way a private window still fills saved passwords.
  readOnly,

  /// Saved credentials answer challenges and the prompt offers to save.
  readWrite,
}
