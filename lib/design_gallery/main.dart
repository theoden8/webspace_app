// Design-time gallery entrypoint. Not shipped: builds only for the web
// target, which exists so real widgets can be rendered in a browser and
// screenshotted. The native WebView never renders here; cards that need one
// draw a placeholder in its place.
//
//   flutter build web -t lib/design_gallery/main.dart
//   ?card=<id>&theme=light|dark&accent=<name>&locale=<code>
//
// Without ?card the page shows every card at once for human browsing.
// Workflow and constraints: tool/design_gallery/CLAUDE.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/widgets/url_bar.dart';

const Map<String, Color> galleryAccents = {
  'blue': accentBlue,
  'green': accentGreen,
  'purple': accentPurple,
  'orange': accentOrange,
  'red': accentRed,
  'pink': accentPink,
  'teal': accentTeal,
  'yellow': accentYellow,
};

class GalleryCard {
  const GalleryCard({required this.id, required this.label, required this.builder});

  final String id;
  final String label;
  final WidgetBuilder builder;
}

final List<GalleryCard> galleryCards = [
  GalleryCard(id: 'color-roles', label: 'Color roles', builder: (c) => const _ColorRolesCard()),
  GalleryCard(id: 'type-scale', label: 'Type scale', builder: (c) => const _TypeScaleCard()),
  GalleryCard(id: 'radius-scale', label: 'Corner radii', builder: (c) => const _RadiusScaleCard()),
  GalleryCard(id: 'url-bar', label: 'URL bar', builder: (c) => const _UrlBarCard()),
  GalleryCard(id: 'hint-button', label: 'Hint button', builder: (c) => const _HintButtonCard()),
  GalleryCard(id: 'tab-corner-button', label: 'Tab corner button', builder: (c) => const _TabCornerCard()),
  GalleryCard(id: 'browser-chrome', label: 'Browser chrome', builder: (c) => const _BrowserChromeCard()),
];

/// CanvasKit pulls Roboto from fonts.gstatic.com; where that is unreachable it
/// draws no text at all. Serve it from web/fonts (see sync_fonts.js) instead.
Future<void> _loadRoboto() async {
  const faces = ['Roboto_400Regular', 'Roboto_500Medium', 'Roboto_700Bold'];
  final loader = FontLoader('Roboto');
  var loaded = 0;
  for (final face in faces) {
    try {
      final res = await http.get(Uri.parse('fonts/$face.ttf'));
      if (res.statusCode != 200) continue;
      loader.addFont(Future.value(ByteData.sublistView(res.bodyBytes)));
      loaded++;
    } catch (_) {}
  }
  if (loaded > 0) await loader.load();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadRoboto();
  final q = Uri.base.queryParameters;
  runApp(GalleryApp(
    cardId: q['card'],
    brightness: q['theme'] == 'dark' ? Brightness.dark : Brightness.light,
    accent: galleryAccents[q['accent']] ?? accentBlue,
    localeCode: q['locale'],
  ));
}

class GalleryApp extends StatelessWidget {
  const GalleryApp({
    super.key,
    this.cardId,
    this.brightness = Brightness.light,
    this.accent = accentBlue,
    this.localeCode,
  });

  final String? cardId;
  final Brightness brightness;
  final Color accent;
  final String? localeCode;

  @override
  Widget build(BuildContext context) {
    final scheme = buildAccentColorScheme(accent, brightness);
    final single = cardId == null
        ? null
        : galleryCards.where((c) => c.id == cardId).firstOrNull;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: localeCode == null ? null : Locale(localeCode!),
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor:
            brightness == Brightness.light ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      ),
      home: single != null
          ? Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: single.builder(context))))
          : const _GalleryIndex(),
    );
  }
}

