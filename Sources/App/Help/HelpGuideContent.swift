// Purpose: HelpGuideContent, the text of the MinuteMind user guide: one topic per feature area,
//          written for users. Read in the Settings Help tab and by Claude over MCP (get_help).
// Dependencies: Sources/App/Help/HelpGuide.swift (HelpGuideTopic)
// Used by: Sources/App/Help/HelpGuide.swift (HelpGuide.topics)
// Notes: Keep this current with the app: a change users can see (a new button, a moved setting,
//        a new shortcut) updates the matching topic in the same commit. Settings are named the way
//        the Settings window labels them, with their place ("Settings > Automation > Pipeline"),
//        so Claude can point people there; the settings themselves (values, options) come from
//        AppSettingsCatalog, so this text describes what they do, not every option. Topic ids are
//        referenced by AppSettingsCatalog and get_help: renaming one means updating both.
//        No em or en dashes in the text.

import Foundation

enum HelpGuideContent {
    static let topics: [HelpGuideTopic] = [
        gettingStarted, recording, meetingDetection, inbox, transcription, speakers, dictionary,
        summaries, quickDictation, voiceAssistant, companion, projects, workspace, knowledge,
        jobs, sharedProjects, calendar, tasks, claudeIntegration, appearance, storage, settings,
        updating, crashReports, shortcuts,
    ]

    static let crashReports = HelpGuideTopic(
        id: "crash-reports",
        title: "Crash Reports",
        icon: "ladybug",
        summary: "What the optional crash reports contain, where they go, and how to switch them on or off.",
        body: """
        Crash reports are off unless you switch them on: on the last page of the first-launch setup, or in Settings, Help ("Send crash reports automatically").

        When MinuteMind has crashed, macOS writes a crash log on your Mac. With the switch on, MinuteMind sends a short version of it at the next launch: where in MinuteMind it crashed (the functions on the crashed thread), the app and macOS version, the Mac model and the day. No recordings, transcripts, meeting titles, names or file contents, and user names in paths are replaced. **Show Last Report** in Settings, Help shows exactly what is sent.

        Reports go to the project's own endpoint on Cloudflare and are stored in the EU for 90 days, only to fix bugs. IP addresses are not stored. Each crash is sent once; crashes from the last 14 days count. Switching it off stops sending at once.
        """
    )

    static let updating = HelpGuideTopic(
        id: "updating",
        title: "Updating MinuteMind",
        icon: "arrow.down.circle",
        summary: "MinuteMind offers new releases by itself; you can also update from Terminal or by asking Claude.",
        body: """
        **Automatic check:** MinuteMind looks for a new release when it starts and once a day while it runs. When there is one, a dialog shows the new version and what changed. **Update** quits MinuteMind, installs the release and opens it again, usually within a minute; your recordings, projects, settings and permissions stay. **Later** hides the dialog for three days. The dialog never appears while a recording, a transcription or meeting processing runs, or during the first-launch setup: it waits until they are done.

        MinuteMind is also installed and updated with one command in Terminal:

        ```
        curl -fsSL https://raw.githubusercontent.com/Robschke/MinuteMind/main/install.sh | bash
        ```

        It downloads the latest release, quits MinuteMind, replaces the app where it is installed (/Applications or ~/Applications) and opens the new version. Your recordings, projects, settings and permissions stay. It also installs Claude Code if it is missing.

        **Ask Claude instead:** "Is there a MinuteMind update?" makes Claude compare your version with the latest release and show what changed. "Update MinuteMind" installs it: MinuteMind quits and opens again, usually within a minute. Open windows and Claude sessions in MinuteMind close, so Claude asks first. It waits while a recording, a transcription or meeting processing runs.

        Releases and their notes are listed at github.com/Robschke/MinuteMind/releases. MinuteMind needs macOS 14 or newer on a Mac with Apple Silicon.
        """
    )

