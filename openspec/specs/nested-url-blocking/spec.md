# Nested Webview URL Blocking Specification

## Overview

Prevents nested webviews from being created for tracking URLs, analytics, service workers, and popups while maintaining functionality for legitimate use cases like Cloudflare challenges.

## Status

- **Branch**: `claude/fix-nested-webview-urls-nUssS`
- **Date**: 2026-01-11
- **Status**: Completed

---

## Problem Statement

When opening certain websites, multiple nested webviews were being created for:
- `about:blank` (5x instances)
- `about:srcdoc` (1x instance)
- Cloudflare DNS challenges
- Google Tag Manager service worker iframes

These nested webviews degraded performance and user experience.

---

## Requirements

### Requirement: NESTED-001 - Disable Multiple Windows

The system SHALL disable automatic nested window creation.

#### Scenario: Block popup window creation

**Given** a website attempts to open a popup via window.open()
**When** the popup request is intercepted
**Then** no nested webview is created

---

### Requirement: NESTED-002 - Block about: Protocol URLs

The system SHALL block all `about:` protocol URLs.

#### Scenario: Block about:blank

**Given** a page tries to create an iframe with src="about:blank"
**When** the navigation is intercepted
**Then** the navigation is cancelled
**And** no nested webview is created

---

### Requirement: NESTED-003 - Block Service Worker Iframes

The system SHALL block service worker and tracking iframes.

Blocked patterns:
- `/sw_iframe.html`
- `/blank.html`
- `/service_worker/`

#### Scenario: Block Google Tag Manager service worker

**Given** a page loads Google Tag Manager
**When** GTM tries to create a service worker iframe
**Then** the iframe creation is blocked

---

### Requirement: NESTED-004 - Block Tracking Domains

The system SHALL block common tracking and analytics domains:

- googletagmanager.com
- google-analytics.com
- googleadservices.com
- doubleclick.net
- facebook.com/tr
- connect.facebook.net
- analytics.twitter.com
- static.ads-twitter.com

#### Scenario: Block Google Analytics iframe

**Given** a page includes Google Analytics
**When** GA tries to create a tracking iframe
**Then** the iframe is blocked

---

### Requirement: NESTED-005 - Allow Cloudflare Challenges

The system SHALL allow Cloudflare challenge URLs to load in the main webview.

#### Scenario: Complete Cloudflare challenge

**Given** a site is protected by Cloudflare
**When** a challenge is triggered
**Then** the challenge loads in the main webview (not nested)
**And** the user can complete the challenge
**And** authentication cookies are preserved

---

### Requirement: NESTED-006 - Preserve Normal Navigation

The system SHALL allow normal website navigation within the same domain.

#### Scenario: Normal internal navigation

**Given** a user is on example.com/page1
**When** they click a link to example.com/page2
**Then** navigation proceeds normally

---

## Implementation

### URL Blocking Helper

```dart
static bool _shouldBlockUrl(String url) {
  // Block about: URLs
  if (url.startsWith('about:')) return true;

  // Block service worker patterns
  if (url.contains('/sw_iframe.html') ||
      url.contains('/blank.html') ||
      url.contains('/service_worker/')) return true;

  // Block tracking domains
  final trackingDomains = [
    'googletagmanager.com',
    'google-analytics.com',
    // ... more domains
  ];

  for (final domain in trackingDomains) {
    if (url.contains(domain)) return true;
  }

  return false;
}
```

### Cloudflare Detection

```dart
static bool _isCloudflareChallenge(String url) {
  return url.contains('challenges.cloudflare.com') ||
         url.contains('cloudflare.com/cdn-cgi/challenge');
}
```

---

## What Gets Blocked

- All `about:` protocol URLs
- Service worker iframes
- Tracking iframes
- Google Tag Manager
- Google Analytics
- Google Ad Services
- DoubleClick
- Facebook tracking pixels
- Twitter analytics
- Any other popup/window.open() attempts

## What Still Works

- Normal website navigation within the same domain
- Cloudflare challenges (redirected to main webview)
- External links (via existing domain filtering logic)
- JavaScript execution and dynamic content
- Cookie persistence

---

## Files

### Modified
- `lib/platform/webview_factory.dart`
  - Added `_shouldBlockUrl()` helper
  - Added `_isCloudflareChallenge()` helper
  - Implemented `onCreateWindow` callback
  - Set `supportMultipleWindows: false`
