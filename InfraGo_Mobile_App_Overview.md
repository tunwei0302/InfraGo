# InfraGo: Next-Generation Mobile Application Overview

---

## 1. Executive Summary

**InfraGo** is an innovative, dual-role Flutter mobile application designed to advance **United Nations Sustainable Development Goal 9 (SDG 9: Industry, Innovation, and Infrastructure)** in Malaysia. It bridges commercial e-hailing operations with public infrastructure data transparency. 

By unifying both commuter (rider) and driver workflows into a single cross-platform mobile application, InfraGo delivers real-time trip planning, order dispatching, camera-based landmark verification, dynamic traffic telemetry analytics, and automated wait-time compensation rewards. The application actively consumes official public sector datasets from **data.gov.my** and **OpenDOSM**, transforming everyday commercial transport into a crowdsourced vector for public infrastructure intelligence and congestion reduction.

---

## 2. Core Problems & Proposed Solutions

### Problem 1: Data Integration Gap in E-Hailing Platforms
* **Issue:** Although official government transport and road telemetry datasets exist on portals like `data.gov.my`, commercial e-hailing apps operate as closed ecosystems that fail to consume or visualize public sector open data for their users.
* **Impact:** Drivers and commuters cannot view public infrastructure health metrics (such as national vehicle density or public transit ridership patterns) directly within their daily navigation tools.
* **InfraGo Solution:** Fetches open REST API feeds from `data.gov.my` and renders them into an interactive in-app **Analytics Dashboard** for public data transparency.

### Problem 2: First-Mile / Last-Mile Landmark Friction
* **Issue:** Standard GPS positioning often drops pins in ambiguous locations (e.g., sprawling shopping malls, multi-level train stations, or congested office lobbies).
* **Impact:** Causes driver idling, wasted fuel, pickup delays, increased carbon emissions, and rider frustration.
* **InfraGo Solution:** Incorporates mobile camera hardware via the `image_picker` package in booking forms so commuters can capture and attach real-time photos of their exact pickup landmark meeting point.

### Problem 3: Lack of Dual-Role Flexibility
* **Issue:** Mainstream applications rigidly separate rider and driver interfaces into two distinct apps, hindering smooth multi-role user experiences.
* **Impact:** Friction for users who both commute and drive, alongside increased app maintenance overhead.
* **InfraGo Solution:** Integrates both **Commuter Mode** and **Driver Mode** into a single Flutter codebase using global state management (`Provider`).

### Problem 4: City Traffic Inefficiency & Pickup Delays
* **Issue:** Poor driver dispatching, unmonitored peak-hour surges, and long waiting times aggravate urban congestion in Malaysian cities.
* **Impact:** Excessive wait times without transparency lead to rider drop-off and uncoordinated urban mobility.
* **InfraGo Solution:** Employs an **Automated Wait-Time Compensation Rewards** system using local SQLite storage (`sqflite`) and async timers to automatically award loyalty discount points to commuters if no driver accepts their ride request within 1 minute.

---

## 3. Four-Module Architectural Breakdown

The application is structured around a 4-member modular distribution, ensuring clear separation of concerns, high code maintainability, and alignment with Flutter/Dart paradigms:

```
                                  +---------------------------------------+
                                  |         ChangeNotifierProvider        |
                                  |          (Global App State)           |
                                  +---------------------------------------+
                                                      |
                  +-----------------------------------+-----------------------------------+
                  |                                   |                                   |
                  v                                   v                                   v
+-----------------------------------+   +-----------------------------------+   +-----------------------------------+
|             Module 1              |   |             Module 2              |   |             Module 3              |
|        Trip Planner & Maps        |   |       Rider Booking & Forms       |   |      Driver Hub & Orders          |
|    (UI, Navigation & LBS - M1)    |   |     (Forms & Hardware - M2)       |   |    (Driver Operations - M3)       |
+-----------------------------------+   +-----------------------------------+   +-----------------------------------+
                  |                                   |                                   |
                  +-----------------------------------+-----------------------------------+
                                                      |
                                                      v
                                  +---------------------------------------+
                                  |              Module 4                 |
                                  |  Open Data Analytics, State & Storage  |
                                  |     (Async API & Persistence - M4)    |
                                  +---------------------------------------+
```

### Module 1: Trip Planner & Maps (UI, Navigation & Location-Based Services)
* **Assigned Role:** Member 1 (The UI & Navigation Expert)
* **Primary Scope:** Renders the primary map canvas, manages real-time GPS tracking, and handles screen routing.
* **Technical Implementation:**
  * Uses a multi-child `Stack` widget overlaying UI control cards and floating action buttons over an interactive map canvas (`flutter_map` or `google_maps_flutter`).
  * Integrates device location plugins to retrieve latitude/longitude coordinates and display origin/destination polyline routes and driver marker overlays.
  * Controls screen routing using Flutter's `Navigator` stack (`Navigator.push()` and `Navigator.pop()`) to transition between map views and detailed transit schedules.

### Module 2: Rider Booking & Forms (Forms, Inputs & Hardware Integration)
* **Assigned Role:** Member 2 (The Input & Hardware Expert)
* **Primary Scope:** Manages ride package selections, passenger instructions, camera landmark attachments, and confirmation modals.
* **Technical Implementation:**
  * Form management built using native `Form` widgets bound to a `GlobalKey<FormState>()`.
  * Captures text inputs through `TextFormField` controls managed by individual `TextEditingController` instances.
  * Integrates the `image_picker` package to invoke device camera or photo gallery hardware, enabling riders to attach photos of pickup landmarks.
  * Employs `showDialog()` with custom `AlertDialog` widgets and `SnackBar` elements for interactive checkout confirmations and status alerts.