    static let gettingStarted = HelpGuideTopic(
        id: "getting-started",
        title: "Getting Started",
        icon: "play.circle",
        summary: "What MinuteMind is, the first-launch setup, and where things are in the window.",
        body: """
        MinuteMind is a Mac app that records your meetings, transcribes them on your Mac, and has Claude write a summary, a title, todos and project knowledge for each one. Every project gets its own workspace folder where Claude Code can work with your meetings, and a small desktop companion keeps recording, dictation and Claude one click away.

        ## First launch

        A new install opens a short setup: one page per macOS permission (Microphone, Screen & System Audio Recording, Accessibility, Calendar, Notifications, Speech Recognition; each can be skipped and granted later in System Settings), Claude (MinuteMind uses the Claude Code app you have installed, and one click connects Claude Code to MinuteMind), the speech models (Parakeet for transcription, Nemotron 3 for telling speakers apart), a short tour, and a restart. Help > Show Welcome Tour opens it again at any time.

        ## What you need

        - **Claude Code** installed and signed in. Summaries, titles, todos, knowledge, transcript correction, jobs and the voice assistant all run through it. Without it MinuteMind still records and transcribes.
        - **Parakeet** installed (Settings > Automation > Parakeet) for the best transcripts. Until then Apple Speech is used.
        - **Screen & System Audio Recording** permission so the other side of a call is recorded, not only your microphone.

        ## The window

        MinuteMind opens on Home: your projects as tiles with their creatures. The sidebar lists Home, Inbox (meetings waiting to be processed), All Transcripts (every recording, with the record button), All Tasks, Calendar, Clipboard (your dictation history), General (a workspace for meetings without a project) and your projects. Settings is the gear at the bottom of the sidebar (Cmd+,).

        Click a project (its tile or its row) to enter it: the sidebar then belongs to that project, with its sections and its files. Click the project's name at the top of the sidebar to go back Home. The back and forward buttons of your mouse go to the previous and next place, like in a browser. Hold Cmd and press K to switch projects.

        ## Your data

        Everything stays on your Mac, in ~/Library/Application Support/MinuteMind: recordings, transcripts, projects and the workspace folders. Claude sees a meeting only when MinuteMind processes it or when you ask Claude about it.
        """
    )

    static let recording = HelpGuideTopic(
        id: "recording",
        title: "Recording Meetings",
        icon: "record.circle",
        summary: "Starting and stopping recordings, what is recorded, the 3-hour limit, importing audio and audio retention.",
        body: """
        ## Starting a recording

        - The record button on All Transcripts. The project picker next to it decides where the meeting is filed (a project, General, or none).
        - The desktop companion: right click (or Ctrl click) and choose Record.
        - When MinuteMind detects a call it offers to record it beside the companion (see Meeting Detection).
        - Calendar events with auto-record switched on start by themselves at event time.
        - Claude can start and stop recordings for you through MinuteMind's MCP tools.

        ## What is recorded

        Your microphone (the one chosen in Settings > Audio) and the Mac's system audio, so both sides of a call are captured. System audio needs the Screen & System Audio Recording permission. A one-time notice reminds you to tell the others that you record.

        ## Stopping

        Recordings only end when you stop them: with the button on All Transcripts, Stop in the companion's menu or card, or Stop on the "Meeting over?" question. When the call app releases the microphone, or after a long silence (Settings > Automation > Auto-recording), MinuteMind only asks; it never stops by itself, except at the 3-hour maximum (with a warning 10 minutes before).

        ## Projects and export folders

        A project can file every transcript and summary into a folder of your choice (project menu > Project Settings...). A project needs either an export folder or the explicit "no export" choice before you can record into it; MinuteMind tells you when that is missing. You can also pick or change the project after the recording (see Inbox and Processing).

        ## Importing audio

        File > Import Audio... (Cmd+I), or drop audio files onto All Transcripts. Imported files become normal recordings; click Transcribe on the card to start.

        ## Audio retention

        To save space, a recording's audio is deleted 14 days after it was made. The transcript, summary and everything else stay. Tick "Keep audio" on a recording's card to keep its audio for good. Settings > Storage shows what uses space.
        """
    )

    static let meetingDetection = HelpGuideTopic(
        id: "meeting-detection",
        title: "Meeting Detection",
        icon: "video",
        summary: "How MinuteMind notices calls in Teams, Zoom, Meet and others and offers to record them.",
        body: """
        With **Detect Meetings** on (the switch at the top of All Transcripts), MinuteMind notices when a call app or a browser uses the microphone for 5 seconds (Teams, Zoom, Google Meet, Webex, Slack, FaceTime and others) and offers to record it in a card beside the desktop companion. Ignore it and a hollow ring stays on the companion while the call runs, so you can still start later.

        When the call app lets go of the microphone (8 seconds) or quits, the card asks "Meeting over?" with Stop and Keep Recording. Nothing stops on its own.

        Screen sharing is detected too: while you share your screen the companion hides (unless Settings > Appearance > "Show the companion in screen shares" is on) and a menu bar item mirrors the recording state instead.

        Calendar events can record on their own: open the event in Calendar and switch on auto-record (see Calendar). "Start recording automatically at event time" in Settings > Automation > Auto-recording switches that feature on or off as a whole.

        Settings > Automation also has an older "Detect Microsoft Teams calls" switch that starts recording on its own when a Teams call is active; Detect Meetings replaces it for most people.
        """
    )

