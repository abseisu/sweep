# Inbox Ledger — Architecture & Setup Guide

## Architecture Map

```
InboxLedger/
├── App/
│   ├── InboxLedgerApp.swift          — App entry point, scene config, notification setup
│   └── AppState.swift                — ObservableObject holding global auth + email state
│
├── Models/
│   ├── LedgerEmail.swift             — Core data model for a triaged email
│   └── AIResponse.swift              — Model for AI summary + draft response
│
├── Managers/
│   ├── GmailManager.swift            — Google Sign-In, OAuth, Gmail REST API (fetch/send)
│   ├── AIManager.swift               — LLM integration (OpenAI API) for summarization + drafts
│   └── NotificationManager.swift     — Local notification scheduling
│
├── Views/
│   ├── ContentView.swift             — Root view: auth gate → Dashboard
│   ├── DashboardView.swift           — "Clean the Ledger" card stack
│   ├── EmailCardView.swift           — Individual swipeable email card
│   ├── DraftEditorView.swift         — Editable AI draft + Send button
│   └── SettingsView.swift            — Notification time picker
│
├── Extensions/
│   └── Date+Extensions.swift         — Helper for "24 hours ago" queries
│
├── Info.plist                        — URL schemes for Google OAuth callback
└── README.md                         — This file
```

---

## Setup Guide

### Step 1: Google Cloud Console

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project called "Inbox Ledger"
3. Enable the **Gmail API** under "APIs & Services → Library"
4. Go to **"APIs & Services → Credentials"**
5. Click **"Create Credentials → OAuth 2.0 Client ID"**
6. Select **"iOS"** as the application type
7. Enter your app's **Bundle Identifier** (e.g., `com.yourname.InboxLedger`)
8. Copy the generated **Client ID** — you'll paste this into `GmailManager.swift`

### Step 2: OAuth Consent Screen

1. Go to **"APIs & Services → OAuth consent screen"**
2. Set User Type to **External** (for testing)
3. Fill in the App name: "Inbox Ledger"
4. Add your email as a test user
5. Add the following **scopes**:
   - `https://www.googleapis.com/auth/gmail.readonly`
   - `https://www.googleapis.com/auth/gmail.send`
   - `https://www.googleapis.com/auth/gmail.modify`

### Step 3: Xcode Project Setup

1. Create a new Xcode project (iOS → App, SwiftUI lifecycle)
2. Add the following **Swift Packages**:
   - `https://github.com/google/GoogleSignIn-iOS` (Google Sign-In SDK)
3. Copy all `.swift` files from this repo into the project
4. Configure `Info.plist` (see below)

### Step 4: Info.plist Configuration

Add the following to your `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <!-- Reversed Client ID from Google Cloud Console -->
            <string>com.googleusercontent.apps.YOUR_CLIENT_ID_HERE</string>
        </array>
    </dict>
</array>
<key>GIDClientID</key>
<string>YOUR_CLIENT_ID_HERE.apps.googleusercontent.com</string>
```

### Step 5: API Keys

Open `AIManager.swift` and replace:
```swift
private let apiKey = "YOUR_OPENAI_API_KEY"
```

Open `GmailManager.swift` and replace:
```swift
private let clientID = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
```

### Step 6: Run

1. Build & run on a physical device or simulator
2. Sign in with your Google account
3. Grant Gmail permissions
4. Your last 24 hours of unread emails appear as cards
5. Swipe right to send, swipe left to dismiss

---

## Key Design Decisions

- **No external DB** — all state is in-memory via `@Published` properties
- **Happy path focus** — minimal error handling, no offline caching
- **Modular managers** — Gmail, AI, and Notifications are fully decoupled
- **REST-only Gmail** — no Google Client Library bloat; raw URLSession calls
- **Ranking algorithm** — scores by sender frequency × recency × unread status
