import 'package:nib/ui/theme.dart';
import 'package:test/test.dart';

void main() {
  group('NibTheme Palettes and Switching', () {
    test(
      'catppuccinMocha features signature lavender and flamingo accents',
      () {
        final cat = NibTheme.catppuccinMocha;
        expect(cat.accent.r, equals(180));
        expect(cat.accent.g, equals(190));
        expect(cat.accent.b, equals(254)); // #b4befe Lavender

        expect(cat.secondary.r, equals(242));
        expect(cat.secondary.g, equals(205));
        expect(cat.secondary.b, equals(205)); // #f2cdcd Flamingo
      },
    );

    test('all 14 themes are registered', () {
      final expectedThemes = [
        'catppuccin',
        'tokyonight',
        'nord',
        'gruvbox',
        'dracula',
        'rosepine',
        'onedark',
        'monokai',
        'kanagawa',
        'everforest',
        'solarized-dark',
        'solarized-light',
        'github-dark',
        'synthwave',
      ];

      for (final id in expectedThemes) {
        expect(
          NibTheme.allThemes.containsKey(id),
          isTrue,
          reason: 'Theme "$id" should be in allThemes',
        );
      }
    });

    test('setTheme resolves themes and aliases cleanly', () {
      NibTheme.setTheme('dracula');
      expect(NibTheme.current.id, equals('dracula'));

      NibTheme.setTheme('rose-pine');
      expect(NibTheme.current.id, equals('rosepine'));

      NibTheme.setTheme('MONOKAI-PRO');
      expect(NibTheme.current.id, equals('monokai'));

      NibTheme.setTheme('github');
      expect(NibTheme.current.id, equals('github-dark'));

      NibTheme.setTheme('synthwave84');
      expect(NibTheme.current.id, equals('synthwave'));

      NibTheme.setTheme('solarized');
      expect(NibTheme.current.id, equals('solarized-dark'));

      NibTheme.setTheme('catppuccin');
      expect(NibTheme.current.id, equals('catppuccin'));
    });

    test('RgbColor generates correct TrueColor 24-bit ANSI sequences', () {
      const color = RgbColor(12, 34, 56);
      expect(color.fg, equals('\x1B[38;2;12;34;56m'));
      expect(color.bg, equals('\x1B[48;2;12;34;56m'));
      expect(color.text('hi'), equals('\x1B[38;2;12;34;56mhi\x1B[0m'));
    });
  });
}