    static let inbox = HelpGuideTopic(
        id: "inbox",
        title: "Inbox and Processing",
        icon: "tray",
        summary: "Choosing a project after a recording, the project wheel, Process, Process All and Skip.",
        body: """
        After every recording MinuteMind transcribes it straight away. **Processing** is the next step: Claude corrects the transcript, then writes the summary, the title and the todos, and adds what matters to the project's knowledge. Processing needs a project (or General), because the result is filed there.

        ## Which project?

        Right after you stop, the card beside the companion asks "Which project?": your three most recent projects are one click each, Other lists every project and General, Later (or 30 seconds without an answer) leaves the meeting in the Inbox. When the project was already set (calendar mapping, the record picker) the card says "Filed to X" with Change and OK.

        **Project wheel:** while recording, or while the card asks, scroll over the companion (mouse wheel or two fingers on the trackpad) to flip through your projects: starred ones first, then the others, General, and No Project or Later. Stop scrolling for a moment and the recording is filed to the project shown; a click on a row picks it at once.

        ## Processing

        With "Process meetings once they have a project" on (Settings > Automation > Pipeline, the default) processing starts by itself as soon as a meeting has a project and a transcript. Off, you click Process.

        ## The Inbox

        Inbox in the sidebar lists recent meetings without a summary: transcribing, ready, processing (with its steps) or failed (Retry). Meetings without a project show "Choose project". Process (Cmd+Return on the selected one), Process All (Shift+Cmd+Return; skips meetings without a project; can be stopped) and Skip (hides it from the Inbox, with Undo and a Skipped filter).

        Claude can list the Inbox and process meetings for you too.
        """
    )

    static let transcription = HelpGuideTopic(
        id: "transcription",
        title: "Transcription",
        icon: "text.quote",
        summary: "Transcription engines (Parakeet, Apple Speech), language, transcript correction and audio cleanup.",
        body: """
        ## Engines

        - **Parakeet** (NVIDIA, on your Mac): the default and the most accurate. Install it once in Settings > Automation > Parakeet; the same section checks for and installs updates of the model.
        - **Apple Speech**: built into macOS, used until Parakeet is installed.

        The engine is chosen in Settings > Automation > Pipeline > Transcription engine and applies to every recording. If the chosen engine's model is missing, Apple Speech is used and Settings says so.

        ## Language

        Settings > Automation > Live Dictation > Default language (Auto-detect, English, German) applies to recordings and live dictation. A calendar series can have its own language (open the event in Calendar).

        ## Making transcripts better

        - **Transcript correction:** when a meeting is processed, Claude (always Sonnet) fixes misheard words, names and punctuation without changing what was said. Needs Claude Code.
        - **Dictionary:** terms MinuteMind should always spell right, plus how they get misheard (see Dictionary).
        - **Correct names from calendar & project** (Settings > Automation > Pipeline): fixes near-miss spellings of participant names, the project and the meeting title.
        - **Clean audio before transcription** (same place): filters rumble, evens out quiet recordings and softens background noise.
        - **Speakers:** see Speakers and Voices.

        You can edit a transcript yourself on the recording; a hand edit is kept.
        """
    )

    static let speakers = HelpGuideTopic(
        id: "speakers",
        title: "Speakers and Voices",
        icon: "person.2.wave.2",
        summary: "Telling speakers apart, naming them, the voice library and your own name in transcripts.",
        body: """
        ## Identify speakers

        Settings > Automation > Pipeline > "Identify speakers" splits the audio into Speaker 1, Speaker 2 and so on, on your Mac. Two engines: **Nemotron 3** (NVIDIA, up to 8 speakers, more accurate, the default once installed) and **Standard**. Switching it on downloads the models it needs.

        By default your microphone is labelled with your name (or "You") and only the call audio is split. Switch on "Also identify speakers on the microphone" for in-person meetings where several people share this Mac's microphone.

        ## Your name

        Settings > Audio > "Your name" is how you appear in transcripts instead of "You".

        ## Naming speakers and the voice library

        Name the speakers of a recording on its card. MinuteMind remembers each named voice, and later recordings recognise them by themselves (marked "Recognized"). The learned voices are listed in Settings > Automation (speaker section), where you can rename or delete them.
        """
    )

    static let dictionary = HelpGuideTopic(
        id: "dictionary",
        title: "Dictionary",
        icon: "character.book.closed",
        summary: "Teaching MinuteMind names and terms so transcripts and dictation spell them right.",
        body: """
        Settings > Dictionary holds terms MinuteMind should always get right: the correct spelling plus, optionally, the forms it is misheard as (for example "Auth0", heard as "auth zero").

        - The heard-as forms are replaced whole-word after every transcription, in live transcripts and in quick dictation.
        - All terms help the speech engine and Claude's transcript correction.

        Add, edit or delete entries there, or ask Claude ("add Kubernetes to my dictionary, it is often heard as cooper netties").
        """
    )