### Module 3: Driver Hub & Available Orders (Driver Operations & Dispatch)
* **Assigned Role:** Member 3 (The Driver Operations Expert)
* **Primary Scope:** Provides the Driver Profile view, Online/Offline master toggle switch, and incoming order dispatch feed.
* **Technical Implementation:**
  * Features a master switch control (`Switch` / `StatefulWidget`) toggling driver status between Online and Offline.
  * Builds a dynamic `ListView.builder` feed rendering nearby ride requests, complete with pickup distance, estimated fare, and location tags.
  * Implements order accept/reject action handlers with real-time state feedback dialogs.
  * Integrates driver identity verification mechanisms using camera photo capture for vehicle road tax and identity validation.

### Module 4: Global State, Open Data Analytics & Rewards (State, Async Networking & Persistence)
* **Assigned Role:** Member 4 (The Data, Network & State Expert)
* **Primary Scope:** Controls the global role switcher, executes asynchronous REST API queries to `data.gov.my`, and manages persistent local storage.
* **Technical Implementation:**
  * **Global State Management:** Uses `Provider` with `ChangeNotifier` to seamlessly switch the application viewport between Commuter Mode and Driver Mode globally without destroying widget tree states.
  * **Asynchronous Networking:** Uses the `http` package to execute asynchronous GET requests (`http.get()`) targeting `data.gov.my` endpoints.
  * **JSON Deserialization:** Performs manual JSON parsing (`jsonDecode()`) into strongly-typed Dart model classes featuring `factory Model.fromJson()` constructors.
  * **Async Rendering:** Binds network futures to `FutureBuilder` / `StreamBuilder` widgets to display loading indicators (`CircularProgressIndicator`) before rendering dynamic traffic health charts.
  * **Local Persistence:** Uses `shared_preferences` for key-value caching (auth tokens, active theme, user role) and `sqflite` (SQLite singleton via `DatabaseHelper`) to log trip history and calculate off-peak carbon offset telemetry offline.

---

## 4. Open Data Integration Strategy (data.gov.my)

InfraGo utilizes four core open datasets retrieved directly from Malaysia's official open data portal to drive public transparency and fulfill SDG 9:

| Dataset Name & Source | Retrieved Variables | In-App Purpose & Value Proposition |
| :--- | :--- | :--- |
| **JPJ Vehicle Registrations**<br>*(Road Transport Dept / MOT)* | `date_reg`, `type` (car, motorcycle, van), `fuel` (petrol, electric, hybrid), `state` | **Road Infrastructure Telemetry:** Visualizes national/state EV vs. petrol adoption and vehicle growth trends to explain regional congestion patterns. |
| **Prasarana & KTMB Daily Ridership**<br>*(Prasarana / KTMB)* | `date`, `service` (LRT, MRT, Monorail, KTM, Bus), `ridership` | **Public Transit Health Index:** Displays daily peak-hour passenger volume graphs across transit corridors to encourage first-mile/last-mile e-hailing connections. |
| **MOF Weekly Fuel Prices**<br>*(Ministry of Finance)* | `date`, `ron95`, `ron97`, `diesel` (MYR/Liter) | **Transparent Fare & Earnings Estimator:** Provides transparent pricing logic for commuters and allows drivers to calculate net earnings based on real-time fuel benchmarks. |
| **GTFS Realtime Vehicle Positions**<br>*(Prasarana / MOT)* | `latitude`, `longitude`, `speed`, `timestamp` | **Multi-Modal Route Optimization:** Displays live bus/rail stop markers and fleet positions on the map canvas to help users combine e-hailing with public transit. |

---

## 5. Technology Stack & Technical Specifications

* **Core Framework:** Flutter (Dart SDK)
* **Programming Language:** Dart (Strongly typed, object-oriented, asynchronous `async`/`await`, Futures, Streams)
* **State Management:** `provider` (`ChangeNotifier`, `Consumer`, `MultiProvider`)
* **Navigation & Routing:** Flutter `Navigator` (`push`, `pop`, Material Page Routes)
* **Database & Caching:** * `sqflite` (Relational SQLite database using singleton `DatabaseHelper`)
  * `shared_preferences` (Key-value lightweight persistent storage)
* **Networking & Data Format:** `http` package, `dart:convert` (`jsonDecode`, `jsonEncode`), REST APIs
* **Hardware & Location Services:** `image_picker` (Camera & Gallery access), `geolocator`, `geocoding`, `flutter_map` / `google_maps_flutter`
* **Target Platforms:** Android & iOS

---

## 6. Architecture & Reactive UI Principles

In accordance with Flutter's architectural principles:
1. **Declarative UI:** The user interface is a direct function of state: $\text{UI} = f(\text{State})$.
2. **Unidirectional Data Flow:** Data flows down through the widget tree, while events (e.g., button taps, API responses) flow up through callbacks and state notifications (`notifyListeners()`).
3. **App Lifecycle Awareness:** Handles lifecycle transitions (`resumed`, `paused`, `inactive`, `detached`) using `AppLifecycleListener` to pause background timers, release hardware camera locks, and finalize SQLite database writes safely.

---

## 7. Conclusion

**InfraGo** demonstrates how commercial mobile app platforms can be leveraged to address public infrastructure challenges in Malaysia. By combining a dual-role commuter/driver Flutter application with camera-based landmark verification, local SQLite delay tracking, and real-time open data streams from `data.gov.my`, InfraGo fulfills UN SDG 9 by driving resilient, transparent, and sustainable urban mobility.
