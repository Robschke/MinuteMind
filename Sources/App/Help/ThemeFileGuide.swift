// Purpose: ThemeFileGuide, the description of the theme file format Claude reads before it writes
//          a theme: every key, the allowed values, an example and design advice.
// Dependencies: Sources/App/Config/ThemeFile.swift (keys, version), Sources/App/Config/ThemeStyle.swift
//               (enums and ranges), Sources/App/Config/AppTheme.swift (built-in ids)
// Used by: Sources/App/Services/MCP/MCPThemeTools.swift (get_theme_rules),
//          Sources/App/Help/HelpGuideContent.swift (the Appearance topic carries it, so a Claude
//          that edits the files directly finds it through get_help too)
// Notes: Built from the same constants the validator uses, so the guide cannot list a value the
//        validator refuses or miss one it accepts.

import Foundation

enum ThemeFileGuide {
    static var markdown: String {
        let corners = ThemeStyle.Corners.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
        let density = ThemeStyle.Density.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
        let bases = AppTheme.builtIn.map { "`\($0.id)` (\($0.mood))" }.joined(separator: "; ")
        let colors = ThemeFile.colorKeys.map { "`\($0)`" }.joined(separator: ", ")
        let scale = ThemeStyle.fontScaleRange
        let size = ThemeStyle.terminalSizeRange
        return """
        ## Theme files (for Claude)

        A theme is one JSON file, `<id>.json`, in `~/Library/Application Support/MinuteMind/Themes/`. The app reads the folder every 1.5 seconds and applies changes to the selected theme at once. Prefer the MCP tools: `get_theme` (start from an existing theme), `preview_theme` (check and look at it), `save_theme` (write and select it), `delete_theme`, `list_fonts`. Editing the file directly works too; a file that does not pass keeps its last good version on screen, and `list_themes` shows its problems.

        Keys (all optional except `id` and `name`; unknown keys are refused):

        - `formatVersion`: \(ThemeFile.formatVersion).
        - `id`: lowercase letters, digits and dashes, at most 40; it is the file name. Saving under an existing id replaces that theme.
        - `name`: shown on the theme card, at most 40 characters. `description`: one line under it.
        - `base`: the built-in theme every unlisted colour comes from: \(bases). Default `studio`.
        - `colors`: any of \(colors), plus `speakers` (exactly \(ThemeFile.speakerCount) colours, the speaker labels in transcripts). A colour is `"#RRGGBB"` for both modes or `{"light": "#RRGGBB", "dark": "#RRGGBB"}`. `background` is the page, `surface` the sidebars and strips, `card` raised panels, `border` lines and outlines, `accent` selection, buttons and links; `success`, `warning` and `danger` are status colours (recording red stays red regardless). When `background` is set and `surface` or a text colour is not, they are derived from the background so text stays readable.
        - `font`: `{"family": "Inter", "scale": 1.0}`. `family` is an installed font family (see `list_fonts`), or `null` for the system font. `scale` multiplies every text size, \(scale.lowerBound) to \(scale.upperBound).
        - `corners`: \(corners). How round cards, buttons and panels are (`square` is 0, `regular` today's look).
        - `density`: \(density). How much room padding and gaps take everywhere (`compact` is about 70 percent, `roomy` 130).
        - `terminal`: `{"family": "JetBrains Mono", "size": 13}` for the Claude terminals, the code editor and monospaced text. `family` `null` is SF Mono; `size` \(Int(size.lowerBound)) to \(Int(size.upperBound)) points.

        Example, a dense dark terminal look:

        ```json
        {
          "formatVersion": 1,
          "id": "terminal",
          "name": "Terminal",
          "description": "Dark, dense and monospaced",
          "base": "midnight",
          "colors": {
            "accent": {"light": "#0E7490", "dark": "#5EEAD4"},
            "background": {"light": "#F6F7F9", "dark": "#0A0D12"},
            "card": {"light": "#FFFFFF", "dark": "#11161D"},
            "border": {"light": "#D5DAE1", "dark": "#1F2833"}
          },
          "font": {"family": "Menlo", "scale": 0.95},
          "corners": "square",
          "density": "compact",
          "terminal": {"family": "Menlo", "size": 13}
        }
        ```

        Advice: give every colour a light and a dark value unless the look is meant to stay the same in both modes (then tell the user that Light mode will look dark too). Keep body text at a contrast of 4.5:1 or more on the background; `preview_theme` and `save_theme` warn below that, on `card` as well. Whenever you set `background`, set `card` (and `border`) too: text colours are derived from the background, while an unset card stays the base theme's, so light text can end up on a light card. Pick fonts from `list_fonts`; a family that is not installed falls back to the system font. Look at the `preview_theme` picture before saving.
        """
    }
}