    static let summaries = HelpGuideTopic(
        id: "summaries",
        title: "Summaries and Claude Model",
        icon: "sparkles",
        summary: "How summaries, titles and todos are made, the Claude model, and summary prompts.",
        body: """
        MinuteMind uses Claude through your installed Claude Code (your own Claude subscription, no API key). Settings > AI shows whether Claude Code is found.

        ## What processing produces

        - A **summary** (the meeting minutes, in Markdown) written with the selected summary prompt.
        - A **title** for the meeting.
        - **Todos**, added to the project's tasks directly or shown on the recording card for review first ("Auto-accept extracted tasks", Settings > Automation > Pipeline; projects can override it in their menu).
        - **Knowledge** in the project's workspace (see Knowledge).

        ## Model

        Settings > AI > Model: Haiku (fastest), Sonnet (the balance, recommended) or Opus (most thorough). Used for summaries, titles, todos and knowledge. Transcript correction always uses Sonnet; the voice assistant has its own model.

        ## Summary prompts

        Settings > AI > Summary Prompts holds the instructions for the summary. Add your own prompt (for example a format your team uses) and select it; the selected prompt is used for every new summary.
        """
    )

    static let quickDictation = HelpGuideTopic(
        id: "quick-dictation",
        title: "Quick Dictation",
        icon: "mic.badge.plus",
        summary: "Dictating into any app with fn, quick recordings by double tap, live dictation and the Clipboard history.",
        body: """
        ## Dictate into any app

        Hold **fn** (the default), speak, and release: the text is typed wherever your cursor is. Settings > Automation > Quick Dictation chooses the trigger (hold fn, hold the right Option key, or press Ctrl+Opt+D to start and again to insert) and the language. The dictionary's corrections apply.

        - Typing into other apps needs the Accessibility permission; without it the text goes to the clipboard.
        - For fn to be free, set "Press 🌐 key to" to "Do Nothing" in macOS Keyboard settings, and move macOS dictation's shortcut away from "Press 🌐 twice".
        - The bar beside the companion shows a waveform while you speak; it waits for the microphone to be ready before it says "Listening".

        ## Quick recordings

        With a hold key, **double tap** it to start a quick recording (a voice note, not a meeting) and press it once more to stop. Quick recordings shorter than 2 seconds are dropped. Give one a project on its card and it is filed under recordings/ in that project's workspace. Recordings started with the mouse only stop with the mouse. Switch it off with "Double tap to record".

        ## Live dictation

        Shift+Cmd+D opens live dictation with a running transcript (Apple Speech).

        ## Clipboard

        Clipboard in the sidebar lists everything you dictated and every voice assistant answer, newest first. The companion's card also has a clipboard button with the last 20 things you copied anywhere.

        Holding the key together with Control calls the voice assistant instead (see Voice Assistant).
        """
    )

    static let voiceAssistant = HelpGuideTopic(
        id: "voice-assistant",
        title: "Voice Assistant (Claude mini tasks)",
        icon: "waveform.and.mic",
        summary: "Asking Claude by voice from any app with fn + Control, and its settings.",
        body: """
        Hold your dictation key (fn by default) **together with Control**, say what you want, and release. Control may come first. Claude Code runs in the background with your MinuteMind data and web search, and:

        - **types the result** where your cursor is when a text field has focus (a rewrite, a reply, a translation), or shows it in a card with Copy and Insert;
        - **does something** and shows a done card (create a task, process a meeting, change a setting);
        - or **asks you** a question in a card; type or dictate the answer and it continues.

        Text you have selected in the front app goes along, so "make this friendlier" works on the selection. One task runs at a time; the companion shows it working, and its right-click menu offers Cancel Claude Task.

        ## Settings

        Settings > Automation > Quick Dictation > Claude mini tasks: switch it on or off, choose its model (Sonnet recommended, Haiku fastest, Opus best), "Let Claude run terminal commands" (off limits it to MinuteMind and the web), and your standing instructions sent with every task (tone, language, who you are). Deleting things in MinuteMind is never allowed from the voice assistant.

        Needs Claude Code and a hold key (fn or right Option).
        """
    )

