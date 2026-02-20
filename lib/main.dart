// -----------------------------
// Imports
// -----------------------------

import 'dart:convert'; // Used to decode JSON responses from OSRM routing API.
import 'dart:math';   // Used for min/max while zooming in/out.
import 'package:flutter/material.dart'; // Core Flutter UI widgets (Scaffold, TextField, etc.).
import 'package:flutter_map/flutter_map.dart'; // FlutterMap widget for showing OSM tiles + polylines + markers.
import 'package:http/http.dart' as http; // Used to call OSRM routing API over HTTP.
import 'package:latlong2/latlong.dart'; // LatLng type used by flutter_map.
import 'package:supabase_flutter/supabase_flutter.dart'; // Supabase client for querying database.

// -----------------------------
// App Entry Point
// -----------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Ensures Flutter engine is ready before async init.

  // Initialize Supabase so we can query location_v and Route tables.
  await Supabase.initialize(
    url: 'https://ombpbujzbommuavtoczf.supabase.co', // Supabase project URL
    anonKey: 'sb_publishable_R0dMbG_1y-7uLkwswndGCw_VK5zTR6X', // Supabase anonymous key
  );

  runApp(const DeekApp()); // Launch the Flutter app.
}

// -----------------------------
// Top-level widget
// -----------------------------
class DeekApp extends StatelessWidget {
  const DeekApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false, // Removes debug banner.
      home: HomePage(), // Main screen.
    );
  }
}

// -----------------------------
// Helper converters
// -----------------------------
// Supabase returns dynamic JSON values, often as num (int/double). These helpers safely convert.
int asInt(dynamic v) => (v as num).toInt();
double asDouble(dynamic v) => (v as num).toDouble();

