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
    accent: RgbColor(180, 190, 254), // #b4befe Lavender
    secondary: RgbColor(242, 205, 205), // #f2cdcd Flamingo
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

  static const NibTheme dracula = NibTheme(
    id: 'dracula',
    displayName: 'Dracula',
    accent: RgbColor(189, 147, 249), // #bd93f9 Purple
    secondary: RgbColor(255, 121, 198), // #ff79c6 Pink
    primary: RgbColor(248, 248, 242), // #f8f8f2 Foreground
    muted: RgbColor(98, 114, 164), // #6272a4 Comment
    surface: RgbColor(68, 71, 90), // #44475a Current Line
    success: RgbColor(80, 250, 123), // #50fa7b Green
    error: RgbColor(255, 85, 85), // #ff5555 Red
    warning: RgbColor(241, 250, 140), // #f1fa8c Yellow
    info: RgbColor(139, 233, 253), // #8be9fd Cyan
    code: RgbColor(255, 184, 108), // #ffb86c Orange
    diffAdd: RgbColor(80, 250, 123),
    diffDel: RgbColor(255, 85, 85),
  );

  static const NibTheme rosePine = NibTheme(
    id: 'rosepine',
    displayName: 'Rosé Pine',
    accent: RgbColor(235, 188, 186), // #ebbcba Rose
    secondary: RgbColor(196, 167, 231), // #c4a7e7 Iris
    primary: RgbColor(224, 222, 244), // #e0def4 Text
    muted: RgbColor(110, 106, 134), // #6e6a86 Muted
    surface: RgbColor(38, 35, 58), // #26233a Surface
    success: RgbColor(156, 207, 216), // #9ccfd8 Foam
    error: RgbColor(235, 111, 146), // #eb6f92 Love
    warning: RgbColor(246, 193, 119), // #f6c177 Gold
    info: RgbColor(156, 207, 216), // #9ccfd8 Foam
    code: RgbColor(246, 193, 119), // #f6c177 Gold
    diffAdd: RgbColor(156, 207, 216),
    diffDel: RgbColor(235, 111, 146),
  );

  static const NibTheme oneDark = NibTheme(
    id: 'onedark',
    displayName: 'One Dark',
    accent: RgbColor(97, 175, 239), // #61afef Blue
    secondary: RgbColor(198, 120, 221), // #c678dd Purple
    primary: RgbColor(171, 178, 191), // #abb2bf Text
    muted: RgbColor(92, 99, 112), // #5c6370 Comment
    surface: RgbColor(40, 44, 52), // #282c34 Gutter
    success: RgbColor(152, 195, 121), // #98c379 Green
    error: RgbColor(224, 108, 117), // #e06c75 Red
    warning: RgbColor(229, 192, 123), // #e5c07b Yellow
    info: RgbColor(86, 182, 194), // #56b6c2 Cyan
    code: RgbColor(209, 154, 102), // #d19a66 Orange
    diffAdd: RgbColor(152, 195, 121),
    diffDel: RgbColor(224, 108, 117),
  );

  static const NibTheme monokaiPro = NibTheme(
    id: 'monokai',
    displayName: 'Monokai Pro',
    accent: RgbColor(255, 216, 102), // #ffd866 Yellow
    secondary: RgbColor(255, 97, 136), // #ff6188 Red/Pink
    primary: RgbColor(252, 252, 250), // #fcfcfa Text
    muted: RgbColor(114, 112, 114), // #727072 Muted
    surface: RgbColor(64, 62, 65), // #403e41 Surface
    success: RgbColor(169, 220, 118), // #a9dc76 Green
    error: RgbColor(255, 97, 136), // #ff6188 Red
    warning: RgbColor(252, 152, 103), // #fc9867 Orange
    info: RgbColor(120, 220, 232), // #78dce8 Cyan
    code: RgbColor(171, 157, 242), // #ab9df2 Purple
    diffAdd: RgbColor(169, 220, 118),
    diffDel: RgbColor(255, 97, 136),
  );

  static const NibTheme kanagawa = NibTheme(
    id: 'kanagawa',
    displayName: 'Kanagawa',
    accent: RgbColor(126, 156, 216), // #7e9cd8 Crystal Blue
    secondary: RgbColor(149, 127, 184), // #957fb8 Oni Violet
    primary: RgbColor(220, 215, 186), // #dcd7ba Fuji White
    muted: RgbColor(114, 113, 105), // #727169 Fuji Gray
    surface: RgbColor(42, 42, 55), // #2a2a37 Sumi Ink 2
    success: RgbColor(118, 148, 106), // #76946a Autumn Green
    error: RgbColor(195, 64, 67), // #c34043 Autumn Red
    warning: RgbColor(192, 163, 110), // #c0a36e Boat Yellow
    info: RgbColor(122, 168, 159), // #7aa89f Wave Aqua
    code: RgbColor(255, 160, 102), // #ffa066 Surimi Orange
    diffAdd: RgbColor(118, 148, 106),
    diffDel: RgbColor(195, 64, 67),
  );

  static const NibTheme everforest = NibTheme(
    id: 'everforest',
    displayName: 'Everforest',
    accent: RgbColor(167, 192, 128), // #a7c080 Green
    secondary: RgbColor(214, 153, 182), // #d699b6 Purple
    primary: RgbColor(211, 198, 170), // #d3c6aa Fg
    muted: RgbColor(133, 146, 137), // #859289 Grey
    surface: RgbColor(55, 65, 69), // #374145 Bg2
    success: RgbColor(167, 192, 128), // #a7c080 Green
    error: RgbColor(230, 126, 128), // #e67e80 Red
    warning: RgbColor(219, 188, 127), // #dbbc7f Yellow
    info: RgbColor(127, 187, 179), // #7fbbb3 Blue
    code: RgbColor(230, 152, 117), // #e69875 Orange
    diffAdd: RgbColor(167, 192, 128),
    diffDel: RgbColor(230, 126, 128),
  );

  static const NibTheme solarizedDark = NibTheme(
    id: 'solarized-dark',
    displayName: 'Solarized Dark',
    accent: RgbColor(38, 139, 210), // #268bd2 Blue
    secondary: RgbColor(42, 161, 152), // #2aa198 Cyan
    primary: RgbColor(147, 161, 161), // #93a1a1 Base1
    muted: RgbColor(88, 110, 117), // #586e75 Base01
    surface: RgbColor(7, 54, 66), // #073642 Base02
    success: RgbColor(133, 153, 0), // #859900 Green
    error: RgbColor(220, 50, 47), // #dc322f Red
    warning: RgbColor(181, 137, 0), // #b58900 Yellow
    info: RgbColor(42, 161, 152), // #2aa198 Cyan
    code: RgbColor(203, 75, 22), // #cb4b16 Orange
    diffAdd: RgbColor(133, 153, 0),
    diffDel: RgbColor(220, 50, 47),
  );

  static const NibTheme solarizedLight = NibTheme(
    id: 'solarized-light',
    displayName: 'Solarized Light',
    accent: RgbColor(38, 139, 210), // #268bd2 Blue
    secondary: RgbColor(42, 161, 152), // #2aa198 Cyan
    primary: RgbColor(88, 110, 117), // #586e75 Base00
    muted: RgbColor(147, 161, 161), // #93a1a1 Base1
    surface: RgbColor(238, 232, 213), // #eee8d5 Base2
    success: RgbColor(133, 153, 0), // #859900 Green
    error: RgbColor(220, 50, 47), // #dc322f Red
    warning: RgbColor(181, 137, 0), // #b58900 Yellow
    info: RgbColor(42, 161, 152), // #2aa198 Cyan
    code: RgbColor(203, 75, 22), // #cb4b16 Orange
    diffAdd: RgbColor(133, 153, 0),
    diffDel: RgbColor(220, 50, 47),
  );

  static const NibTheme githubDark = NibTheme(
    id: 'github-dark',
    displayName: 'GitHub Dark',
    accent: RgbColor(88, 166, 255), // #58a6ff Blue
    secondary: RgbColor(188, 140, 255), // #bc8cff Purple
    primary: RgbColor(201, 209, 217), // #c9d1d9 Fg
    muted: RgbColor(139, 148, 158), // #8b949e Muted
    surface: RgbColor(33, 38, 45), // #21262d Canvas subtle
    success: RgbColor(63, 185, 80), // #3fb950 Green
    error: RgbColor(248, 81, 73), // #f85149 Red
    warning: RgbColor(210, 153, 34), // #d29922 Yellow
    info: RgbColor(57, 197, 207), // #39c5cf Cyan
    code: RgbColor(240, 136, 62), // #f0883e Orange
    diffAdd: RgbColor(63, 185, 80),
    diffDel: RgbColor(248, 81, 73),
  );

  static const NibTheme synthwave = NibTheme(
    id: 'synthwave',
    displayName: "Synthwave '84",
    accent: RgbColor(254, 68, 80), // #fe4450 Neon Pink
    secondary: RgbColor(254, 222, 93), // #fede5d Neon Yellow
    primary: RgbColor(240, 239, 241), // #f0eff1 Bright White
    muted: RgbColor(132, 139, 189), // #848bbd Neon Violet-gray
    surface: RgbColor(52, 41, 79), // #34294f Dark Violet
    success: RgbColor(114, 241, 184), // #72f1b8 Laser Mint
    error: RgbColor(254, 68, 80), // #fe4450 Hot Red
    warning: RgbColor(254, 222, 93), // #fede5d Electric Gold
    info: RgbColor(3, 237, 249), // #03edf9 Cyan Neon
    code: RgbColor(255, 126, 219), // #ff7edb Hot Pink
    diffAdd: RgbColor(114, 241, 184),
    diffDel: RgbColor(254, 68, 80),
  );

  static final Map<String, NibTheme> allThemes = {
    'catppuccin': catppuccinMocha,
    'tokyonight': tokyoNight,
    'nord': nord,
    'gruvbox': gruvbox,
    'dracula': dracula,
    'rosepine': rosePine,
    'onedark': oneDark,
    'monokai': monokaiPro,
    'kanagawa': kanagawa,
    'everforest': everforest,
    'solarized-dark': solarizedDark,
    'solarized-light': solarizedLight,
    'github-dark': githubDark,
    'synthwave': synthwave,
  };

  static NibTheme current = catppuccinMocha;

  static void setTheme(String id) {
    final lower = id.toLowerCase().trim().replaceAll('_', '-');
    final aliases = <String, String>{
      'rose-pine': 'rosepine',
      'monokai-pro': 'monokai',
      'one-dark': 'onedark',
      'solarized': 'solarized-dark',
      'github': 'github-dark',
      'synthwave84': 'synthwave',
      'synthwave-84': 'synthwave',
    };
    final resolved = aliases[lower] ?? lower;
    if (allThemes.containsKey(resolved)) {
      current = allThemes[resolved]!;
    }
  }
}