    static let companion = HelpGuideTopic(
        id: "companion",
        title: "Desktop Companion",
        icon: "face.smiling",
        summary: "The pixel creature: clicks, menu, project creatures, Claude session notices and its look.",
        body: """
        The companion is a small pixel creature, docked by default in the bottom right corner of the MinuteMind window. Drag it out to let it float anywhere; drop it near the corner (or use Dock to MinuteMind Window in its menu) to dock it again.

        ## Gestures

        - **Click:** its card with Record, Claude, Bring Claude Windows Here, Open MinuteMind, the dictation hint and Claude sessions that need you.
        - **Double click:** fans out every window with a running Claude session beside it; double click again to put them back.
        - **Right click:** Record or Stop, sessions that need you, Claude, Bring Claude Windows Here, Open MinuteMind, Notify When Claude Finishes, Reset Position, Hide Companion (Window > Show Companion brings it back).
        - **Scroll** over it while recording to pick the project (see Inbox and Processing).
        - **Shake the mouse** and it runs to the pointer (can be switched off).

        Its mood shows what is going on: headphones while recording, typing while Claude works, "!" when a Claude session waits for you, a cheer when something is done, asleep after 5 idle minutes.

        ## Claude sessions

        When a Claude session in any workspace waits for you, finishes a long turn or hits an error, the companion tells you. Click the notice to answer right there: Allow or Deny a tool, pick an option, or type a reply, without switching windows. Open Session jumps to it.

        ## Project creatures

        A project can have its own creature (sidebar right click > Companion or Edit Project..., or when creating the project), in its own colour if you pick one in Edit Project.... While that project runs Claude sessions its creature stands next to the companion and shows their state; when one needs you it steps to the front. Click a small one to bring it forward, double click to open its session.

        ## Appearance

        Settings > Appearance > Companion: show or hide it, the creature (blob, duck, dog, puppy, pug, several cats, lime), size, colour, "come to the pointer when I shake the mouse" with a Sensitivity slider below it (Gentle: two short flips are enough, Hard: five wide ones), and "Show the companion in screen shares" (off by default, so others do not see it).
        """
    )

    static let projects = HelpGuideTopic(
        id: "projects",
        title: "Projects",
        icon: "folder",
        summary: "Creating, arranging, starring and configuring projects, Home, moving around (back, forward, Option+Tab, the Cmd+K search) and the General workspace.",
        body: """
        Projects group meetings, tasks, knowledge and a workspace folder. Create one with the + button in the sidebar (New Project: name and optional companion creature; or Join shared, see Shared Projects). Projects have no colour of their own: their creature identifies them everywhere (sidebar, switcher, lists, calendar, the project wheel).

        ## In the sidebar

        - Right click a project: Star / Unstar (starred projects come first in the project wheel and show their creature or a star, and are always in the project switcher), Edit Project..., Companion (its creature), Make Shared Project..., Arrange Projects.
        - **Edit Project...** (also a right click on the project's name at the top of its own sidebar, or on its creature in the switcher) opens the project settings: name, companion creature, avatar colour (Default is the creature's natural colour; Own Colour opens the system colour panel with wheel, sliders and hex code, and paints the creature's body only, the headphones and other details keep theirs) and the export folder.
        - Long press a project (or Arrange Projects) to drag the projects into your order.

        ## Inside a project

        Entering a project (a tile on Home, or its row in the sidebar) gives the sidebar to the project: at the top its creature and name (click it to go back Home), then three sections: **Overview** (tasks and recordings), **Workspace** (the project folder with Claude Code, see Workspace) and **Jobs** (scheduled Claude jobs), then its Agents (the open Claude sessions), the project's files and its branch row. Each project remembers its last section; the first visit opens Workspace. The menu in the Overview header has Rename Project, Project Settings... (the same sheet as Edit Project...: name, companion, avatar colour and the export folder for transcripts and summaries), the project's own task auto-accept choice, and Delete Project.

        A project without a creature of its own shows a Blob (in its avatar colour, if set); General shows your companion.

        ## Moving around

        - **Back and forward:** the back and forward buttons of your mouse (buttons 4 and 5) step through the places you visited: pages, projects and their sections.
        - **Switch projects:** hold Option and press Tab. The switcher shows your starred projects and every project with a running Claude session, each creature with its project's name below; open the others from Home or the sidebar. The projects you used last come first, so one Option+Tab jumps back to the previous project. Keep holding Option and press Tab again to move on (the arrow keys go both ways), let go of Option to enter the highlighted project, Esc cancels. A click on a creature enters it too. It works in the terminal and the editor too, so Shift+Tab stays free for Claude Code's modes.
        - **Search everything:** press Cmd+K anywhere in the main window, also in the terminal or the editor. Type to find pages, Settings pages, projects, Claude sessions, meetings by their title and by what was said in their transcript or written in their summary, knowledge files and menu commands. Up and Down move through the results, Return opens one, Esc or Cmd+K again closes the search. A meeting found in its transcript opens the transcript showing only the lines with your search words; one found in its summary opens the Summary; a knowledge file opens in its project's Workspace; a Claude session comes forward.

        ## General

        General is the workspace for meetings filed without a project. Entering it works like a project, with its own Workspace and Jobs. The Claude (General) window, opened from the companion, runs Claude in this folder.
        """
    )

