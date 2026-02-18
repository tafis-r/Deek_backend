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

  List<Polyline> polylines = <Polyline>[];
  List<Marker> markers = <Marker>[];
  int? totalFare;
  bool loading = false;

  double _zoom = 12;

  final List<Color> _segColors = const [
    Colors.greenAccent,
    Colors.orangeAccent,
    Colors.cyanAccent,
    Colors.purpleAccent,
    Colors.yellowAccent,
    Colors.pinkAccent,
    Colors.lightBlueAccent,
  ];

  void snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // =========================
  // 1) Find main ID by name (sub_id=0)
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
  // 2) Load all routes (for dijkstra)
  // =========================
  Future<List<Map<String, dynamic>>> loadRoutesMainGraph() async {
    final res = await db.from('Route').select('starting_id,destination_id,fare');
    return List<Map<String, dynamic>>.from(res as List);
  }

  // =========================
  // 3) Dijkstra on MAIN IDs only
  // =========================
  Map<String, dynamic>? dijkstraMain(int start, int target, List<Map<String, dynamic>> routes) {
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
  // 4) Find the exact Route row for a hop (A->B) (or reverse)
  //     Returns: {starting_id, starting_sub, destination_id, destination_sub, fare}
  // =========================
  Future<Map<String, dynamic>?> findRouteRowEitherWay(int aId, int bId) async {
    final forward = await db
        .from('Route')
        .select('starting_id,starting_sub,destination_id,destination_sub,fare')
        .eq('starting_id', aId)
        .eq('destination_id', bId)
        .limit(1);

    final fList = forward as List;
    if (fList.isNotEmpty) return Map<String, dynamic>.from(fList.first as Map);

    final reverse = await db
        .from('Route')
        .select('starting_id,starting_sub,destination_id,destination_sub,fare')
        .eq('starting_id', bId)
        .eq('destination_id', aId)
        .limit(1);

    final rList = reverse as List;
    if (rList.isNotEmpty) return Map<String, dynamic>.from(rList.first as Map);

    return null;
  }

  // =========================
  // 5) Get exact point (id, sub_id) from location_v
  // =========================
  Future<LatLng?> getPoint(int id, int sub) async {
    final res = await db
        .from('location_v')
        .select('lat,lng')
        .eq('id', id)
        .eq('sub_id', sub)
        .limit(1);

    final list = res as List;
    if (list.isEmpty) return null;

    final row = list.first;
    if (row['lat'] == null || row['lng'] == null) return null;

    return LatLng(asDouble(row['lat']), asDouble(row['lng']));
  }

  // =========================
  // 6) OSRM road route between 2 points
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

    final geom = routes[0]['geometry'] as Map<String, dynamic>;
    final coords = geom['coordinates'];
    if (coords is! List) return <LatLng>[a, b];

    return coords
        .map<LatLng>((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
  }

  // =========================
  // 7) Dotted line for terminal transfer
  // =========================
  List<Polyline> dashedLine(LatLng a, LatLng b,
      {required Color color, double strokeWidth = 3, int pieces = 28}) {
    final segs = <Polyline>[];
    for (int i = 0; i < pieces; i++) {
      if (i.isOdd) continue;
      final t1 = i / pieces;
      final t2 = (i + 1) / pieces;

      final p1 = LatLng(
        a.latitude + (b.latitude - a.latitude) * t1,
        a.longitude + (b.longitude - a.longitude) * t1,
      );
      final p2 = LatLng(
        a.latitude + (b.latitude - a.latitude) * t2,
        a.longitude + (b.longitude - a.longitude) * t2,
      );

      segs.add(Polyline(points: [p1, p2], strokeWidth: strokeWidth, color: color));
    }
    return segs;
  }

  Marker _marker(LatLng p, Color color, String label) {
    return Marker(
      point: p,
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.location_on, size: 44, color: color),
          Positioned(
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(label, style: const TextStyle(fontSize: 10)),
            ),
          ),
        ],
      ),
    );
  }

  // =========================
  // MAIN: Dijkstra on IDs, then exact sub points per hop, plus dotted transfers
  // =========================
  Future<void> findMinimumFareRoute() async {
    final startName = startCtrl.text.trim();
    final destName = destCtrl.text.trim();

    if (startName.isEmpty || destName.isEmpty) {
      snack("Enter start and destination.");
      return;
    }

    setState(() {
      loading = true;
      polylines = <Polyline>[];
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

      final routes = await loadRoutesMainGraph();
      final dj = dijkstraMain(startId, destId, routes);
      if (dj == null) {
        snack("No path found.");
        return;
      }

      final path = List<int>.from(dj['path']); // main ids only
      final cost = dj['cost'] as int;

      final newPolys = <Polyline>[];
      final newMarkers = <Marker>[];
      final boundsPts = <LatLng>[];

      LatLng? lastArrivalPoint; // the exact point we arrived at (for dotted transfer)
      int segIndex = 0;

      for (int i = 0; i < path.length - 1; i++) {
        final aId = path[i];
        final bId = path[i + 1];

        // Find the route row for this hop (aId -> bId) and read sub ids
        final row = await findRouteRowEitherWay(aId, bId);
        if (row == null) {
          snack("Missing Route row for hop $aId → $bId");
          return;
        }

        final sId = asInt(row['starting_id']);
        final sSub = asInt(row['starting_sub']);
        final dId = asInt(row['destination_id']);
        final dSub = asInt(row['destination_sub']);

        final startExact = await getPoint(sId, sSub);
        final destExact = await getPoint(dId, dSub);

        if (startExact == null || destExact == null) {
          snack("Missing location_v point for ($sId,$sSub) or ($dId,$dSub)");
          return;
        }

        // If we arrived at the same terminal (same id) but at different sub,
        // draw dotted transfer from previous arrival point to this segment's start point.
        if (lastArrivalPoint != null) {
          if (lastArrivalPoint != startExact) {
            newPolys.addAll(dashedLine(lastArrivalPoint!, startExact,
                color: Colors.white70, strokeWidth: 3, pieces: 30));
            boundsPts.add(lastArrivalPoint!);
            boundsPts.add(startExact);
          }
        } else {
          // First segment: mark START at the startExact
          newMarkers.add(_marker(startExact, Colors.blueAccent, "START"));
        }

        // Draw transport segment (OSRM) with unique color
        final segColor = _segColors[segIndex % _segColors.length];
        segIndex++;

        final roadPts = await fetchOSRM(startExact, destExact);
        newPolys.add(Polyline(points: roadPts, strokeWidth: 5, color: segColor));
        boundsPts.addAll(roadPts);

        // Mark "leave/take" points:
        // - segment start point (where you take this transport)
        // - segment destination point (where you leave this transport)
        // To avoid duplicate markers, mark middle points only.
        if (i > 0) {
          newMarkers.add(_marker(startExact, segColor, "TAKE ${i + 1}"));
        }
        newMarkers.add(_marker(destExact, segColor, "LEAVE ${i + 1}"));

        // update arrival point for next transfer check
        lastArrivalPoint = destExact;
      }

      // Mark END at last arrival point (destination exact)
      if (lastArrivalPoint != null) {
        newMarkers.add(_marker(lastArrivalPoint!, Colors.redAccent, "END"));
      }

      setState(() {
        totalFare = cost;
        polylines = newPolys;
        markers = newMarkers;
      });

      if (boundsPts.isNotEmpty) {
        mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(boundsPts),
            padding: const EdgeInsets.all(90),
          ),
        );
      }

      snack("Main path: ${path.join(" → ")} | Fare: $cost");
    } finally {
      setState(() => loading = false);
    }
  }

  // Zoom controls
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
      appBar: AppBar(title: const Text("Deek — Minimum Fare (Sub points)")),
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
              PolylineLayer(polylines: polylines),
              MarkerLayer(markers: markers),
            ],
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _Box(controller: startCtrl, hint: "Start location (name)"),
                  const SizedBox(height: 10),
                  _Box(controller: destCtrl, hint: "Destination location (name)"),
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
//text
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