// -----------------------------
// Main page (stateful)
// -----------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Supabase client (already initialized in main()).
  final db = Supabase.instance.client;

  // Text inputs for user to type "start location name" and "destination location name".
  final startCtrl = TextEditingController();
  final destCtrl = TextEditingController();

  // Controller to programmatically move/zoom/fit the map.
  final mapController = MapController();

  // List of polylines we draw on the map (transport paths + dotted transfers).
  List<Polyline> polylines = <Polyline>[];

  // List of markers we draw on the map (START / TAKE / LEAVE / END).
  List<Marker> markers = <Marker>[];

  // Total fare for the computed route.
  int? totalFare;

  // UI flag to disable button + show "Finding..." text.
  bool loading = false;

  // Current zoom level (tracked manually to support + / - buttons).
  double _zoom = 12;

  // Colors used to color each transport segment differently.
  // Each hop of the final route gets a different color, cycling through this list.
  final List<Color> _segColors = const [
    Colors.greenAccent,
    Colors.orangeAccent,
    Colors.cyanAccent,
    Colors.purpleAccent,
    Colors.yellowAccent,
    Colors.pinkAccent,
    Colors.lightBlueAccent,
  ];

  // Quick helper for showing snack messages at bottom.
  void snack(String m) {
    if (!mounted) return; // Ensure widget is still alive.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // =========================
  // 1) Find main ID by name (sub_id=0)
  // =========================
  // Purpose:
  // - The user types a location name.
  // - We search "location_v" for the MAIN point only (sub_id=0).
  // - Return the "id" of that location (main id).
  //
  // Example:
  // name="temukhi" -> find row in location_v with sub_id=0 -> return its id (like 4).
  Future<int?> findMainId(String name) async {
    final res = await db
        .from('location_v')
        .select('id')
        .ilike('name', '%$name%') // name ILIKE '%input%'
        .eq('sub_id', 0)          // only main point
        .limit(1);                // just first match

    final list = res as List;
    if (list.isEmpty) return null;
    return asInt(list.first['id']); // return main id
  }

  // =========================
  // 2) Load all routes (for dijkstra)
  // =========================
  // Purpose:
  // - Load edges of the graph for Dijkstra.
  // - But here Dijkstra runs on MAIN ids only, so we only need:
  //   starting_id, destination_id, fare.
  Future<List<Map<String, dynamic>>> loadRoutesMainGraph() async {
    final res = await db.from('Route').select('starting_id,destination_id,fare');
    return List<Map<String, dynamic>>.from(res as List);
  }

  // =========================
  // 3) Dijkstra on MAIN IDs only
  // =========================
  // Purpose:
  // - Compute the minimum total fare path from start main-id to destination main-id.
  // - Graph nodes are MAIN IDs (e.g., 4,3,1,7).
  // - Edges come from Route table (starting_id -> destination_id) with cost=fare.
  //
  // Returns:
  // {
  //   'path': [4, 3, 1, 7],
  //   'cost': 18
  // }
  Map<String, dynamic>? dijkstraMain(int start, int target, List<Map<String, dynamic>> routes) {
    // Build adjacency list: graph[u] = list of {to, cost}
    final graph = <int, List<Map<String, dynamic>>>{};

    for (final r in routes) {
      final u = asInt(r['starting_id']);
      final v = asInt(r['destination_id']);
      final cost = asInt(r['fare']);

      // Add both directions (treat as undirected).
      // If your system is actually one-way, this would be wrong (but that's your current design).
      graph.putIfAbsent(u, () => <Map<String, dynamic>>[]).add({'to': v, 'cost': cost});
      graph.putIfAbsent(v, () => <Map<String, dynamic>>[]).add({'to': u, 'cost': cost});
    }

    // If either node doesn't exist in graph, no path.
    if (!graph.containsKey(start) || !graph.containsKey(target)) return null;

    // dist = best known distance to each node
    final dist = <int, int>{};

    // prev = previous node in shortest path
    final prev = <int, int?>{};

    // visited set to avoid reprocessing nodes
    final visited = <int>{};

    // Initialize all nodes distance to "infinity"
    for (final node in graph.keys) {
      dist[node] = 1 << 30;
      prev[node] = null;
    }
    dist[start] = 0; // start distance = 0

    // Main Dijkstra loop (simple O(V^2) version — good for small graphs)
    while (visited.length < graph.length) {
      int? u;
      int best = 1 << 30;

      // Find the unvisited node with smallest dist
      for (final node in graph.keys) {
        final d = dist[node] ?? (1 << 30);
        if (!visited.contains(node) && d < best) {
          best = d;
          u = node;
        }
      }

      if (u == null) break;       // no reachable nodes left
      if (u == target) break;     // reached destination

      visited.add(u);

      // Relax edges from u
      for (final edge in graph[u] ?? const <Map<String, dynamic>>[]) {
        final v = edge['to'] as int;
        final cost = (edge['cost'] as num).toInt(); // ensure int, avoid num/int error
        final newDist = dist[u]! + cost;

        final currentDist = dist[v] ?? (1 << 30);
        if (newDist < currentDist) {
          dist[v] = newDist;
          prev[v] = u;
        }
      }
    }

    // If target dist is still infinity => no path
    if ((dist[target] ?? (1 << 30)) >= (1 << 30)) return null;

    // Rebuild path by following prev pointers backward
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
  // =========================
  // Purpose:
  // - After Dijkstra gives main path like 4->3->1->7,
  //   we need to draw each hop using the EXACT stop points (sub points).
  // - Route row contains:
  //   starting_id, starting_sub, destination_id, destination_sub, fare
  // - If forward (A->B) not found, we try reverse (B->A).
  //
  // Returns map like:
  // {
  //   starting_id: 4,
  //   starting_sub: 1,
  //   destination_id: 3,
  //   destination_sub: 0,
  //   fare: 10
  // }
  Future<Map<String, dynamic>?> findRouteRowEitherWay(int aId, int bId) async {
    // Try A -> B
    final forward = await db
        .from('Route')
        .select('starting_id,starting_sub,destination_id,destination_sub,fare')
        .eq('starting_id', aId)
        .eq('destination_id', bId)
        .limit(1);

    final fList = forward as List;
    if (fList.isNotEmpty) return Map<String, dynamic>.from(fList.first as Map);

    // Try B -> A
    final reverse = await db
        .from('Route')
        .select('starting_id,starting_sub,destination_id,destination_sub,fare')
        .eq('starting_id', bId)
        .eq('destination_id', aId)
        .limit(1);

    final rList = reverse as List;
    if (rList.isNotEmpty) return Map<String, dynamic>.from(rList.first as Map);

    return null; // no route row found either direction
  }

  // =========================
  // 5) Get exact point (id, sub_id) from location_v
  // =========================
  // Purpose:
  // - Route row gives you which sub stop to use at that terminal/location.
  // - This fetches the lat/lng for that exact (id, sub_id).
  //
  // Example: getPoint(4,1) -> returns LatLng of location id=4 sub_id=1
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
  // Purpose:
  // - Instead of drawing a straight line, ask OSRM for the road-following route.
  // - OSRM expects coordinates in (lon,lat) order.
  //
  // Returns list of LatLng points that follow roads.
  Future<List<LatLng>> fetchOSRM(LatLng a, LatLng b) async {
    final url =
        "https://router.project-osrm.org/route/v1/driving/"
        "${a.longitude},${a.latitude};${b.longitude},${b.latitude}"
        "?overview=full&geometries=geojson";

    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) return <LatLng>[a, b]; // fallback to straight

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final routes = data['routes'];
    if (routes is! List || routes.isEmpty) return <LatLng>[a, b];

    final geom = routes[0]['geometry'] as Map<String, dynamic>;
    final coords = geom['coordinates'];
    if (coords is! List) return <LatLng>[a, b];

    // coords are [[lon,lat], [lon,lat], ...]
    return coords
        .map<LatLng>((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
  }

  // =========================
  // 7) Dotted line for terminal transfer
  // =========================
  // Purpose:
  // - Sometimes you arrive at a terminal at one sub stop,
  //   but the next transport leaves from another sub stop in the same terminal.
  // - That "walk inside terminal" is drawn as dotted polyline.
  //
  // How it works:
  // - Splits straight line into many small segments
  // - Draws only even segments -> creates dashed/dotted look
  List<Polyline> dashedLine(LatLng a, LatLng b,
      {required Color color, double strokeWidth = 3, int pieces = 28}) {
    final segs = <Polyline>[];
    for (int i = 0; i < pieces; i++) {
      if (i.isOdd) continue; // skip every other segment -> dashed effect
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

  // Marker builder: creates a marker icon and label box.
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
  // This is the heart of the app:
  // 1) Read user inputs
  // 2) Find main ids (sub_id=0) for start and destination
  // 3) Run Dijkstra on main ids using fare as cost
  // 4) For each hop in the main path:
  //    - find route row to get sub stops
  //    - fetch exact start/dest coordinates from location_v
  //    - if needed, add dotted line to next start stop
  //    - fetch OSRM route for road-following polyline
  //    - add markers
  // 5) Fit map camera and show total fare
  Future<void> findMinimumFareRoute() async {
    final startName = startCtrl.text.trim();
    final destName = destCtrl.text.trim();

    if (startName.isEmpty || destName.isEmpty) {
      snack("Enter start and destination.");
      return;
    }

    // Reset UI and show loading
    setState(() {
      loading = true;
      polylines = <Polyline>[];
      markers = <Marker>[];
      totalFare = null;
    });

    try {
      // Convert names to main ids
      final startId = await findMainId(startName);
      final destId = await findMainId(destName);

      if (startId == null || destId == null) {
        snack("Location not found (check spelling).");
        return;
      }

      // Load edges and run Dijkstra to get main path
      final routes = await loadRoutesMainGraph();
      final dj = dijkstraMain(startId, destId, routes);

      if (dj == null) {
        snack("No path found.");
        return;
      }

      final path = List<int>.from(dj['path']); // main ids only, e.g. [4,3,1,7]
      final cost = dj['cost'] as int;

      // Prepare new drawings
      final newPolys = <Polyline>[];
      final newMarkers = <Marker>[];
      final boundsPts = <LatLng>[];

      LatLng? lastArrivalPoint; // where we arrived after last hop (exact sub point)
      int segIndex = 0;          // used to pick segment colors

      // For each hop in the main path
      for (int i = 0; i < path.length - 1; i++) {
        final aId = path[i];
        final bId = path[i + 1];

        // Retrieve the exact Route row so we know which sub stops to use
        final row = await findRouteRowEitherWay(aId, bId);
        if (row == null) {
          snack("Missing Route row for hop $aId → $bId");
          return;
        }

        // Sub stop info
        final sId = asInt(row['starting_id']);
        final sSub = asInt(row['starting_sub']);
        final dId = asInt(row['destination_id']);
        final dSub = asInt(row['destination_sub']);

        // Convert sub stops to coordinates
        final startExact = await getPoint(sId, sSub);
        final destExact = await getPoint(dId, dSub);

        if (startExact == null || destExact == null) {
          snack("Missing location_v point for ($sId,$sSub) or ($dId,$dSub)");
          return;
        }

        // If we already arrived from previous hop, and the new hop starts at a different sub stop,
        // draw dotted transfer between "where we arrived" and "where next transport starts".
        if (lastArrivalPoint != null) {
          if (lastArrivalPoint != startExact) {
            newPolys.addAll(dashedLine(
              lastArrivalPoint!,
              startExact,
              color: Colors.white70,
              strokeWidth: 3,
              pieces: 30,
            ));
            boundsPts.add(lastArrivalPoint!);
            boundsPts.add(startExact);
          }
        } else {
          // First hop: mark START at the first exact start stop
          newMarkers.add(_marker(startExact, Colors.blueAccent, "START"));
        }

        // Pick a unique color for this transport segment
        final segColor = _segColors[segIndex % _segColors.length];
        segIndex++;

        // Fetch road route via OSRM and draw it
        final roadPts = await fetchOSRM(startExact, destExact);
        newPolys.add(Polyline(points: roadPts, strokeWidth: 5, color: segColor));
        boundsPts.addAll(roadPts);

        // Mark "TAKE" and "LEAVE" points for user guidance
        // - TAKE is the stop where user boards this transport
        // - LEAVE is where user gets off for this segment
        if (i > 0) {
          newMarkers.add(_marker(startExact, segColor, "TAKE ${i + 1}"));
        }
        newMarkers.add(_marker(destExact, segColor, "LEAVE ${i + 1}"));

        // Update lastArrivalPoint = where we ended this hop
        lastArrivalPoint = destExact;
      }

      // Mark END at final arrival point
      if (lastArrivalPoint != null) {
        newMarkers.add(_marker(lastArrivalPoint!, Colors.redAccent, "END"));
      }

      // Push all new drawings to UI
      setState(() {
        totalFare = cost;
        polylines = newPolys;
        markers = newMarkers;
      });

      // Fit camera to all drawn points
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
      // Always stop loading state even if errors happen
      setState(() => loading = false);
    }
  }

  // Zoom in button handler
  void _zoomIn() {
    _zoom = min(_zoom + 1, 19);
    final c = mapController.camera.center;
    mapController.move(c, _zoom);
    setState(() {});
  }

  // Zoom out button handler
  void _zoomOut() {
    _zoom = max(_zoom - 1, 2);
    final c = mapController.camera.center;
    mapController.move(c, _zoom);
    setState(() {});
  }

  // =========================
  // UI Layout
  // =========================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Deek — Minimum Fare (Sub points)")),
      body: Stack(
        children: [
          // Map background
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
              // OSM tile provider (HOT tiles)
              TileLayer(
                urlTemplate: "https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png",
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: "com.example.deek",
              ),
              // Draw polylines (transport + dotted transfers)
              PolylineLayer(polylines: polylines),
              // Draw markers (start/take/leave/end)
              MarkerLayer(markers: markers),
            ],
          ),

          // Inputs and button at top
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

          // Zoom buttons on the right side
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

          // Bottom bar to show total fare
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

// -----------------------------
// Reusable text input box widget
// -----------------------------
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
          decoration: InputDecoration(
            hintText: hint,
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }
}