class _GalleryIndex extends StatelessWidget {
  const _GalleryIndex();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebSpace design gallery'),
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            for (final card in galleryCards)
              SizedBox(
                width: 460,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(card.label, style: theme.textTheme.titleSmall),
                    Text('?card=${card.id}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: card.builder(context),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ColorRolesCard extends StatelessWidget {
  const _ColorRolesCard();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final roles = <String, (Color, Color)>{
      'primary': (s.primary, s.onPrimary),
      'primaryContainer': (s.primaryContainer, s.onPrimaryContainer),
      'secondary': (s.secondary, s.onSecondary),
      'surface': (s.surface, s.onSurface),
      'surfaceContainerHighest': (s.surfaceContainerHighest, s.onSurfaceVariant),
      'error': (s.error, s.onError),
      'outline': (s.outline, s.surface),
      'outlineVariant': (s.outlineVariant, s.onSurface),
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in roles.entries)
          Container(
            width: 200,
            height: 56,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: e.value.$1,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: s.outlineVariant),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.key, style: TextStyle(color: e.value.$2, fontSize: 12)),
                Text(
                  '#${(e.value.$1.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  style: TextStyle(color: e.value.$2, fontSize: 10),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TypeScaleCard extends StatelessWidget {
  const _TypeScaleCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final styles = <String, TextStyle?>{
      'titleLarge': t.titleLarge,
      'titleMedium': t.titleMedium,
      'bodyLarge': t.bodyLarge,
      'bodyMedium': t.bodyMedium,
      'bodySmall': t.bodySmall,
      'labelSmall': t.labelSmall,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in styles.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${e.key} ${e.value?.fontSize?.toStringAsFixed(0)}px', style: e.value),
          ),
      ],
    );
  }
}

class _RadiusScaleCard extends StatelessWidget {
  const _RadiusScaleCard();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final r in [2.0, 4.0, 6.0, 8.0, 12.0])
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: s.primaryContainer,
                  borderRadius: BorderRadius.circular(r),
                ),
              ),
              const SizedBox(height: 4),
              Text(r.toStringAsFixed(0), style: TextStyle(fontSize: 11, color: s.onSurfaceVariant)),
            ],
          ),
      ],
    );
  }
}

class _UrlBarCard extends StatelessWidget {
  const _UrlBarCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        UrlBar(currentUrl: 'https://codeberg.org/theoden8/webspace', onUrlSubmitted: (_) {}),
        const SizedBox(height: 16),
        UrlBar(currentUrl: 'http://example.org', onUrlSubmitted: (_) {}),
      ],
    );
  }
}

class _HintButtonCard extends StatelessWidget {
  const _HintButtonCard();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Tracking protection'),
        HintButton(
          title: 'Tracking protection',
          description: 'Forces ClearURLs, DNS blocklist, content blocker and LocalCDN on, '
              'and injects the anti-fingerprinting shim.',
        ),
      ],
    );
  }
}

class _TabCornerCard extends StatelessWidget {
  const _TabCornerCard();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TabBarCornerButton(
          dragging: false,
          onTap: () {},
          onDragBegin: (_) {},
          onDragUpdate: (_) {},
          onDragEnd: () {},
        ),
        const SizedBox(width: 32),
        TabBarCornerButton(
          dragging: true,
          onTap: () {},
          onDragBegin: (_) {},
          onDragUpdate: (_) {},
          onDragEnd: () {},
        ),
      ],
    );
  }
}

/// The chrome around a site, composed from the real primitives. The content
/// area is a placeholder: the native WebView has no web implementation.
class _BrowserChromeCard extends StatelessWidget {
  const _BrowserChromeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: s.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 56,
            color: s.primaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(Icons.menu, color: s.onPrimaryContainer),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('Codeberg',
                      style: theme.textTheme.titleMedium?.copyWith(color: s.onPrimaryContainer)),
                ),
                Icon(Icons.refresh, color: s.onPrimaryContainer),
                const SizedBox(width: 16),
                Icon(Icons.more_vert, color: s.onPrimaryContainer),
              ],
            ),
          ),
          SizedBox(
            height: 220,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: s.surfaceContainerHighest,
                    child: Center(
                      child: Text('site content (native WebView)',
                          style: TextStyle(color: s.onSurfaceVariant, fontSize: 12)),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: TabBarCornerButton(
                    dragging: false,
                    onTap: () {},
                    onDragBegin: (_) {},
                    onDragUpdate: (_) {},
                    onDragEnd: () {},
                  ),
                ),
              ],
            ),
          ),
          UrlBar(currentUrl: 'https://codeberg.org/theoden8/webspace', onUrlSubmitted: (_) {}),
        ],
      ),
    );
  }
}
