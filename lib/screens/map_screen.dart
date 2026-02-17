import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const WalkApp());
}

// ===============================
// MAIN APP
// ===============================
class WalkApp extends StatelessWidget {
  const WalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Walk Tracker',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MapScreen(),
    );
  }
}

// ===============================
// WALK MODEL
// ===============================
class WalkSession {
  final double distance;
  final double calories;
  final int seconds;
  final List<LatLng> path;

  WalkSession({
    required this.distance,
    required this.calories,
    required this.seconds,
    required this.path,
  });

  Map<String, dynamic> toJson() => {
    'distance': distance,
    'calories': calories,
    'seconds': seconds,
    'path': path
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
  };

  factory WalkSession.fromJson(Map<String, dynamic> json) {
    return WalkSession(
      distance: json['distance'],
      calories: json['calories'],
      seconds: json['seconds'],
      path: (json['path'] as List)
          .map((p) => LatLng(p['lat'], p['lng']))
          .toList(),
    );
  }
}

// ===============================
// MAP SCREEN
// ===============================
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _map = MapController();

  LatLng? _current;

  bool _walking = false;

  StreamSubscription<Position>? _stream;

  double _distance = 0;
  double _calories = 0;

  LatLng? _last;

  List<LatLng> _path = [];

  int _seconds = 0;

  Timer? _timer;

  double _weight = 70;

  List<WalkSession> _history = [];

  @override
  void initState() {
    super.initState();

    _loadWeight();
    _loadHistory();
    _initGPS();
  }

  // ===============================
  // LOAD USER SETTINGS
  // ===============================
  Future<void> _loadWeight() async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _weight = prefs.getDouble('weight') ?? 70;
    });
  }

  Future<void> _saveWeight(double w) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setDouble('weight', w);
  }

  // ===============================
  // LOAD HISTORY
  // ===============================
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();

    final data = prefs.getString('history');

    if (data == null) return;

    final list = jsonDecode(data) as List;

    setState(() {
      _history = list.map((e) => WalkSession.fromJson(e)).toList();
    });
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();

    final data =
    jsonEncode(_history.map((e) => e.toJson()).toList());

    await prefs.setString('history', data);
  }

  // ===============================
  // GPS
  // ===============================
  Future<void> _initGPS() async {
    var perm = await Geolocator.checkPermission();

    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    final pos = await Geolocator.getCurrentPosition();

    final lat = LatLng(pos.latitude, pos.longitude);

    setState(() {
      _current = lat;
    });

    _map.move(lat, 16);
  }

  // ===============================
  // WALK CONTROL
  // ===============================
  void _start() {
    if (_walking) return;

    _distance = 0;
    _calories = 0;
    _seconds = 0;

    _path.clear();
    _last = null;

    _timer = Timer.periodic(
      const Duration(seconds: 1),
          (_) => setState(() => _seconds++),
    );

    _stream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
      ),
    ).listen(_onLocation);

    setState(() => _walking = true);
  }

  void _stop() async {
    _stream?.cancel();
    _timer?.cancel();

    _walking = false;

    if (_distance > 10) {
      _history.add(
        WalkSession(
          distance: _distance,
          calories: _calories,
          seconds: _seconds,
          path: List.from(_path),
        ),
      );

      await _saveHistory();
    }

    setState(() {});
  }

  void _onLocation(Position p) {
    final pos = LatLng(p.latitude, p.longitude);

    if (_last != null) {
      final d = Geolocator.distanceBetween(
        _last!.latitude,
        _last!.longitude,
        pos.latitude,
        pos.longitude,
      );

      _distance += d;
      _updateCalories();
    }

    _last = pos;

    _path.add(pos);

    setState(() {
      _current = pos;
    });

    _map.move(pos, _map.camera.zoom);
  }

  // ===============================
  // CALORIES
  // ===============================
  void _updateCalories() {
    final km = _distance / 1000;

    _calories = km * _weight * 0.9;
  }

  // ===============================
  // EXPORT GPX
  // ===============================
  Future<void> _exportGPX() async {
    if (_path.isEmpty) return;

    final dir = await getApplicationDocumentsDirectory();

    final file =
    File('${dir.path}/walk_${DateTime.now().millisecondsSinceEpoch}.gpx');

    final buffer = StringBuffer();

    buffer.writeln('<?xml version="1.0"?>');
    buffer.writeln('<gpx version="1.1">');
    buffer.writeln('<trk><trkseg>');

    for (var p in _path) {
      buffer.writeln(
          '<trkpt lat="${p.latitude}" lon="${p.longitude}"></trkpt>');
    }

    buffer.writeln('</trkseg></trk></gpx>');

    await file.writeAsString(buffer.toString());

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Exported: ${file.path}')),
    );
  }

  // ===============================
  // UI
  // ===============================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walk Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _editWeight,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: _showHistory,
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: _exportGPX,
          ),
        ],
      ),

      body: Stack(
        children: [
          // MAP
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _current ?? const LatLng(0, 0),
              initialZoom: 16,
            ),
            children: [
              TileLayer(
                urlTemplate:
                'https://a.tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.walk',
              ),

              // PATH
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _path,
                    strokeWidth: 4,
                    color: Colors.blue,
                  ),
                ],
              ),

              // MARKER
              if (_current != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _current!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.red,
                        size: 32,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // INFO
          _infoPanel(),

          // CONTROLS
          _buttons(),
        ],
      ),
    );
  }

  Widget _infoPanel() {
    return Positioned(
      top: 10,
      left: 10,
      right: 10,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Distance: ${(_distance / 1000).toStringAsFixed(2)} km'),
              Text('Calories: ${_calories.toStringAsFixed(1)} kcal'),
              Text('Time: ${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}'),
              Text(
                  'Speed: ${_seconds > 0 ? ((_distance / 1000) / (_seconds / 3600)).toStringAsFixed(2) : '0'} km/h'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buttons() {
    return Positioned(
      bottom: 20,
      left: 20,
      right: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ElevatedButton(
            onPressed: _walking ? null : _start,
            child: const Text('Start'),
          ),
          ElevatedButton(
            onPressed: _walking ? _stop : null,
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }

  // ===============================
  // SETTINGS
  // ===============================
  void _editWeight() {
    final ctrl =
    TextEditingController(text: _weight.toString());

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Your Weight (kg)'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final w = double.tryParse(ctrl.text);

              if (w != null && w > 20 && w < 300) {
                _weight = w;
                _saveWeight(w);
              }

              Navigator.pop(context);

              setState(() {});
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showHistory() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Walk History'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            itemCount: _history.length,
            itemBuilder: (_, i) {
              final w = _history[i];

              return ListTile(
                title: Text(
                    '${(w.distance / 1000).toStringAsFixed(2)} km'),
                subtitle: Text(
                    '${w.calories.toStringAsFixed(1)} kcal · ${w.seconds ~/ 60} min'),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stream?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}