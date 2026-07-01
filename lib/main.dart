import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart'; 
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
AudioPlayer? globalAudioPlayer;

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  double? targetLat;
  double? targetLng;
  double alarmDistance = 750;
  StreamSubscription<Position>? positionStream;
  DateTime? lastNotificationTime;

  service.on('startMonitoring').listen((data) {
    if (data == null) return;

    targetLat = (data['latitude'] as num).toDouble();
    targetLng = (data['longitude'] as num).toDouble();
    alarmDistance = (data['alarmDistance'] as num).toDouble();

    positionStream?.cancel();

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) async {
      if (targetLat == null || targetLng == null) return;

      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        targetLat!,
        targetLng!,
      );

      service.invoke('distanceUpdate', {'distance': distance});

      final now = DateTime.now();
      if (lastNotificationTime == null ||
          now.difference(lastNotificationTime!).inSeconds >= 5) {
        lastNotificationTime = now;

        final distanceText = distance >= 1000
            ? '${(distance / 1000).toStringAsFixed(1)} km remaining'
            : '${distance.toInt()} m remaining';

        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: 'WakeUpKorea',
            content: distanceText,
          );
        }
      }

      if (distance <= alarmDistance) {
        await positionStream?.cancel();
        positionStream = null;

        service.invoke('alarmTriggered', {});

        if (service is AndroidServiceInstance) {
          await service.stopSelf();
        }
      }
    });
  });

  service.on('stopMonitoring').listen((_) async {
    await positionStream?.cancel();
    positionStream = null;
    targetLat = null;
    targetLng = null;        // ← use local `notifications`
    await Future.delayed(const Duration(milliseconds: 300));

    if (service is AndroidServiceInstance) {
      await service.stopSelf();
    }
  });
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  const AndroidNotificationChannel monitoringChannel = AndroidNotificationChannel(
    'WakeUpKorea channel',
    'WakeUpKorea Service',
    description: 'Location monitoring service',
    importance: Importance.low,
    showBadge: true,
    playSound: false,
    enableLights: true,
  );

  const AndroidNotificationChannel alarmChannel = AndroidNotificationChannel(
    'WakeUpKorea alarm',
    'WakeUpKorea Alarm',
    description: 'Alarm notifications',
    importance: Importance.max,       // max so it shows on lock screen
    showBadge: true,
    playSound: false,                 // we play sound ourselves
    enableVibration: false,           // we handle vibration ourselves
  );

  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  await androidPlugin?.createNotificationChannel(monitoringChannel);
  await androidPlugin?.createNotificationChannel(alarmChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'WakeUpKorea channel',
      initialNotificationTitle: 'WakeUpKorea',
      initialNotificationContent: 'Monitoring your location...',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: const [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
    ),
  );
}

void main() async {
  
  WidgetsFlutterBinding.ensureInitialized();

  // 1. INIT NOTIFICATIONS
  const AndroidInitializationSettings androidInit =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initSettings =
      InitializationSettings(android: androidInit);

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) async {
      if (response.actionId == 'dismiss_alarm') {
        await globalAudioPlayer?.stop();
        Vibration.cancel();
        await flutterLocalNotificationsPlugin.cancel(888);
        await flutterLocalNotificationsPlugin.cancel(999);
        FlutterBackgroundService().invoke('stopMonitoring', {});
      }
    },
  );

  // 2. INIT BACKGROUND SERVICE
  await initializeService();

  runApp(const WakeUpKoreaApp());
}

class SavedLocation {
  String name;             // ← remove final so it can be changed
  final String address;
  final double latitude;
  final double longitude;

  SavedLocation({
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
  });
}