    static let workspace = HelpGuideTopic(
        id: "workspace",
        title: "Project Workspace and Claude Code",
        icon: "terminal",
        summary: "The workspace folder, its files in the sidebar, the editor, Claude Code sessions, terminals, splits and git branches.",
        body: """
        Every project has a workspace: a folder (a git repository) holding its processed meetings (meetings/), quick recordings (recordings/), knowledge (knowledge/), jobs (jobs/) and anything you or Claude add, such as plans, notes or cloned code. Its CLAUDE.md tells Claude what the folder is; text you add outside the MinuteMind block is kept.

        ## The Workspace

        - **Agents** in the project's sidebar: every open Claude session of the project with a dot for its state: blue working, orange waiting for you (or stopped with an error), grey idle. Click one to open it in the Workspace.
        - **Files** in the project's sidebar: browse, drag to move (Option copies), rename, New File / New Folder, Duplicate, Copy Path, Move to Trash (Cmd+Delete). meetings/, recordings/, knowledge/ and CLAUDE.md stay in place. The folder button beside Files shows the folder in Finder.
        - **Editor:** click a file to open it (from any section, it switches to Workspace), with syntax colours, a Markdown preview, images and PDFs. Changes save by themselves; double click opens a file in its usual app.
        - **Claude Code:** up to six sessions per project in tabs (the sparkle button; right click for Sonnet instead of Opus), plus plain terminals (Shift+Opt+Cmd+N). Opt+Cmd+Left/Right switches sessions. Each pane's frame shows its state: blue working, orange waiting for you, green done, red error.
        - **Layout:** Claude sits below the file (default), beside it, or in its own window (buttons in Claude's tab strip). Drag a tab onto a pane to split it, or use Split Right / Split Down in the tab's menu; drag a tab out to give it its own window.
        - **Branch row** at the bottom of the project's sidebar: the checked-out git branch; switch or create branches there. Uncommitted changes come along or are kept for you on the branch you leave. If it says "git is not installed", click Install: it opens Apple's installer for the Command Line Tools (or run `xcode-select --install` in Terminal). Until then the workspace keeps no history and Shared Projects cannot sync.

        Claude in the workspace has MinuteMind's tools, so it can read meetings, tasks, the calendar and the knowledge, and change settings.
        """
    )

    static let knowledge = HelpGuideTopic(
        id: "knowledge",
        title: "Knowledge",
        icon: "brain",
        summary: "Project knowledge: how it is built from meetings, where it lives, and how to search it.",
        body: """
        Each workspace has a knowledge/ folder with one Markdown file per topic (architecture, decisions, people, glossary and so on). After a meeting is processed Claude adds what matters to these files, every point citing the meeting it came from. When a meeting moves to another project its knowledge moves with it.

        - Read and edit the files in the Workspace tab like any other file.
        - Ask Claude ("what did we decide about the API?"); it searches the knowledge of every project.
        - Ask Claude to remember something ("save that we use Postgres 16"); it is written into the knowledge too.
        - The search index can be rebuilt in Settings > Storage > Search index.
        """
    )

    static let jobs = HelpGuideTopic(
        id: "jobs",
        title: "Scheduled Jobs",
        icon: "clock.arrow.circlepath",
        summary: "Prompts Claude runs on a schedule in a workspace: schedules, access levels, notifications.",
        body: """
        A job is a prompt Claude runs on a schedule inside a project's workspace (or General), for example "every Monday at 9, write a status update from last week's meetings into status.md".

        ## Setting one up

        Project > Jobs (General: Workspace / Jobs switch). The editor sets:

        - **Schedule:** hourly (every full hour between a start and end time), daily at a time, both optionally on chosen weekdays only, or weekly on one day.
        - **Access:** read only (reads files, the web, MinuteMind and your Claude connectors), standard (also edits files, changes MinuteMind data without deleting, and can send or change things through your connectors) or full (also terminal commands and deleting).
        - **Model** and **notify** (always, only on failures, never).

        ## Connectors (Outlook, Slack, ...)

        Jobs can use the connectors of your Claude account, for example Microsoft 365 (Outlook mail and calendar, Teams) or Slack, so a morning briefing can read your mail. A connector must be connected in Claude first. Read-only jobs get only the tools that search or read (a tool whose name says send, create, update, upload and the like is refused); standard and full jobs get every connector tool. Other MCP servers you added to Claude Code yourself are not available to jobs.

        Run Now runs it at once, Stop cancels. Each run's answer is saved and opens from the list or the notification.

        Jobs only run while MinuteMind is open (Settings > Automation > Startup can open it at login). A slot missed while the app was closed runs once when it opens. Claude can create, change and run jobs for you. In a Shared Project jobs stay private to you.
        """
    )

