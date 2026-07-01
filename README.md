# WakeUpKorea 🚨

## Introduction

Have you ever fell asleep on the subway or the bus and missed your stop? Or have you ever wanted to take a quick nap but couldn't because you were worried that you would miss your stop? **This app is built for you!** It's a **PROXIMITY-BASED ALARM APP** for Android, built for Korea's transit system. WakeUpKorea alerts you when you're approaching your destination so you never miss your stop again!

---

## 💡 Why I Built This

This app started as a personal learning project - my first Flutter app and my first backend server. From the beginning, I wanted it to be **a real lesson in app development and deployment and something genuinely useful to other people.** 

The idea came from **my own frustration**. Everytime I take the subway or the bus, I always found myself in the same situation - either anxiously checking Naver Maps or Google Maps every minute to see how close I am to my stop, or falling asleep and missing it entirely. I just wanted an app that would tap me on the shoulder and say "Hey, wake up, you're almost there." That app didn't exist the way I wanted it to, so I decided to build it myself. 

Taking on something this complex and new from scratch **wasn't easy**. There were moments during the development process where nothing worked and everything felt overwhelming. There were even moments where I felt the application wasn't worth publishing. But finishing it and watching it grow from a blank Flutter prompt into a real app on the Google Play Store was **one of the most rewarding things I've done**. It showed me what I'm capable of building and honestly fueled me even more to take on bigger projects. 

This experience didn't just teach me Flutter, backend, and API. It taught me how to think like a developer. 

---

## 🎬 Demonstration
<div align="center">
  <video controls src="WakeUpKorea_vid.mp4" width="300" title="WakeUpKorea Demo"></video>
</div>

---

## ⚙️ How it works

**You set a destination and an alarm distance**. The app tracks your GPS in the background — even when your phone is locked — and triggers the alarm with a full-screen notification when you get close enough. It keeps working while you sleep so you don't have to worry about missing your stop at all!

```
User searches destination
        ↓
Flutter app → Render backend → Naver Search API
        ↓
Coordinates returned to app
        ↓
User presses Start Monitoring
        ↓
Background service starts GPS stream
        ↓
Every 10 meters → calculates distance to destination
        ↓
Updates lock screen notification with live distance
        ↓
Distance ≤ alarm threshold → triggers full screen alarm
```

---

## ✨ Features

### Version 1
- **Location search** powered by Naver Local Search API (supports Korean place names like 서울역, 김포공항)
- **Background GPS tracking** that survives screen lock and app minimization
- **Live lock screen notification** showing distance remaining in real time
- **Full screen alarm** with sound, vibration, and a dismiss/snooze button
- **5 alarm sounds** to choose from
- **Alarm modes** — Sound Only, Vibrate Only, or Both
- **Favorites** — save, edit, and manage your frequent destinations
- **Search history** — remembers your last 10 searches
- **Adjustable alarm distance** from 100m to 2km via slider
- **Snooze** — re-triggers the alarm after 2 minutes
- **Korean** language supported. **English translation** is available!!

---

## 🛠️ Tech Stack

- **Flutter / Dart** — cross-platform mobile framework
- **Android** target (minimum SDK 21)
- **Node.js + Express** backend hosted on Render (for API key security)
- **Naver Developers Local Search API** for place search

### Flutter Packages Used

| Package | Purpose |
|---|---|
| `geolocator` | GPS location tracking |
| `flutter_background_service` | Keeps GPS running when app is in background |
| `flutter_local_notifications` | Lock screen and alarm notifications |
| `audioplayers` | Playing alarm sounds |
| `vibration` | Vibration control |
| `shared_preferences` | Persisting favorites and search history |
| `http` | API calls to the backend server |

---

## 📁 Project Structure

The full application source code is in the **`lib/`** folder:

```
wake_me_up/
├── lib/
│   └── main.dart          ← All app code lives here
├── assets/
│   ├── sounds/            ← Alarm sound files (.mp3)
│   └── icon/              ← App icon (.png)
├── android/               ← Android-specific configuration
│   └── app/src/main/
│       └── AndroidManifest.xml
└── pubspec.yaml           ← Dependencies and assets
```

### Key classes inside `main.dart`

| Class | What it does |
|---|---|
| `onStart()` | Background service — runs GPS tracking in a separate isolate |
| `HomePage` | Main screen with search, monitoring controls, and alarm settings |
| `FavoritesPage` | Manage saved locations |
| `SavedLocation` | Data model for a saved place |

---

## 🔒 Security

API keys are **not stored in this repository** or in the app binary. All Naver API calls are proxied through a private Node.js backend server hosted on Render. The backend repository is private.

If you want to run this project yourself you will need to:
1. Create your own [Naver Developers](https://developers.naver.com) account and [Naver Cloud Platform](https://www.ncloud.com/) account to get API keys for the Local Search API
2. Set up your own backend server with those keys as environment variables
3. Replace the Render URL in `main.dart` with your own server URL

---

## 📋 Permissions Required

| Permission | Why |
|---|---|
| `ACCESS_FINE_LOCATION` | Precise GPS tracking |
| `ACCESS_BACKGROUND_LOCATION` | GPS continues when screen is locked |
| `FOREGROUND_SERVICE` | Background service stays alive |
| `POST_NOTIFICATIONS` | Lock screen and alarm notifications |
| `WAKE_LOCK` | Keeps CPU awake to process GPS |
| `USE_FULL_SCREEN_INTENT` | Full screen alarm on lock screen |

---

## ֎ **Use of AI in Development**

A significant portion of this project **_involved the use of AI-assisted development_** tools like Chatgpt and Claude AI. While many people will be quick to judge my use of AI, I used AI not simply to generate the codes without any critical thinking but as **_a tool to better understand concepts, debug issues, and improve my own problem-solving process._**

Rather than asking AI to build the entire project from scratch, I approached the development phase by 
- **_planning_** the structure and features myself.
- **_attempting_** to create the application independently. 
- using AI **_selectively_** to solve specific technical obstacles.
- **_applying_** what I've learned to other parts of the project. 

Through this process, I was able to learn tremendously about Flutter, backend server, API usage, Application UI Design, and more. 

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

---

## 📬 Contact

For feedbacks, reviews, or questions, please feel free to contact me on

📧 [WNa0531@outlook.com](mailto:WNa0531@outlook.com)

---

# **_THANK YOU AND ENJOY!!_**