class WakeUpKoreaApp extends StatelessWidget {
  const WakeUpKoreaApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WakeUpKorea',
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {

  final AudioPlayer audioPlayer = AudioPlayer();
  final FlutterBackgroundService _service = FlutterBackgroundService();
  
  final TextEditingController destinationController = TextEditingController();
  String destination = "";
  double? latitude;
  double? longitude;
  List<SavedLocation> savedLocations = [];
  List<SavedLocation> searchResults = [];
  double alarmDistance = 750;
  String selectedAlarmSound = "Up Here";
  final List<String> alarmSounds = ["Up Here", "Electric", "Bowling", "Rings of Saturn", "Arcade"];
  bool isMonitoring = false;
  bool isPreviewing = false;
  bool _isSearching = false;
  Timer? _searchDebounce;
  double distanceRemaining = 0;
  StreamSubscription? _distanceSubscription;
  StreamSubscription? _alarmSubscription;
  List<String> searchHistory = [];
  bool _searchBarFocused = false; 
  String alarmMode = 'Both';

  final FocusNode _searchFocusNode = FocusNode(); 

  @override
  void initState() {
    super.initState();
    globalAudioPlayer = audioPlayer;
    loadFavorites();
    loadSearchHistory();
    _listenToService();
    // cancel any stale notifications from previous sessions
    Future.delayed(const Duration(milliseconds: 500), () {
      flutterLocalNotificationsPlugin.cancelAll();
    });
    _searchFocusNode.addListener(() {
      setState(() => _searchBarFocused = _searchFocusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _distanceSubscription?.cancel();
    _alarmSubscription?.cancel();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> showAlarmNotification() async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'WakeUpKorea alarm',
      'WakeUpKorea Alarm',
      channelDescription: 'Alarm notifications',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,           // ← this makes it show on lock screen
      autoCancel: false,
      ongoing: true,                    // ← can't swipe away
      visibility: NotificationVisibility.public,  // ← shows even on locked screen
      icon: '@mipmap/ic_launcher',
      actions: [
        AndroidNotificationAction(
          'dismiss_alarm',
          'Dismiss Alarm',              // ← button on lock screen
          cancelNotification: true,
          showsUserInterface: true,
        ),
      ],
    );

    await flutterLocalNotificationsPlugin.show(
      999,
      '⏰ Wake Up!',
      'You are approaching your destination!',
      const NotificationDetails(android: androidDetails),
    );
  }

  void _listenToService() {
    _distanceSubscription?.cancel();
    _alarmSubscription?.cancel();
    DateTime? lastUiUpdate;
    _distanceSubscription = _service.on('distanceUpdate').listen((data) {
      if (data == null) return;
      final now = DateTime.now();
      if (lastUiUpdate == null || now.difference(lastUiUpdate!).inSeconds >= 3) {
        lastUiUpdate = now;
        setState(() {
          distanceRemaining = (data['distance'] as num).toDouble();
        });
      }
    });

    _alarmSubscription = _service.on('alarmTriggered').listen((_) async {
      setState(() => isMonitoring = false);
      
      triggerAlarm();
    });
  }

  void addToSearchHistory(String query) {
    if (query.trim().isEmpty) return;
    setState(() {
      searchHistory.remove(query);        // remove duplicate if exists
      searchHistory.insert(0, query);     // add to front
      if (searchHistory.length > 10) {    // keep only last 10
        searchHistory = searchHistory.sublist(0, 10);
      }
    });
    saveSearchHistory();
  }

  Future<void> getCoordinates(String location) async {
    setState(() => _isSearching = true);
    final url = Uri.parse(
  "https://wakemeup-server.onrender.com/search?query=${Uri.encodeComponent(location)}",
);
    // Note: 10.0.2.2 is how Android emulators reach your computer's localhost
    // For a real device on the same WiFi, use your computer's local IP instead
    try {
      final response = await http.get(url); // no headers needed — server handles auth
      final data = jsonDecode(response.body);
      if (data["items"] != null && (data["items"] as List).isNotEmpty) {
        setState(() {
          destination = location;
          latitude = double.parse(data["items"][0]["mapy"]) / 1e7;
          longitude = double.parse(data["items"][0]["mapx"]) / 1e7;
          searchResults = (data["items"] as List).map<SavedLocation>((item) {
            return SavedLocation(
              name: item["title"].replaceAll(RegExp(r'<[^>]*>'), ''),
              address: item["roadAddress"] ?? item["address"] ?? "",
              latitude: double.parse(item["mapy"]) / 1e7,
              longitude: double.parse(item["mapx"]) / 1e7,
            );
          }).toList();
        });
      } else {
        setState(() {
          destination = location;
          latitude = null;
          longitude = null;
          searchResults = [];
        });
      }
    } catch (e) {
      setState(() {
        destination = location;
        latitude = null;
        longitude = null;
        searchResults = [];
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Search failed. Check your internet connection.")),
        );
      }
    } finally {
    setState(() => _isSearching = false); // ← hide spinner whether success or fail
    }
  }

  Future<void> updateDistancePreview() async {
    if (latitude == null || longitude == null) return;
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        latitude!,
        longitude!,
      );
      setState(() => distanceRemaining = distance);
    } catch (e) {
      // silently fail if GPS not available
    }
  }

  // saves favorites list to phone storage
  Future<void> saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = savedLocations.map((loc) => jsonEncode({
      "name": loc.name,
      "address": loc.address,
      "latitude": loc.latitude,
      "longitude": loc.longitude,
    })).toList();
    await prefs.setStringList("savedLocations", encoded);
  }