    static let sharedProjects = HelpGuideTopic(
        id: "shared-projects",
        title: "Shared Projects",
        icon: "person.2",
        summary: "Sharing a project with teammates: making one shared, joining, publishing meetings, sync.",
        body: """
        A Shared Project lets several MinuteMind users work in one project: published meetings and recordings and one shared knowledge, synced through a private GitHub or GitLab repository. Each person decides per meeting what leaves their Mac.

        ## Sharing a project

        Sidebar right click > Make Shared Project.... MinuteMind asks for your display name once (Settings > Integrations > Shared Projects), then Claude walks you through it in the Workspace: which existing meetings and recordings to publish, which files stay private, and it creates the private repository. Whoever shares first is the project's admin and invites teammates as collaborators on that repository.

        ## Joining

        New Project > Join shared, and paste the repository URL you were invited to.

        ## Publishing

        After each recording filed to a Shared Project the card asks "Share with the team?": Publish or Keep private. No answer means private. Private items live under private/ in the workspace and never leave your Mac; to publish one later, right click its folder under private/meetings or private/recordings > Publish.... Publishing cannot be taken back.

        ## Sync

        MinuteMind syncs in the background (at launch, every 3 minutes, after changes) while you are on the main branch. Every file you add, change or delete in the workspace reaches the other members, except private/, jobs/ and code/. The branch row shows "Synced 2 min ago" and Sync now; problems show in orange there and as a dot on the project in the sidebar.

        Files over 50 MB stay on your Mac: the branch row shows "1 file not synced", and a click on it lists them with Sync anyway (remembered for that file; files over 100 MB cannot sync).

        When two members changed the same file, MinuteMind merges it: a file deleted by one and edited by the other keeps the edit, and text both edited is merged by Claude. The commit "Sync: merge with the other members' changes" names the merged files. What cannot be merged (binary files, or without Claude Code) shows as "Sync conflict in <file>".
        """
    )

    static let calendar = HelpGuideTopic(
        id: "calendar",
        title: "Calendar",
        icon: "calendar",
        summary: "The calendar view, linking event series to projects, auto-record per event, event notes.",
        body: """
        Calendar in the sidebar shows your macOS calendars (Calendar permission needed) as a list and a week view. Click an event to open its details:

        - **Project:** link the event (for a recurring meeting the whole series) to a project, so its recordings are filed there automatically.
        - **Auto-record:** record this event by itself at its start time (needs "Start recording automatically at event time" in Settings > Automation > Auto-recording).
        - **Language** for its transcription, if it differs from your default.
        - **Notes** for the event.

        Once a day, the first time you open MinuteMind, a small briefing asks which of today's meetings to record.

        Claude can list, search, create and delete calendar events for you.
        """
    )

    static let tasks = HelpGuideTopic(
        id: "tasks",
        title: "Tasks",
        icon: "checklist",
        summary: "Tasks from meetings, All Tasks, Task Commander, Apple Reminders sync and review reminders.",
        body: """
        - **From meetings:** processing extracts todos. They go straight into the project's tasks or wait on the recording card for review ("Auto-accept extracted tasks", Settings > Automation > Pipeline; per project in the project menu).
        - **A project's tasks** are on its Overview tab; **All Tasks** in the sidebar lists every open task.
        - **Task Commander:** Shift+Cmd+T from anywhere for quick task entry and the open task list.
        - **Apple Reminders:** "Sync tasks to Apple Reminders by default" (Settings > Automation > Reminders Sync) decides whether new tasks also go to Reminders; each task can override it.
        - **Task review reminders:** times of day when MinuteMind sends a short Claude-written brief of your open tasks (Settings > Automation > Task Review Reminders).
        - **Board:** tasks can carry a status (backlog, todo, in progress, review, done) and belong to epics; Claude can manage both and summarise the board.

        Claude can list, create, update and delete tasks and reminders for you.
        """
    )

    static let claudeIntegration = HelpGuideTopic(
        id: "claude-integration",
        title: "Claude and the MCP Server",
        icon: "point.3.connected.trianglepath.dotted",
        summary: "How Claude Code and Claude Desktop reach MinuteMind, what Claude can do there, and the MCP settings.",
        body: """
        MinuteMind runs a local MCP server so Claude can work with your data. It only listens on this Mac and needs an access token.

        ## Connecting

        - **Claude Code:** the first-launch setup registers MinuteMind with one click. Settings > Integrations > Claude Code shows the command to do it by hand. Claude sessions in MinuteMind's workspaces are always connected.
        - **Claude Desktop:** Settings > Integrations > Claude Desktop shows the configuration to paste.
        - Settings > Integrations > MCP server switches the server on or off and sets its port (47821 by default); Access token shows and renews the token. Renewing it disconnects clients until they get the new one.

        ## What Claude can do in MinuteMind

        - Meetings: list, read, rename, delete, process; the Inbox.
        - Projects, tasks, epics and the board summary; notes; calendar events; Apple Reminders.
        - Knowledge: search and save.
        - Dictionary entries; scheduled jobs (create, change, run).
        - **Help:** read this guide (get_help) to answer questions about MinuteMind.
        - **Settings:** list every setting with its current value and change it (list_settings, update_setting). Only the MCP server's own settings cannot be changed this way.
        - **App:** open a place in MinuteMind (a Settings page, a project tab, Inbox, Calendar) and start or stop a recording.
        - **Troubleshooting:** check MinuteMind's health (models, permissions, Claude Code, failed meetings, sync, jobs), read its log, and repair what the app can fix itself, such as reinstalling Parakeet or retrying a meeting (see Troubleshooting).

        Deleting asks for your confirmation in Claude. Meeting transcripts are treated as other people's words: Claude does not follow instructions found in them.

        ## Claude inside MinuteMind

        The Workspace tab of every project, the Claude (General) window (from the companion), the voice assistant and scheduled jobs all run Claude Code with these tools.
        """
    )

