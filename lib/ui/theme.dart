class RgbColor {
  final int r;
  final int g;
  final int b;

  const RgbColor(this.r, this.g, this.b);

  factory RgbColor.hex(String hex) {
    final clean = hex.replaceAll('#', '').trim();
    final val = int.parse(clean, radix: 16);
    return RgbColor((val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF);
  }

  String get fg => '\x1B[38;2;$r;$g;${b}m';
  String get bg => '\x1B[48;2;$r;$g;${b}m';

  String text(String content) => '$fg$content\x1B[0m';
  String chip(String content) => '$bg\x1B[30m $content \x1B[0m';
}

/// A complete 24-bit TrueColor theme definition for Nib.
class NibTheme {
  final String id;
  final String displayName;
  final RgbColor accent;
  final RgbColor secondary;
  final RgbColor primary;
  final RgbColor muted;
  final RgbColor surface;
  final RgbColor success;
  final RgbColor error;
  final RgbColor warning;
  final RgbColor info;
  final RgbColor code;
  final RgbColor diffAdd;
  final RgbColor diffDel;

  const NibTheme({
    required this.id,
    required this.displayName,
    required this.accent,
    required this.secondary,
    required this.primary,
    required this.muted,
    required this.surface,
    required this.success,
    required this.error,
    required this.warning,
    required this.info,
    required this.code,
    required this.diffAdd,
    required this.diffDel,
  });

  static const NibTheme catppuccinMocha = NibTheme(
    id: 'catppuccin',
    displayName: 'Catppuccin Mocha',
    accent: RgbColor(137, 180, 250), // #89b4fa Blue
    secondary: RgbColor(203, 166, 247), // #cba6f7 Mauve
    primary: RgbColor(205, 214, 244), // #cdd6f4 Text
    muted: RgbColor(108, 112, 134), // #6c7086 Overlay0
    surface: RgbColor(49, 50, 68), // #313244 Surface0
    success: RgbColor(166, 227, 161), // #a6e3a1 Green
    error: RgbColor(243, 139, 168), // #f38ba8 Red
    warning: RgbColor(249, 226, 175), // #f9e2af Yellow
    info: RgbColor(148, 226, 213), // #94e2d5 Teal
    code: RgbColor(250, 179, 135), // #fab387 Peach
    diffAdd: RgbColor(166, 227, 161),
    diffDel: RgbColor(243, 139, 168),
  );

  static const NibTheme tokyoNight = NibTheme(
    id: 'tokyonight',
    displayName: 'Tokyo Night',
    accent: RgbColor(122, 162, 247), // #7aa2f7
    secondary: RgbColor(187, 154, 247), // #bb9af7
    primary: RgbColor(192, 202, 245), // #c0caf5
    muted: RgbColor(86, 95, 137), // #565f89
    surface: RgbColor(36, 40, 59), // #24283b
    success: RgbColor(158, 206, 106), // #9ece6a
    error: RgbColor(247, 118, 142), // #f7768e
    warning: RgbColor(224, 175, 104), // #e0af68
    info: RgbColor(125, 207, 255), // #7dcfff
    code: RgbColor(255, 158, 100), // #ff9e64
    diffAdd: RgbColor(158, 206, 106),
    diffDel: RgbColor(247, 118, 142),
  );

  static const NibTheme nord = NibTheme(
    id: 'nord',
    displayName: 'Nord',
    accent: RgbColor(136, 192, 208), // #88c0d0
    secondary: RgbColor(129, 161, 193), // #81a1c1
    primary: RgbColor(236, 239, 244), // #eceff4
    muted: RgbColor(76, 86, 106), // #4c566a
    surface: RgbColor(59, 66, 82), // #3b4252
    success: RgbColor(163, 190, 140), // #a3be8c
    error: RgbColor(191, 97, 106), // #bf616a
    warning: RgbColor(235, 203, 139), // #ebcb8b
    info: RgbColor(143, 188, 187), // #8fbcbb
    code: RgbColor(208, 135, 112), // #d08770
    diffAdd: RgbColor(163, 190, 140),
    diffDel: RgbColor(191, 97, 106),
  );

  static const NibTheme gruvbox = NibTheme(
    id: 'gruvbox',
    displayName: 'Gruvbox Dark',
    accent: RgbColor(131, 165, 152), // #83a598
    secondary: RgbColor(211, 134, 155), // #d3869b
    primary: RgbColor(235, 219, 178), // #ebdbb2
    muted: RgbColor(146, 131, 116), // #928374
    surface: RgbColor(60, 56, 54), // #3c3836
    success: RgbColor(184, 187, 38), // #b8bb26
    error: RgbColor(251, 73, 52), // #fb4934
    warning: RgbColor(250, 189, 47), // #fabd2f
    info: RgbColor(142, 192, 124), // #8ec07c
    code: RgbColor(254, 128, 25), // #fe8019
    diffAdd: RgbColor(184, 187, 38),
    diffDel: RgbColor(251, 73, 52),
  );

  static final Map<String, NibTheme> allThemes = {
    'catppuccin': catppuccinMocha,
    'tokyonight': tokyoNight,
    'nord': nord,
    'gruvbox': gruvbox,
  };

  static NibTheme current = catppuccinMocha;

  static void setTheme(String id) {
    final lower = id.toLowerCase().trim();
    if (allThemes.containsKey(lower)) {
      current = allThemes[lower]!;
    }
  }
}

typedef TartTheme = NibTheme;