  // loads favorites list from phone storage
  Future<void> loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getStringList("savedLocations") ?? [];
    setState(() {
      savedLocations = encoded.map((str) {
        final map = jsonDecode(str);
        return SavedLocation(
          name: map["name"],
          address: map["address"],
          latitude: map["latitude"],
          longitude: map["longitude"],
        );
      }).toList();
    });
  }

  Future<void> saveSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList("searchHistory", searchHistory);
  }

  Future<void> loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      searchHistory = prefs.getStringList("searchHistory") ?? [];
    });
  }


  Future<void> startMonitoring() async {
    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    // ask user for GPS permission
    LocationPermission permission = await Geolocator.requestPermission(); // continuously listens to GPS and fires
    // request background location permission specifically
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    
    // everytime you move more than 10 meters
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Location permission denied")),
      );
      return;
    }

    setState(() => isMonitoring = true);

    // start background service
    // start background service
    await _service.startService();

    // wait a moment for service to fully initialize before sending commands
    await Future.delayed(const Duration(milliseconds: 500));

    // send destination and distance to background service
    _service.invoke('startMonitoring', {
      'latitude': latitude,
      'longitude': longitude,
      'alarmDistance': alarmDistance,
    });
  }

  Future<void> dismissAlarmAndStopService() async {
    await audioPlayer.stop();
    Vibration.cancel();
    await flutterLocalNotificationsPlugin.cancel(888);
    await flutterLocalNotificationsPlugin.cancel(999);
    _service.invoke('stopMonitoring', {});
  }

  Future<void> stopMonitoring() async {
    _service.invoke('stopMonitoring', {});
    await Future.delayed(const Duration(milliseconds: 500));
    await audioPlayer.stop();
    Vibration.cancel();
    await flutterLocalNotificationsPlugin.cancel(888);
    await flutterLocalNotificationsPlugin.cancel(999);
    // Give background isolate time to call setAsBackgroundService + stopSelf
    await Future.delayed(const Duration(milliseconds: 800));
    await flutterLocalNotificationsPlugin.cancelAll();
    if (!mounted) return;
    setState(() {
      isMonitoring = false;
      isPreviewing = false;
      distanceRemaining = 0;
    });
    // Re-attach listeners — your old code cancelled them permanently
    _listenToService();
  }

  void triggerAlarm() async {
    setState(() => isPreviewing = false);
    if (alarmMode == "Both" || alarmMode == "Sound Only") {
      await playAlarmSound();
    }
    await showAlarmNotification();
    if (alarmMode == "Both" || alarmMode == "Vibrate Only") {
      bool? hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(
          pattern: [0, 500, 200, 500, 200, 800],
          repeat: 0,
        );
      }
    }
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text("⏰ Wake Up!"),
        content: Text("You are approaching $destination!"),
        actions: [
          TextButton(
            onPressed: () async {
              await dismissAlarmAndStopService();
              if (!mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Snoozed for 2 minutes")),
              );
              Future.delayed(const Duration(minutes: 2), () {
                if (mounted) triggerAlarm();
              });
            },
            child: const Text("Snooze (2 min)", style: TextStyle(fontSize: 14)),
          ),
          TextButton(
            onPressed: () async {
              await dismissAlarmAndStopService();
              if (!mounted) return;
              Navigator.pop(context);
            },
            child: const Text("I'm awake!", style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Future<void> playAlarmSound() async {
    String fileName = "Uphere.mp3";
    switch (selectedAlarmSound) {
      case "Up Here":
        fileName = "Uphere.mp3";
        break;
      case "Electric":
        fileName = "Electric.mp3";
        break;
      case "Bowling":
        fileName = "Bowling.mp3";
        break;
      case "Rings of Saturn":
        fileName = "Rings-of-Saturn.mp3";
        break;
      case "Arcade":
        fileName = "Arcade.mp3";
        break;
    }
    await audioPlayer.stop();
    await audioPlayer.setReleaseMode(
      ReleaseMode.loop,
    );
    await audioPlayer.setVolume(1.0);
    await audioPlayer.play(
      AssetSource("sounds/$fileName"),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 380;
    return Scaffold(
      appBar: AppBar(
        title: const Text("WakeUpKorea"),
        actions: [
          IconButton(
            icon: const Icon(Icons.star),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FavoritesPage(
                    savedLocations: savedLocations,
                    onRemove: (location) {
                      setState(() {
                        savedLocations.removeWhere(
                          (s) => s.latitude == location.latitude && s.longitude == location.longitude,
                        );
                      });
                      saveFavorites();    // ← save after removing
                    },
                    onSetDestination: (location) {
                      setState(() {
                        destination = location.name;
                        destinationController.text = location.name; 
                        latitude = location.latitude;
                        longitude = location.longitude;
                      });
                      updateDistancePreview();
                    },
                    onAdd: (location) {
                      setState(() {
                        savedLocations.add(location);
                      });
                      saveFavorites();    // ← save after adding
                    },
                    onEdit: (location, newName) {
                      setState(() {
                        location.name = newName;
                      });
                      saveFavorites();    // ← save after editing
                    },
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 30),
            const Text(
              "Where are you going?",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),

            // search bar
            TextField(
              controller: destinationController,
              focusNode: _searchFocusNode,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.search,
              enableIMEPersonalizedLearning: true,
              onChanged: (value) {
                _searchDebounce?.cancel();   // cancel previous timer
                if (value.isEmpty) {
                  setState(() => searchResults = []);
                  return;
                }
                if (value.length >= 2) {
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 500),  // wait 500ms after last keystroke
                    () => getCoordinates(value),
                  );
                }
              },
              onSubmitted: (value) {
                addToSearchHistory(value);
                getCoordinates(value);
              },
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: "서울역 / Seoul Station",
                suffixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : destinationController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              destinationController.clear();
                              setState(() {
                                searchResults = [];
                                destination = "";
                                latitude = null;
                                longitude = null;
                              });
                            },
                          )
                        : const Icon(Icons.search),
              ),
            ),

            // search history shown when bar is empty
            if (searchResults.isEmpty && searchHistory.isNotEmpty && _searchBarFocused && destinationController.text.isEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Recent searches",
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                          GestureDetector(
                            onTap: () {
                              setState(() => searchHistory = []);
                              saveSearchHistory();
                            },
                            child: const Text("Clear",
                                style: TextStyle(fontSize: 12, color: Colors.blue)),
                          ),
                        ],
                      ),
                    ),
                    ...searchHistory.map((query) => Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.history, size: 18, color: Colors.grey),
                        title: Text(query, style: const TextStyle(fontSize: 14)),
                        onTap: () {
                          destinationController.text = query;
                          addToSearchHistory(query);
                          getCoordinates(query);
                          _searchFocusNode.unfocus();
                        },
                      ),
                    )),
                  ],
                ),
              ),

            // dropdown appears right below search bar
            if (searchResults.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: searchResults.length,
                  itemBuilder: (context, index) {
                    final result = searchResults[index];
                    final isSaved = savedLocations.any(
                      (s) => s.latitude == result.latitude && s.longitude == result.longitude,
                    );
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: false,
                        title: Text(result.name, style: const TextStyle(fontSize: 14)),
                        subtitle: Text(result.address, style: const TextStyle(fontSize: 12)),
                        trailing: IconButton(
                        icon: Icon(
                          isSaved ? Icons.star : Icons.star_border,
                          color: isSaved ? Colors.amber : Colors.grey,
                          size: 28,
                        ),
                        onPressed: () {
                          setState(() {
                            if (isSaved) {
                              savedLocations.removeWhere(
                                (s) => s.latitude == result.latitude && s.longitude == result.longitude,
                              );
                            } else {
                              savedLocations.add(result);
                            }
                          });
                          saveFavorites();    // ← save after starring from search
                        },
                      ),
                      onTap: () {
                        addToSearchHistory(destinationController.text);
                        setState(() {
                          destination = result.name;
                          latitude = result.latitude;
                          longitude = result.longitude;
                          searchResults = [];
                          destinationController.text = result.name;    // ← show name in bar
                        });
                        _searchFocusNode.unfocus(); 
                        updateDistancePreview();   // ← close keyboard and hide history
                      },
                    ));
                  },
                ),
              ),

            const SizedBox(height: 20),

            // start/stop button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isMonitoring ? Colors.red : Colors.blue,
                ),
                onPressed: () {
                  if (destination.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Please select a destination first")),
                    );
                    return;
                  }
                  if (isMonitoring) {
                    stopMonitoring();
                  } else {
                    startMonitoring();
                  }
                },
                child: Text(
                  isMonitoring ? "Stop Monitoring" : "Start Monitoring",
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 10),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  const Text(
                    "Monitoring Status",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 10),
                  Text("Destination: $destination"),
                  Text(
                    distanceRemaining >= 1000
                        ? "Distance Remaining: ${(distanceRemaining / 1000).toStringAsFixed(2)} km"
                        : "Distance Remaining: ${distanceRemaining.toInt()} m",
                  ),
                  Text(
                    alarmDistance >= 1000
                        ? "Alarm Distance: ${(alarmDistance / 1000).toStringAsFixed(1)} km"
                        : "Alarm Distance: ${alarmDistance.toInt()} m",
                  ),
                  Text(
                    "Status: ${isMonitoring ? "Monitoring..." : "Stopped"}",
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),
            // distance slider
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Distance", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Text(
                  alarmDistance >= 1000
                      ? "${(alarmDistance / 1000).toStringAsFixed(1)} km"
                      : "${alarmDistance.toInt()} m",
                  style: const TextStyle(fontSize: 16, color: Colors.blue),
                ),
              ],
            ),
            Slider(
              value: alarmDistance,
              min: 100,
              max: 2000,
              divisions: 38,
              activeColor: Colors.blue,
              onChanged: (value) {
                setState(() {
                  alarmDistance = value;
                });
              },
            ),

            const SizedBox(height: 20),

            // alarm sound label
            const Text("Alarm Sound", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),

            // mode selector + preview button on same row
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...["Both", "Sound Only", "Vibrate Only"].map((mode) {
                    final isSelected = alarmMode == mode;

                    return GestureDetector(
                      onTap: () => setState(() => alarmMode = mode),
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.blue : Colors.transparent,
                          border: Border.all(
                            color: isSelected ? Colors.blue : Colors.grey,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          mode,
                          style: TextStyle(
                            fontSize: 11,
                            color: isSelected ? Colors.white : Colors.grey,
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }),

                  const SizedBox(width: 8),

                  TextButton.icon(
                    onPressed: () async {
                      if (isPreviewing) {
                        await audioPlayer.stop();
                        Vibration.cancel();
                        setState(() => isPreviewing = false);
                      } else {
                        setState(() => isPreviewing = true);

                        if (alarmMode == "Both" || alarmMode == "Sound Only") {
                          await playAlarmSound();
                        }

                        if (alarmMode == "Both" || alarmMode == "Vibrate Only") {
                          bool? hasVibrator = await Vibration.hasVibrator();
                          if (hasVibrator == true) {
                            Vibration.vibrate(
                              pattern: [0, 500, 200, 500, 200, 800],
                            );
                          }
                        }
                      }
                    },
                    icon: Icon(
                      isPreviewing ? Icons.stop_circle : Icons.play_circle,
                      color: isPreviewing ? Colors.red : Colors.blue,
                      size: 18,
                    ),
                    label: Text(
                      isPreviewing ? "Stop" : "Preview",
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.blue,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: alarmSounds.length,
                itemBuilder: (context, index) {
                  final sound = alarmSounds[index];
                  final isSelected = sound == selectedAlarmSound;
                  return GestureDetector(
                    onTap: () async {
                      setState(() {
                        selectedAlarmSound = sound;
                      });
                      // only play if preview is already active
                      if (isPreviewing) {
                        await playAlarmSound();
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blue : Colors.transparent,
                        border: Border.all(color: isSelected ? Colors.blue : Colors.grey),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        sound,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.grey,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );       // ← closes Scaffold
  }          // ← closes build()
}            // ← closes _HomePageState

class FavoritesPage extends StatefulWidget {
  final List<SavedLocation> savedLocations;
  final Function(SavedLocation) onRemove;
  final Function(SavedLocation) onSetDestination;
  final Function(SavedLocation) onAdd;          // ← new: adds directly to favorites
  final Function(SavedLocation, String) onEdit; 

  const FavoritesPage({
    super.key,
    required this.savedLocations,
    required this.onRemove,
    required this.onSetDestination,
    required this.onAdd,
    required this.onEdit,  
  });

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {

  final TextEditingController searchController = TextEditingController();
  List<SavedLocation> searchResults = [];
  bool isSearching = false;
  Timer? _searchDebounce;

  Future<void> searchLocation(String query) async {
    if (query.isEmpty) return;
    final url = Uri.parse(
  "https://wakemeup-server.onrender.com/search?query=${Uri.encodeComponent(query)}",
);
    try {
      final response = await http.get(url); // no headers needed — server handles auth
      final data = jsonDecode(response.body);
      if (data["items"] != null && (data["items"] as List).isNotEmpty) {
        setState(() {
          searchResults = (data["items"] as List).map<SavedLocation>((item) {
            return SavedLocation(
              name: item["title"].replaceAll(RegExp(r'<[^>]*>'), ''),
              address: item["roadAddress"] ?? item["address"] ?? "",
              latitude: double.parse(item["mapy"]) / 1e7,
              longitude: double.parse(item["mapx"]) / 1e7,
            );
          }).toList();
        });
      } else {
        setState(() => searchResults = []);
      }
    } catch (e) {
      setState(() => searchResults = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Favorites"),
        actions: [
          IconButton(
            icon: Icon(isSearching ? Icons.close : Icons.add),
            onPressed: () {
              setState(() {
                isSearching = !isSearching;
                searchResults = [];
                searchController.clear();
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // search bar shown when + is tapped
          if (isSearching) ...[
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (value) {
                  _searchDebounce?.cancel();
                  if (value.isEmpty) {
                    setState(() => searchResults = []);
                    return;
                  }
                  if (value.length >= 3) {
                    _searchDebounce = Timer(
                      const Duration(milliseconds: 500),
                      () => searchLocation(value),
                    );
                  }
                },
                onSubmitted: (value) => searchLocation(value),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: "Search location to add...",
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () => searchLocation(searchController.text),
                  ),
                ),
              ),
            ),

            // search results
            if (searchResults.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
                  ],
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: searchResults.length,
                  itemBuilder: (context, index) {
                    final result = searchResults[index];
                    final alreadySaved = widget.savedLocations.any(
                      (s) => s.latitude == result.latitude && s.longitude == result.longitude,
                    );
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: false,

                        title: Text(
                          result.name,
                          style: const TextStyle(fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),

                        subtitle: Text(
                          result.address,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),

                        trailing: IconButton(
                          icon: Icon(
                            alreadySaved ? Icons.star : Icons.star_border,
                            color: alreadySaved ? Colors.amber : Colors.grey,
                            size: 28,
                          ),
                          onPressed: () {
                            if (!alreadySaved) {
                              widget.onAdd(result);
                              setState(() {
                                searchResults = [];
                                searchController.clear();
                                isSearching = false;
                              });

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text("${result.name} added to favorites"),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],

          // favorites list
          Expanded(
            child: widget.savedLocations.isEmpty
                ? const Center(
                    child: Text(
                      "No saved locations yet.\nTap + to add one.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: widget.savedLocations.length,
                    itemBuilder: (context, index) {
                      final location = widget.savedLocations[index];
                      return ListTile(
                        title: Text(location.name),
                        subtitle: Text(location.address),
                        onTap: () {
                          widget.onSetDestination(location);
                          Navigator.pop(context);
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.star, color: Colors.amber, size: 28),
                          onPressed: () {
                            widget.onRemove(location);
                            setState(() {});
                          },
                        ),
                        onLongPress: () {
                          showModalBottomSheet(
                            context: context,
                            builder: (_) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.edit),
                                    title: const Text("Edit name"),
                                    onTap: () {
                                      Navigator.pop(context);  // close bottom sheet first
                                      // show a dialog with a text field
                                      final editController = TextEditingController(
                                        text: location.name,   // pre-fill with current name
                                      );
                                      showDialog(
                                        context: context,
                                        builder: (_) => AlertDialog(
                                          title: const Text("Edit name"),
                                          content: TextField(
                                            controller: editController,
                                            autofocus: true,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              hintText: "e.g. Home, School...",
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(context),
                                              child: const Text("Cancel"),
                                            ),
                                            TextButton(
                                              onPressed: () {
                                                if (editController.text.trim().isNotEmpty) {
                                                  widget.onEdit(
                                                    location,
                                                    editController.text.trim(),
                                                  );
                                                  setState(() {});
                                                }
                                                Navigator.pop(context);
                                              },
                                              child: const Text("Save"),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.delete_outline),
                                    title: const Text("Remove from favorites"),
                                    onTap: () {
                                      widget.onRemove(location);
                                      Navigator.pop(context);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}