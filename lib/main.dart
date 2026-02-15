import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://ombpbujzbommuavtoczf.supabase.co',
    anonKey: 'sb_publishable_R0dMbG_1y-7uLkwswndGCw_VK5zTR6X',
  );

  runApp(const DeekApp());
}

class DeekApp extends StatelessWidget {
  const DeekApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

int asInt(dynamic v) => (v as num).toInt();
double asDouble(dynamic v) => (v as num).toDouble();

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final db = Supabase.instance.client;

  final startCtrl = TextEditingController();
  final destCtrl = TextEditingController();
  final mapController = MapController();

  List<Polyline> lines = <Polyline>[];
  List<Marker> markers = <Marker>[];
  int? totalFare;
  bool loading = false;

  double _zoom = 12;

  void snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // =========================
  // 1) GET MAIN LOCATION ID (sub_id=0)
  // =========================
  Future<int?> findMainId(String name) async {
    final res = await db
        .from('location_v')
        .select('id')
        .ilike('name', '%$name%')
        .eq('sub_id', 0)
        .limit(1);

    final list = res as List;
    if (list.isEmpty) return null;
    return asInt(list.first['id']);
  }

  // =========================
  // 2) LOAD ALL ROUTES (id-level graph)
  // =========================
  Future<List<Map<String, dynamic>>> loadRoutes() async {
    final res = await db.from('Route').select('starting_id,destination_id,fare');
    return List<Map<String, dynamic>>.from(res as List);
  }

  // =========================
  // 3) DIJKSTRA (minimum fare)
  //    returns {path: [ids], cost: int}
  // =========================
  Map<String, dynamic>? dijkstra(int start, int target, List<Map<String, dynamic>> routes) {
    final graph = <int, List<Map<String, dynamic>>>{};

    for (final r in routes) {
      final u = asInt(r['starting_id']);
      final v = asInt(r['destination_id']);
      final cost = asInt(r['fare']);

      graph.putIfAbsent(u, () => <Map<String, dynamic>>[]).add({'to': v, 'cost': cost});
      graph.putIfAbsent(v, () => <Map<String, dynamic>>[]).add({'to': u, 'cost': cost});
    }

    if (!graph.containsKey(start) || !graph.containsKey(target)) return null;

    final dist = <int, int>{};
    final prev = <int, int?>{};
    final visited = <int>{};

    for (final node in graph.keys) {
      dist[node] = 1 << 30;
      prev[node] = null;
    }
    dist[start] = 0;

    while (visited.length < graph.length) {
      int? u;
      int best = 1 << 30;

      for (final node in graph.keys) {
        final d = dist[node] ?? (1 << 30);
        if (!visited.contains(node) && d < best) {
          best = d;
          u = node;
        }
      }

      if (u == null) break;
      if (u == target) break;

      visited.add(u);

      for (final edge in graph[u] ?? const <Map<String, dynamic>>[]) {
        final v = edge['to'] as int;
        final cost = (edge['cost'] as num).toInt();
        final newDist = dist[u]! + cost;

        final currentDist = dist[v] ?? (1 << 30);
        if (newDist < currentDist) {
          dist[v] = newDist;
          prev[v] = u;
        }
      }
    }

    if ((dist[target] ?? (1 << 30)) >= (1 << 30)) return null;

    final path = <int>[];
    int? cur = target;
    while (cur != null) {
      path.insert(0, cur);
      cur = prev[cur];
    }

    return {'path': path, 'cost': dist[target]!};
  }

  // =========================
  // 4) MAIN LAT/LNG for node (id, sub_id=0)
  // =========================
  Future<LatLng?> getMainLatLng(int id) async {
    final res = await db
        .from('location_v')
        .select('lat,lng')
        .eq('id', id)
        .eq('sub_id', 0)
        .limit(1);

    final list = res as List;
    if (list.isEmpty) return null;
    final row = list.first;

    if (row['lat'] == null || row['lng'] == null) return null;
    return LatLng(asDouble(row['lat']), asDouble(row['lng']));
  }

  // =========================
  // 5) OSRM road-following segment
  // =========================
  Future<List<LatLng>> fetchOSRM(LatLng a, LatLng b) async {
    final url =
        "https://router.project-osrm.org/route/v1/driving/"
        "${a.longitude},${a.latitude};${b.longitude},${b.latitude}"
        "?overview=full&geometries=geojson";

    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) return <LatLng>[a, b];

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final routes = data['routes'];
    if (routes is! List || routes.isEmpty) return <LatLng>[a, b];

    final geom = routes[0]['geometry'];
    final coords = (geom as Map<String, dynamic>)['coordinates'];
    if (coords is! List) return <LatLng>[a, b];