    static let appearance = HelpGuideTopic(
        id: "appearance",
        title: "Appearance and Themes",
        icon: "paintpalette",
        summary: "Themes, custom colours and saved profiles, light and dark mode.",
        body: """
        Settings > Appearance:

        - **Theme:** Studio (standard macOS look, the default), Ember (warm paper and terracotta), Midnight (deep navy and cyan), Voltage (electric violet and lime), or Custom.
        - **Custom:** start from a built-in theme and set accent, background, card and border colours for light and dark. Save custom colours as named profiles; they appear next to the built-in themes and can be renamed or deleted.
        - **Mode:** System, Light or Dark.
        - **Companion:** see Desktop Companion.

        The workspace terminal and Claude follow the theme's colours.
        """
    )

    static let storage = HelpGuideTopic(
        id: "storage",
        title: "Storage",
        icon: "externaldrive",
        summary: "How much space recordings use, archiving audio, and rebuilding the search index.",
        body: """
        Settings > Storage shows the space your recordings use in total, per project, and the largest recordings.

        - **Archive** a recording: re-encode its audio smaller (32 kbps mono) or delete the audio and keep the transcript and summary. Both cannot be undone.
        - **Bulk archive** every recording older than a chosen number of days.
        - **Search index:** rebuild the knowledge search index if search results look stale.

        Audio is deleted automatically 14 days after recording unless "Keep audio" is ticked on its card (see Recording Meetings).
        """
    )

    static let settings = HelpGuideTopic(
        id: "settings",
        title: "Settings Overview",
        icon: "gearshape",
        summary: "What each Settings page holds; Claude can also list and change settings for you.",
        body: """
        Open Settings with the gear at the bottom of the sidebar or Cmd+,. Pages:

        - **Automation:** Startup (open MinuteMind at login, needed for jobs and meeting detection), Auto-recording, Live Dictation (default language), Quick Dictation (with Claude mini tasks), Parakeet, Pipeline (processing, engine, audio cleanup, name correction, speakers, task auto-accept), Task Review Reminders, Reminders Sync.
        - **Audio:** the microphone and your name in transcripts.
        - **Appearance:** theme, light or dark, the companion.
        - **AI:** Claude Code status, the Claude model, summary prompts.
        - **Dictionary:** terms and how they are misheard.
        - **Integrations:** the MCP server, access token, Claude Code and Claude Desktop setup, your display name for Shared Projects.
        - **Storage:** disk use, archiving, search index.
        - **Help:** this guide.

        Ask Claude to change a setting ("turn off double tap to record", "use Opus for summaries"): it can list every setting with its current value and change it. The MCP server's own switch and port are changed in Settings only.
        """
    )

    static let shortcuts = HelpGuideTopic(
        id: "shortcuts",
        title: "Keyboard Shortcuts",
        icon: "keyboard",
        summary: "Every keyboard shortcut and key gesture in MinuteMind.",
        body: """
        ## Anywhere on the Mac

        - **Hold fn** (or right Option, per Settings): quick dictation; release to insert.
        - **Ctrl+Opt+D:** quick dictation when the trigger is set to press-to-start.
        - **Double tap fn:** start a quick recording; press again to stop.
        - **fn + Control (hold):** voice assistant.
        - **Shift+Cmd+T:** Task Commander.
        - **Shift+Cmd+D:** live dictation.

        ## In MinuteMind

        - **Cmd+,:** Settings. **Cmd+I:** Import Audio. **Ctrl+Cmd+S:** show or hide the sidebar.
        - **Cmd+K:** search pages, projects, Claude sessions, meetings (titles, transcripts, summaries), knowledge and menu commands.
        - **Option+Tab (hold Option):** switch projects, also from the terminal and the editor. **Mouse buttons 4 and 5:** back and forward.
        - **Inbox:** Cmd+Return processes the selected meeting, Shift+Cmd+Return processes all, Cmd+Z undoes Skip.
        - **Workspace:** Shift+Opt+Cmd+N new terminal, Opt+Cmd+Left/Right switch sessions, Cmd+S save the open file, Cmd+Delete move the selected file to the Trash.
        - **Recordings:** Space plays or pauses the selected recording.
        """
    )
}
