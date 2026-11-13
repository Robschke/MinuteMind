// Purpose: HelpGuideTroubleshooting, the guide topic for when something does not work: common
//          symptoms, their causes and fixes, and how Claude can check and repair MinuteMind.
// Dependencies: Sources/App/Help/HelpGuide.swift (HelpGuideTopic)
// Used by: Sources/App/Help/HelpGuide.swift (appended to the topics)
// Notes: The cases here mirror the rules in AppDiagnostics.swift, which detect them; a new rule
//        there gets its symptom here. Kept in its own file because it grows with every failure
//        mode, while HelpGuideContent.swift follows the features. No em or en dashes in the text.

import Foundation

enum HelpGuideTroubleshooting {
    static let topic = HelpGuideTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        icon: "stethoscope",
        summary: "When something does not work: transcripts, speakers, summaries, dictation, sync; and how Claude can check and fix it.",
        body: """
        Ask Claude "what is wrong with MinuteMind?" or describe the symptom. Claude reads a health check of the app (models, permissions, Claude Code, queues, failures, sync) and MinuteMind's own log, fixes what the app can fix itself (reinstalling a model, asking for a permission, retrying a meeting, syncing) and tells you the steps for the rest.

        ## Transcripts are poor, or Settings says Apple Speech is used

        Parakeet is not installed, its download failed, or its files are incomplete. Settings > Automation > Parakeet > Install downloads it again (about 600 MB from Hugging Face); the old model, if any, keeps working until the download is complete. If it fails again, check the internet connection. A model that is installed but does not load is repaired the same way.

        ## Only my side of the call is in the recording

        MinuteMind lacks the Screen & System Audio Recording permission, or got it but was not restarted. Allow MinuteMind in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen MinuteMind.

        ## Nothing is recorded or dictated

        The Microphone permission is missing (System Settings > Privacy & Security > Microphone), or the microphone chosen in Settings > Audio is not connected. Check Settings > Audio.

        ## Everyone is "Other", speakers are not separated

        Settings > Automation > Pipeline > Identify speakers is off, or its models are not installed. With Nemotron 3 chosen but not installed, the standard engine is used until the download (about 190 MB) is done.

        ## No summary, title, todos or knowledge

        - The meeting has no project yet: choose one in the Inbox (processing needs a project or General).
        - "Process meetings once they have a project" is off: click Process.
        - Claude Code is missing or not signed in: install it (`curl -fsSL https://claude.ai/install.sh | bash` in Terminal), run `claude` once to sign in, then restart MinuteMind. Settings > AI shows whether it is found.
        - The meeting failed: the Inbox shows it with Retry.

        ## Dictated text does not appear in other apps

        MinuteMind needs the Accessibility permission to type into other apps (System Settings > Privacy & Security > Accessibility); without it the text is on the clipboard. For fn, set "Press 🌐 key to" to "Do Nothing" in macOS Keyboard settings.

        ## Shared Project does not sync

        Sync runs only on the main branch and needs network access and your git login for the project's repository. The branch row shows the problem; Sync now retries. Conflicts are merged by themselves (an edit wins over a deletion, Claude merges text); one that cannot be merged (a binary file, Claude Code missing) is reported with the file it is in. A file missing for the others may be over 50 MB: the branch row then says "1 file not synced", with Sync anyway in its list.

        ## Jobs or meeting detection did not run

        They only run while MinuteMind is open: Settings > Automation > Startup > Open MinuteMind at login. A failed job run is listed in the project's Jobs tab with Claude's answer.

        ## Claude cannot reach MinuteMind

        MinuteMind must be running with Settings > Integrations > MCP server switched on. After renewing the access token, Claude Code and Claude Desktop need the new token (Settings > Integrations shows the setup again).
        """
    )
}