    return coords
        .map<LatLng>((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
  }

  final List<Color> _transferColors = const [
    Colors.greenAccent,
    Colors.orangeAccent,
    Colors.purpleAccent,
    Colors.cyanAccent,
    Colors.yellowAccent,
  ];

  Marker _buildMarker(LatLng p, Color color, String label) {
    return Marker(
      point: p,
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.location_on, size: 40, color: color),
          Positioned(
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                style: const TextStyle(fontSize: 10, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> findMinimumFareRoute() async {
    final startName = startCtrl.text.trim();
    final destName = destCtrl.text.trim();

    if (startName.isEmpty || destName.isEmpty) {
      snack("Enter start and destination.");
      return;
    }

    setState(() {
      loading = true;
      lines = <Polyline>[];
      markers = <Marker>[];
      totalFare = null;
    });

    try {
      final startId = await findMainId(startName);
      final destId = await findMainId(destName);

      if (startId == null || destId == null) {
        snack("Location not found (check spelling).");
        return;
      }

      final routes = await loadRoutes();
      final result = dijkstra(startId, destId, routes);

      if (result == null) {
        snack("No path found.");
        return;
      }

      final path = List<int>.from(result['path']);
      final cost = result['cost'] as int;

      final fullRoute = <LatLng>[];
      final hopPoints = <LatLng>[];

      for (int i = 0; i < path.length; i++) {
        final p = await getMainLatLng(path[i]);
        if (p != null) hopPoints.add(p);
      }

      for (int i = 0; i < hopPoints.length - 1; i++) {
        final seg = await fetchOSRM(hopPoints[i], hopPoints[i + 1]);
        if (fullRoute.isNotEmpty && seg.isNotEmpty) {
          fullRoute.addAll(seg.skip(1));
        } else {
          fullRoute.addAll(seg);
        }
      }

      final newMarkers = <Marker>[];
      if (hopPoints.isNotEmpty) {
        newMarkers.add(_buildMarker(hopPoints.first, Colors.blueAccent, "START"));
      }

      for (int i = 1; i < hopPoints.length - 1; i++) {
        final c = _transferColors[(i - 1) % _transferColors.length];
        newMarkers.add(_buildMarker(hopPoints[i], c, "T$i"));
      }

      if (hopPoints.length >= 2) {
        newMarkers.add(_buildMarker(hopPoints.last, Colors.redAccent, "END"));
      }

      setState(() {
        totalFare = cost;
        lines = [
          Polyline(
            points: fullRoute.isNotEmpty ? fullRoute : hopPoints,
            strokeWidth: 5,
            color: Colors.greenAccent,
          )
        ];
        markers = newMarkers;
      });

      final boundsPts = (fullRoute.isNotEmpty ? fullRoute : hopPoints);
      if (boundsPts.length >= 2) {
        mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(boundsPts),
            padding: const EdgeInsets.all(90),
          ),
        );
      }

      snack("Path: ${path.join(" → ")} | Fare: $cost");
    } finally {
      setState(() => loading = false);
    }
  }

  void _zoomIn() {
    _zoom = min(_zoom + 1, 19);
    final c = mapController.camera.center;
    mapController.move(c, _zoom);
    setState(() {});
  }

  void _zoomOut() {
    _zoom = max(_zoom - 1, 2);
    final c = mapController.camera.center;
    mapController.move(c, _zoom);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Deek — Minimum Fare")),
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: const LatLng(24.8949, 91.8687),
              initialZoom: _zoom,
              onPositionChanged: (pos, _) {
                if (pos.zoom != null) _zoom = pos.zoom!;
              },
            ),
            children: [
              TileLayer(
                urlTemplate: "https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png",
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: "com.example.deek",
              ),
              PolylineLayer(polylines: lines),
              MarkerLayer(markers: markers),
            ],
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _Box(controller: startCtrl, hint: "Start location"),
                  const SizedBox(height: 10),
                  _Box(controller: destCtrl, hint: "Destination location"),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: loading ? null : findMinimumFareRoute,
                      child: Text(loading ? "Finding..." : "Find minimum fare"),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Zoom buttons (right center)
          Positioned(
            right: 12,
            bottom: totalFare != null ? 100 : 40,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: "zoom_in",
                  mini: true,
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 10),
                FloatingActionButton(
                  heroTag: "zoom_out",
                  mini: true,
                  onPressed: _zoomOut,
                  child: const Icon(Icons.remove),
                ),
              ],
            ),
          ),

          if (totalFare != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: Colors.black.withOpacity(0.85),
                child: Text(
                  "Total Fare: $totalFare",
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  final TextEditingController controller;
  final String hint;

  const _Box({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.35),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hint, border: InputBorder.none),
        ),
      ),
    );
  }
}
