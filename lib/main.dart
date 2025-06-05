import 'dart:async'; // Provides Future, Stream, and Timer for scheduling periodic tasks
import 'dart:convert'; // Provides JSON encoding/decoding utilities
import 'dart:math'; // Provides mathematical functions and Random class

import 'package:flutter/material.dart'; // Main Flutter material design library
import 'package:http/http.dart' as http; // HTTP client for sending/receiving requests
import 'package:fl_chart/fl_chart.dart'; // Charting library for Flutter (LineChart, FlSpot, etc.)
import 'package:intl/intl.dart'; // Internationalization package for date/time formatting
import 'package:flutter/foundation.dart'; // Provides kIsWeb constant to detect web platform
import 'log_page.dart'; // Local file containing LogPage widget (for uplink log view)
import 'package:flutter/services.dart'; // Enables access to rootBundle for asset loading
import 'package:csv/csv.dart'; // CSV parsing library

// ═══════════════════════════════════════════════════════════
//                TTN CONFIG & SERVICE
// ═══════════════════════════════════════════════════════════

// Base URL for The Things Network (Australia server)
const String kTtnUrl        = 'https://au1.cloud.thethings.network';
// TTN Application ID configured in TTN console
const String kApplicationId = 'smartvineyardiot';
// TTN API Key for server-side access (must remain confidential)
const String kTtnApiKey     = 'NNSXS.SARCZ2SHMFDVPOQV2OLPXRM2S6FOYSAX4U222WI.AJB4CYML26DM3IFTM5GRRWOOQOW5TCOKDPOSJIXQHZ5O46MTHVMA';

class TtnService {
  // Base endpoint for device-related TTN API calls
  static const _baseUrl =
      '$kTtnUrl/api/v3/as/applications/$kApplicationId/devices';

  /// Fetches the single most recent uplink for the specified device.
  /// Parses the comma-separated payload into a map of sensor values.
  Future<Map<String, String>> latestUplink(String deviceId) async {
    // Construct URI with query parameters: limit=1, order by newest first
    final uri = Uri.parse('$_baseUrl/$deviceId/packages/storage/uplink_message')
        .replace(queryParameters: {
      'limit': '1',
      'order': '-received_at',    // Request newest messages first
    });

    // Send HTTP GET with authorization header
    final res = await http.get(uri, headers: {
      'Authorization': 'Bearer $kTtnApiKey',
      'Accept':        'text/event-stream', // Expect event-stream format
    });

    // Return empty map if the request fails
    if (res.statusCode != 200) {
      debugPrint('❌ TTN fetch failed ${res.statusCode}: ${res.body}');
      return {};
    }

    // Filter lines to keep only valid JSON blobs (lines starting and ending with braces)
    final jsonLines = res.body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('{') && l.endsWith('}'))
        .toList();
    if (jsonLines.isEmpty) return {};

    // Decode the most recent JSON event
    final envelope = jsonDecode(jsonLines.last) as Map<String, dynamic>?;
    final uplink = (envelope?['result'] as Map<String, dynamic>?)?['uplink_message'] as Map<String, dynamic>?;
    // Extract the payload string (e.g., "AT:2130,AH:4380,...") and trim whitespace or control chars
    final raw = ((uplink?['decoded_payload'] as Map<String, dynamic>?)?['message'] as String?)
        ?.trim()
        .replaceAll(RegExp(r'^[\u0000\^"]+|[\u0000\^"]+$'), '') ?? '';

    // Split the payload by commas and then by colon to build a key:value map
    final parsed = <String, String>{};
    for (final part in raw.split(',')) {
      final idx = part.indexOf(':');
      if (idx > 0) {
        parsed[part.substring(0, idx)] = part.substring(idx + 1);
      }
    }

    debugPrint('🔍 latestUplink parsed map = $parsed');
    return parsed;
  }

  /// Fetches up to [limit] uplink messages for the specified device.
  /// Returns a list of maps, each containing parsed sensor values.
  Future<List<Map<String, String>>> fetchHistory(
      String deviceId, {
        int limit = 96, // Default to 96 samples (~3 hours at 2-minute intervals)
      }) async {
    // Construct URI with query parameters: specified limit, order by newest first
    final uri = Uri.parse('$_baseUrl/$deviceId/packages/storage/uplink_message')
        .replace(queryParameters: {
      'limit': '$limit',
      'order': '-received_at',    // Request newest messages first
    });

    // Send HTTP GET with authorization header
    final res = await http.get(uri, headers: {
      'Authorization': 'Bearer $kTtnApiKey',
      'Accept':        'text/event-stream',
    });

    // Return empty list if the request fails
    if (res.statusCode != 200) {
      debugPrint('❌ TTN history fetch failed '
          '${res.statusCode}: ${res.body}');
      return [];
    }

    // Filter lines to keep only valid JSON blobs
    final jsonLines = res.body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('{') && l.endsWith('}'))
        .toList();

    final out = <Map<String, String>>[];
    for (final line in jsonLines) {
      // Decode each JSON event
      final envelope = jsonDecode(line) as Map<String, dynamic>?;
      final uplink = (envelope?['result'] as Map<String, dynamic>?)?['uplink_message'] as Map<String, dynamic>?;
      // Extract and clean the payload string
      final raw = ((uplink?['decoded_payload'] as Map<String, dynamic>?)?['message'] as String?)
          ?.trim()
          .replaceAll(RegExp(r'^[\u0000\^"]+|[\u0000\^"]+$'), '') ?? '';
      // Parse key:value pairs into a map
      final parsed = <String, String>{};
      for (final part in raw.split(',')) {
        final idx = part.indexOf(':');
        if (idx > 0) {
          parsed[part.substring(0, idx)] = part.substring(idx + 1);
        }
      }
      out.add(parsed);
    }
    return out;
  }
}

// ═══════════════════════════════════════════════════════════
//                     DATA MODELS
// ═══════════════════════════════════════════════════════════

/// Represents a data point for charting or history,
/// containing timestamp and four sensor values.
class GraphData {
  final DateTime timestamp;
  final double temperature;
  final double humidity;
  final double leafWetness;
  final double leafTemp;

  GraphData(
      this.timestamp,
      this.temperature,
      this.humidity,
      this.leafWetness,
      this.leafTemp,
      );
}

/// Generates mock data for a given duration key.
/// Useful for initial chart prototyping before real data is available.
List<GraphData> getMockData(String duration) {
  final rnd = Random();
  // Map duration strings to number of days
  final days = {
    '1_week':   7,
    '1_month': 30,
    '6_months':180,
    '1_year':  365,
  }[duration]!;
  final now = DateTime.now();

  // Generate random values for each day in the specified span
  return List.generate(days, (i) {
    final dt = now.subtract(Duration(days: days - 1 - i));
    final air   = 15 + rnd.nextDouble() * 10;       // Random air temperature between 15 and 25 °C
    final hum   = 50 + rnd.nextDouble() * 10;       // Random humidity between 50 and 60 %
    final lTemp = air + (rnd.nextDouble() * 2 - 1); // Leaf temperature within ±1°C of air
    final lWet  = 30 + rnd.nextDouble() * 20;       // Random leaf wetness between 30 and 50 %
    return GraphData(dt, air, hum, lTemp, lWet);
  });
}

// ────────────────────────────────────────────────────────────
//  WeatherNode model
// ────────────────────────────────────────────────────────────

/// Represents a sensor node with various readings and metadata.
class WeatherNode {
  final int    id;         // Unique identifier for the node
  final String name;       // Human-readable name (e.g., “Node 1”)
  final String location;   // Location description (e.g., “Field A”)

  // Mutable fields to hold latest sensor values as strings
  String temperature, humidity;
  String leafTemp,    leafWetness;
  String status, lastUpdated;

  WeatherNode({
    required this.id,
    required this.name,
    required this.location,
    this.temperature = '--',
    this.humidity    = '--',
    this.leafTemp    = '--',
    this.leafWetness = '--',
    this.status      = 'Active',
    this.lastUpdated = '-',
  });
}

/// Represents a notification with a title and message.
class NotificationData {
  final String title;
  final String message;
  NotificationData(this.title, this.message);
}

// ────────────────────────────────────────────────────────────
//  MOCK / HELPER FUNCTIONS
// ────────────────────────────────────────────────────────────

/// Helper to display in-app alert dialogs for notifications.
/// Uses a global navigator key to show dialogs from anywhere.
class NotificationHelper {
  static final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  /// Displays a dialog with the given title and message.
  static void send({required String title, required String message}) {
    showDialog(
      context: navKey.currentContext!,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(navKey.currentContext!),
            child: const Text('OK'),
          )
        ],
      ),
    );
  }
}

/// Holds title, value, and icon for displaying a sensor metric in a grid.
class SensorInfo {
  final String title;
  final String value;
  final IconData icon;
  SensorInfo(this.title, this.value, this.icon);
}

// ═══════════════════════════════════════════════════════════
//                           MAIN APP
// ═══════════════════════════════════════════════════════════

void main() => runApp(const FrostApp());

class FrostApp extends StatelessWidget {
  const FrostApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Define four weather nodes with default “Active” status
    final nodes = <int, WeatherNode>{
      1: WeatherNode(id: 1, name: 'Node 1', location: 'Field A'),
      2: WeatherNode(id: 2, name: 'Node 2', location: 'Field B', status: 'Inactive'),
      3: WeatherNode(id: 3, name: 'Node 3', location: 'Field C'),
      4: WeatherNode(id: 4, name: 'Node 4', location: 'Field D'),
    };

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Frost Detection',
      navigatorKey: NotificationHelper.navKey, // Enables NotificationHelper to show dialogs
      initialRoute: '/login',
      // onGenerateRoute handles routes that require arguments
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/historical':
            return MaterialPageRoute(builder: (_) => const HistoricalDataPage());

          case '/all_notifications':
            return MaterialPageRoute(
              builder: (ctx) => AllNotificationsPage(
                nodes: nodes.values.toList(),
                onBack: () => Navigator.pop(ctx),
              ),
            );

          case '/node_notification':
            final id = settings.arguments as int;
            return MaterialPageRoute(
              builder: (ctx) => NodeNotificationPage(
                node: nodes[id]!,
                onBack: () => Navigator.pop(ctx),
              ),
            );

          case '/node_location':
            final id = settings.arguments as int;
            return MaterialPageRoute(
              builder: (ctx) => NodeLocationPage(node: nodes[id]!),
            );

          default:
            return null;
        }
      },
      // Static routes that require no arguments
      routes: {
        '/login':             (_) => const LoginPage(),
        '/main':              (_) => WeatherPage(nodes: nodes),
        '/frost_prediction':  (_) => const FrostPredictionPage(),
        '/logs':              (_) => const LogPage(),
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
//                        LOGIN PAGE
// ═══════════════════════════════════════════════════════════

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool showPwd = false; // Toggles password visibility

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff87CEEB), // Sky-blue background color
      body: SafeArea(
        child: Column(
          children: [
            // Top 40%: Display app logo
            Flexible(
              flex: 10,
              child: Center(
                child: Image.asset(
                  'assets/logo.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),

            // Bottom 60%: Email/Password form and login button
            Flexible(
              flex: 6,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Email input field
                    TextField(
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        labelText: 'Email',
                        prefixIcon: const Icon(Icons.email),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Password input field with visibility toggle
                    TextField(
                      obscureText: !showPwd,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => showPwd = !showPwd),
                          icon: Icon(
                            showPwd ? Icons.visibility : Icons.visibility_off,
                          ),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Log In button navigates to /main route
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                      ),
                      onPressed: () =>
                          Navigator.pushReplacementNamed(context, '/main'),
                      child: const Text(
                        'LOG IN',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//                    WEATHER (Home) PAGE
// ═══════════════════════════════════════════════════════════

class WeatherPage extends StatefulWidget {
  final Map<int, WeatherNode> nodes; // Map of node ID to WeatherNode
  const WeatherPage({Key? key, required this.nodes}) : super(key: key);

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  final _ttn = TtnService(); // Instance of TTN service for data fetching
  final List<Map<String, dynamic>> _uplinkHistory = []; // Stores recent uplinks
  List<FlSpot> _deviceSpots = []; // Holds 24 hourly average temperature points
  double _minY = 0, _maxY = 0; // Y-axis range for the chart
  late Timer _timer; // Timer to schedule periodic refresh

  @override
  void initState() {
    super.initState();
    _refreshAll(); // Initial fetch of summary and history
    // Schedule refresh every 2 minutes
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _refreshAll());
  }

  @override
  void dispose() {
    _timer.cancel(); // Cancel the timer when the widget is disposed
    super.dispose();
  }

  /// Fetches both summary (latest uplink) and device history (last 24h)
  Future<void> _refreshAll() async {
    await _fetchSummary();
    await _loadDeviceHistory();
  }

  /// Fetches the latest uplink and updates node 1’s displayed values
  Future<void> _fetchSummary() async {
    final p = await _ttn.latestUplink('smartvineyardnode');
    if (p.isEmpty) return;
    final n = widget.nodes[1]!; // Main node (Node 1)

    // Insert new uplink into history list (capped at 720 entries)
    _uplinkHistory.insert(0, {
      'timestamp': DateTime.now(),
      'data': p,
    });
    if (_uplinkHistory.length > 720) {
      _uplinkHistory.removeLast();
    }

    // Update WeatherNode fields with parsed values
    setState(() {
      if (p.containsKey('AT')) {
        // Air temperature: divide raw value by 100 to get °C
        n.temperature = '${double.parse(p['AT']!) / 100}°C';
      }
      if (p.containsKey('AH')) {
        // Air humidity: divide raw value by 100 to get %
        n.humidity = '${double.parse(p['AH']!) / 100}%';
      }
      if (p.containsKey('LT')) {
        // Leaf temperature: divide raw value by 100 to get °C
        n.leafTemp = '${double.parse(p['LT']!) / 100}°C';
      }
      if (p.containsKey('LW')) {
        // Leaf wetness: raw value is already a percentage
        n.leafWetness = '${double.parse(p['LW']!)}%';
      }
      // Update lastUpdated with current time in HH:MM format
      n.lastUpdated = TimeOfDay.now().format(context);
    });
  }

  /// Fetches 720 uplinks (~24h at 2-minute intervals), buckets into hours,
  /// and computes hourly average temperatures for charting.
  Future<void> _loadDeviceHistory() async {
    // Request last 720 samples from TTN
    final raw = await _ttn.fetchHistory('smartvineyardnode', limit: 720);
    final now = DateTime.now();

    // Bucket temperatures into hourly lists (key = hours ago)
    final Map<int, List<double>> hourly = {};
    for (var i = 0; i < raw.length; i++) {
      final t = raw[i]['AT'];
      if (t == null) continue;
      final temp = double.parse(t) / 100; // Convert raw to °C
      final ts    = now.subtract(Duration(minutes: i * 2)); // Estimate timestamp
      final ago   = now.difference(ts).inHours; // 0 = <1h ago, 23 = 23..24h ago
      if (ago < 24) {
        hourly.putIfAbsent(ago, () => []).add(temp);
      }
    }

    // Build 24 hourly-average points (x=0…23)
    final spots = <FlSpot>[];
    for (int x = 0; x < 24; x++) {
      final ago = 23 - x; // Reverse index so x=0 is 23h ago, x=23 is <1h ago
      final list = hourly[ago] ?? [];
      final avg  = list.isEmpty ? 0.0 : list.reduce((a, b) => a + b) / list.length;
      spots.add(FlSpot(x.toDouble(), avg));
    }

    // Compute Y-axis range with padding
    if (spots.isNotEmpty) {
      final ys = spots.map((s) => s.y);
      setState(() {
        _deviceSpots = spots;
        _minY = ys.reduce(min) - 1;
        _maxY = ys.reduce(max) + 1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final node1 = widget.nodes[1]!; // Main node data
    final hour  = DateTime.now().hour;
    final isDay = hour >= 6 && hour < 18; // Determine if it's day or night

    return Scaffold(
      backgroundColor: const Color(0xff87CEEB),
      appBar: AppBar(
        backgroundColor: const Color(0xff87CEEB),
        elevation: 0,
        centerTitle: true,
        title: Text('Kumeu Vineyard – ${node1.name}'),
        // Button to view the uplink log (pushes LogPage)
        leading: IconButton(
          icon: const Icon(Icons.list_alt, color: Colors.white),
          tooltip: 'View Uplink Log',
          onPressed: () => Navigator.pushNamed(context, '/logs'),
        ),
        actions: [
          // Button to view notifications for Node 1
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white),
            tooltip: '${node1.name} Notifications',
            onPressed: () => Navigator.pushNamed(
                context, '/node_notification', arguments: 1),
          ),
          // Button to view all notifications
          IconButton(
            icon: const Icon(Icons.notifications, color: Colors.white),
            tooltip: 'All Notifications',
            onPressed: () => Navigator.pushNamed(context, '/all_notifications'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Summary card showing date, temperature, status, and leaf readings
            _summaryCard(node1, isDay),
            const SizedBox(height: 16),

            // Buttons to navigate to NodeLocationPage for Node 1 and Node 2
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pushNamed(
                        context, '/node_location', arguments: 1),
                    child: const Text('Main Node'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pushNamed(
                        context, '/node_location', arguments: 2),
                    child: const Text('Node 2'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Display 24-hour average temperature chart if data is available
            if (_deviceSpots.isNotEmpty) _deviceChart(),
            const SizedBox(height: 16),

            // Button to view Historical Data page
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                minimumSize: const Size.fromHeight(50),
              ),
              onPressed: () => Navigator.pushNamed(context, '/historical'),
              child: const Text('Historical Data (HortPlus)'),
            ),
            const SizedBox(height: 8),

            // Button to view Frost Prediction page
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black87,
                minimumSize: const Size.fromHeight(50),
              ),
              icon: const Icon(Icons.ac_unit),
              label: const Text('Frost Prediction'),
              onPressed: () =>
                  Navigator.pushNamed(context, '/frost_prediction'),
            ),
            const SizedBox(height: 16),

            // Button to view last 24h raw uplink history (pushes NodeHistoryPage)
            ElevatedButton.icon(
              icon: const Icon(Icons.history),
              label: const Text('View 24h History'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(25),
                ),
              ),
              onPressed: () async {
                // Fetch the last 24 hours of uplinks (~720 samples @2min)
                final rawHist = await _ttn.fetchHistory(
                  'smartvineyardnode',
                  limit: 720,
                );
                // Build the List<Map<String,dynamic>> required by NodeHistoryPage:
                final history = <Map<String, dynamic>>[];
                final now = DateTime.now();
                for (var i = 0; i < rawHist.length; i++) {
                  final entry = rawHist[i];
                  history.add({
                    'timestamp': now.subtract(Duration(minutes: i * 2)),
                    'data': entry,
                  });
                }
                // Navigate to NodeHistoryPage with constructed history
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NodeHistoryPage(history: history),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the summary card showing date, icon, temperature, status, and leaf metrics
  Card _summaryCard(WeatherNode n, bool isDay) => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        // Display current date in DD/MM/YYYY format
        Text(
          DateFormat('dd/MM/yyyy').format(DateTime.now()),
          style: const TextStyle(fontSize: 18, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Display sun or moon icon based on time of day
            Icon(
                isDay ? Icons.wb_sunny : Icons.nightlight_round,
                color: Colors.orange, size: 28),
            const SizedBox(width: 6),
            // Display main node temperature in large bold font
            Text(n.temperature,
                style: const TextStyle(
                    fontSize: 48, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 4),
        // Display status (Active/Inactive) in grey
        Text('Status: ${n.status}',
            style: const TextStyle(fontSize: 18, color: Colors.grey)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left column: last update time and leaf temperature
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Last: ${n.lastUpdated}',
                  style: const TextStyle(color: Colors.grey)),
              Text('Leaf Temp: ${n.leafTemp}',
                  style: const TextStyle(color: Colors.grey)),
            ]),
            // Right column: humidity and leaf wetness
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('Hum: ${n.humidity}',
                  style: const TextStyle(color: Colors.grey)),
              Text('Leaf Wetness: ${n.leafWetness}',
                  style: const TextStyle(color: Colors.grey)),
            ]),
          ],
        ),
      ]),
    ),
  );

  /// Builds a 24-hour average temperature chart using FL Chart
  Widget _deviceChart() {
    final spots = _deviceSpots;
    final now   = DateTime.now();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: AspectRatio(
          aspectRatio: 1.7, // Defines the width/height ratio of the chart
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: 23,
              minY: _minY,
              maxY: _maxY,
              // Configure grid lines (horizontal, dashed)
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: (_maxY - _minY) / 4,
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: Colors.grey.withOpacity(0.2), dashArray: [5,5]),
              ),
              // Draw border around the chart
              borderData: FlBorderData(
                show: true,
                border: Border.all(color: Colors.grey.withOpacity(0.4), width: 1),
              ),
              titlesData: FlTitlesData(
                // Hide top and right titles
                topTitles:   AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                // Configure left Y-axis titles and label
                leftTitles: AxisTitles(
                  axisNameWidget: const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text('Temp (°C)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  axisNameSize: 20,
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: (_maxY - _minY) / 4,
                    reservedSize: 40,
                    getTitlesWidget: (v, _) =>
                        Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
                  ),
                ),
                // Configure bottom X-axis titles and label
                bottomTitles: AxisTitles(
                  axisNameWidget: const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Time', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  axisNameSize: 20,
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 1, // One label per hour
                    reservedSize: 30,
                    getTitlesWidget: (v, _) {
                      // Convert x-value to actual timestamp label (HH:00)
                      final idx = v.toInt().clamp(0, 23);
                      final ts  = now.subtract(Duration(hours: 23 - idx));
                      return Text(DateFormat('HH:00').format(ts),
                          style: const TextStyle(fontSize: 10));
                    },
                  ),
                ),
              ),
              // Define line style and fill gradient below
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  barWidth: 3,
                  color: Colors.blue.shade700,
                  dotData: FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.blue.shade200.withOpacity(0.5),
                        Colors.blue.shade200.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ],
              // Enable touch interactions with tooltips
              lineTouchData: LineTouchData(
                enabled: true,
                touchTooltipData: LineTouchTooltipData(
                  tooltipBgColor: Colors.grey.shade900.withOpacity(0.8),
                  getTooltipItems: (spots) => spots
                      .map((t) => LineTooltipItem(
                      '${t.y.toStringAsFixed(1)}°C',
                      TextStyle(color: t.bar.color, fontWeight: FontWeight.bold)))
                      .toList(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//                 ALL NODES NOTIFICATION PAGE
// ═══════════════════════════════════════════════════════════

class AllNotificationsPage extends StatelessWidget {
  final List<WeatherNode> nodes; // List of all weather nodes
  final VoidCallback onBack;     // Callback to pop this page

  const AllNotificationsPage({
    Key? key,
    required this.nodes,
    required this.onBack,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Build "New" notification using Node 1’s current temperature
    final node1 = nodes.firstWhere((n) => n.id == 1);
    final newNotif = NotificationData(
      'Temperature Update',
      'Current temperature is ${node1.temperature}.',
    );

    // Example "Earlier" notification for demonstration
    final earlierNotifs = <NotificationData>[
      NotificationData('Humidity Update', 'Current humidity is ${node1.humidity}.'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('All Notifications'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: onBack,
        ),
      ),
      body: ListView(
        children: [
          // Section header for new notifications
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('New', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          // Card displaying the new notification
          Card(
            color: Colors.lightBlue.shade50,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: const Icon(Icons.thermostat, color: Colors.redAccent, size: 32),
              title: Text(newNotif.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(newNotif.message),
              trailing: const Text('Just now', style: TextStyle(color: Colors.grey)),
            ),
          ),
          // Section header for earlier notifications
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('Earlier', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          // List of earlier notifications
          ...earlierNotifs.map((notif) => Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: const Icon(Icons.info_outline, color: Colors.blueGrey, size: 28),
              title: Text(notif.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(notif.message),
              trailing: const Text('1h ago', style: TextStyle(color: Colors.grey)),
            ),
          )),
        ],
      ),
    );
  }
}

/// Displays notifications for a single node (temperature/humidity).
class NodeNotificationPage extends StatelessWidget {
  final WeatherNode node;    // Specific node to display notifications for
  final VoidCallback onBack; // Callback to pop this page

  const NodeNotificationPage({
    Key? key,
    required this.node,
    required this.onBack,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Build a list of notifications for this node
    final notifs = <NotificationData>[
      NotificationData('Temperature', 'The temperature is ${node.temperature}.'),
      NotificationData('Humidity', 'The humidity is ${node.humidity}.'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${node.name} Notifications'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: onBack,
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: notifs.length,
        itemBuilder: (_, i) => Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: Icon(
              i == 0 ? Icons.thermostat : Icons.water_drop,
              color: i == 0 ? Colors.redAccent : Colors.blueAccent,
              size: 32,
            ),
            title: Text(notifs[i].title, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(notifs[i].message),
            trailing: const Text('Just now', style: TextStyle(color: Colors.grey)),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//          NODE LOCATION PAGE (Detail View with Dew Point)
// ═══════════════════════════════════════════════════════════

class NodeLocationPage extends StatefulWidget {
  final WeatherNode node; // Specific node to display details for
  const NodeLocationPage({Key? key, required this.node}) : super(key: key);

  @override
  _NodeLocationPageState createState() => _NodeLocationPageState();
}

class _NodeLocationPageState extends State<NodeLocationPage> {
  static const _skyBlue = Color(0xff87CEEB); // Background color
  final _ttn = TtnService(); // TTN service for data fetching
  late Timer _timer;         // Timer to schedule periodic refresh

  // Map to hold sensor values as strings; initialized to "--"
  Map<String, String> _vals = {
    'temperature': '--',
    'humidity':    '--',
    'leafWetness': '--',
    'leafTemp':    '--',
    'skyTemp':     '--',
    'windDir':     '--',
    'windSpeed':   '--',
    'batteryVolt': '--',
    'dewPoint':    '--',
  };

  @override
  void initState() {
    super.initState();
    _refresh(); // Initial fetch of sensor values
    // Schedule refresh every 30 seconds
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  /// Fetches the latest uplink and updates all sensor values including dew point.
  Future<void> _refresh() async {
    try {
      final p = await _ttn.latestUplink('smartvineyardnode');
      if (p.isEmpty) return;

      double? t, h; // Local variables to hold temperature and humidity

      setState(() {
        if (p.containsKey('AT')) {
          // Convert raw AT to °C and store in _vals
          t = double.parse(p['AT']!) / 100;
          _vals['temperature'] = '${t!.toStringAsFixed(1)}°C';
        }
        if (p.containsKey('AH')) {
          // Convert raw AH to % and store in _vals
          h = double.parse(p['AH']!) / 100;
          _vals['humidity'] = '${h!.toStringAsFixed(1)}%';
        }
        if (p.containsKey('LW')) {
          // Leaf wetness is provided as percentage
          _vals['leafWetness'] = '${int.parse(p['LW']!)}%';
        }
        if (p.containsKey('LT')) {
          // Convert raw LT to °C and store in _vals
          _vals['leafTemp'] = '${double.parse(p['LT']!) / 100}°C';
        }
        if (p.containsKey('IC')) {
          // Sky temperature from infrared camera (divide by 10 for °C)
          _vals['skyTemp']  = '${double.parse(p['IC']!) / 10}°C';
        }
        if (p.containsKey('WD')) {
          // Wind direction in degrees
          _vals['windDir']  = '${int.parse(p['WD']!)}°';
        }
        if (p.containsKey('WS')) {
          // Wind speed: convert raw to m/s (divide by 100)
          _vals['windSpeed']= '${double.parse(p['WS']!) / 100} m/s';
        }
        if (p.containsKey('BV')) {
          // Battery voltage: convert raw to V (divide by 100)
          _vals['batteryVolt'] = '${double.parse(p['BV']!) / 100} V';
        }

        // Compute dew point if both temperature and humidity are available
        if (t != null && h != null) {
          const a = 17.27, b = 237.7;
          final gamma = (a * t! / (b + t!)) + log(h! / 100);
          final dp    = b * gamma / (a - gamma);
          _vals['dewPoint'] = '${dp.toStringAsFixed(1)}°C';
        }
      });
    } catch (e) {
      debugPrint('Location fetch error: $e');
    }
  }

  @override
  void dispose() {
    _timer.cancel(); // Cancel the timer when disposing
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Construct a list of SensorInfo objects to display in a grid
    final items = <SensorInfo>[
      SensorInfo('Temperature',  _vals['temperature']!, Icons.thermostat),
      SensorInfo('Humidity',     _vals['humidity']!,    Icons.water_drop),
      SensorInfo('Leaf Wetness', _vals['leafWetness']!, Icons.energy_savings_leaf),
      SensorInfo('Leaf Temp',    _vals['leafTemp']!,    Icons.device_thermostat),
      SensorInfo('Sky Temp',     _vals['skyTemp']!,     Icons.cloud),
      SensorInfo('Wind Dir',     _vals['windDir']!,     Icons.explore),
      SensorInfo('Wind Speed',   _vals['windSpeed']!,   Icons.air),
      SensorInfo('Battery Volt', _vals['batteryVolt']!, Icons.battery_full),
      SensorInfo('Dew Point',    _vals['dewPoint']!,    Icons.opacity),
    ];

    return Scaffold(
      backgroundColor: _skyBlue,
      appBar: AppBar(
        backgroundColor: _skyBlue,
        elevation: 0,
        title: Text('${widget.node.name} Location'),
        leading: const BackButton(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        // Display sensor values in a 2-column grid
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 3 / 2,
          children: items.map((info) => Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(info.icon, size: 32, color: Colors.blueAccent),
                  const SizedBox(height: 8),
                  Text(
                    info.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(info.value, style: const TextStyle(fontSize: 20)),
                ],
              ),
            ),
          )).toList(),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//         HISTORICAL DATA PAGE (CSV-Backed Hourly Chart)
// ═══════════════════════════════════════════════════════════

class HistoricalDataPage extends StatefulWidget {
  const HistoricalDataPage({Key? key}) : super(key: key);

  @override
  State<HistoricalDataPage> createState() => _HistoricalDataPageState();
}

class _HistoricalDataPageState extends State<HistoricalDataPage> {
  static const _skyBlue   = Color(0xff87CEEB);
  static const _assetPath = 'assets/data/daily_avg_6m.csv'; // Path to CSV asset

  String _selectedDuration = '1_week'; // Selected time span key
  List<GraphData> _data = [];         // Parsed GraphData points
  bool _loading = true;               // Indicates if CSV is being parsed

  // Map of duration keys to display labels
  final Map<String, String> _durations = {
    '1_week':   '1 Week',
    '1_month':  '1 Month',
    '3_months': '3 Months',
    '6_months': '6 Months',
  };

  @override
  void initState() {
    super.initState();
    _loadData(); // Load and parse CSV upon initialization
  }

  /// Loads and parses CSV, selects rows matching the current hour, and builds _data list
  Future<void> _loadData() async {
    setState(() => _loading = true);

    // 1) Load CSV from assets
    final raw  = await rootBundle.loadString(_assetPath);
    final rows = const CsvToListConverter()
        .convert(raw, eol: '\n')
        .skip(1) // Skip header row
        .toList(); // Each row: [dateString, hourLabel, numeric values...]

    // 2) Group rows by date string (preserves chronological order)
    final grouped = <String, List<List<dynamic>>>{};
    for (final r in rows) {
      final date = r[0] as String;
      grouped.putIfAbsent(date, () => []).add(r);
    }

    // 3) Determine how many days back based on selected duration
    int spanDays;
    switch (_selectedDuration) {
      case '1_week':   spanDays = 7;   break;
      case '1_month':  spanDays = 30;  break;
      case '3_months': spanDays = 90;  break;
      default:         spanDays = 184; break; // '6_months'
    }
    final allDates = grouped.keys.toList();
    final daysToShow = min(spanDays, allDates.length);
    final recentDates = allDates.sublist(allDates.length - daysToShow);

    // 4) Construct current-hour label (e.g., "6 - 7PM")
    final now = DateTime.now();
    final h24 = now.hour;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final suffix = h24 < 12 ? 'AM' : 'PM';
    final h12Next = (h12 % 12) + 1;
    final targetLabel = '$h12 - $h12Next$suffix';

    // 5) Build GraphData entries for each recent date
    _data = [];
    for (var i = 0; i < recentDates.length; i++) {
      final day = recentDates[i];
      final dayRows = grouped[day]!;

      // Find row matching current hour, or fallback to first row
      final row = dayRows.firstWhere(
            (r) => r[1] == targetLabel,
        orElse: () => dayRows.first,
      );

      // Extract first four numeric values after date and hour columns
      final numerics = row
          .skip(2) // Skip date & hour columns
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      if (numerics.length < 4) continue;

      final temp = numerics[0];
      final hum  = numerics[1];
      final lw   = numerics[2];
      final lt   = numerics[3];

      // Construct timestamp at current hour for this date
      final ts = DateTime(
        now.year,
        now.month,
        now.day - (daysToShow - 1 - i),
        h24,
      );

      _data.add(GraphData(ts, temp, hum, lw, lt));
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _skyBlue,
      appBar: AppBar(
        backgroundColor: _skyBlue,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        title: const Text(
          'Historical Data (Hourly at Current Time)',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Dropdown to select time span (1 Week, 1 Month, etc.)
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedDuration,
                    items: _durations.entries
                        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _selectedDuration = v);
                      _loadData(); // Reload data when selection changes
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Show spinner while loading, or message if no data
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_data.isEmpty)
              const Expanded(child: Center(child: Text('No data for this period')))
            else
              _buildChartSection(),

            // If data is available, show the list of daily values below chart
            if (!_loading && _data.isNotEmpty) ...[
              const SizedBox(height: 16),
              Expanded(child: _buildDataList()),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the chart section with a LineChart and its legend
  Widget _buildChartSection() {
    return Column(
      children: [
        SizedBox(
          height: 300,
          child: Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.only(left: 60, top: 16, right: 16, bottom: 60),
              child: LineChart(_buildChartData()),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildLegend(), // Legend row below the chart
      ],
    );
  }

  /// Configures LineChartData for four series: Temp, Hum, Leaf Temp, Leaf Wet
  LineChartData _buildChartData() {
    final tSpots = <FlSpot>[];
    final hSpots = <FlSpot>[];
    final lWSpots = <FlSpot>[];
    final lTSpots = <FlSpot>[];

    // Populate FlSpot lists for each metric
    for (var i = 0; i < _data.length; i++) {
      final gd = _data[i];
      tSpots .add(FlSpot(i.toDouble(), gd.temperature));
      hSpots .add(FlSpot(i.toDouble(), gd.humidity));
      lWSpots.add(FlSpot(i.toDouble(), gd.leafWetness));
      lTSpots.add(FlSpot(i.toDouble(), gd.leafTemp));
    }

    // Determine overall Y-axis range with padding
    final allYs = [
      ...tSpots.map((s) => s.y),
      ...hSpots.map((s) => s.y),
      ...lWSpots.map((s) => s.y),
      ...lTSpots.map((s) => s.y),
    ];
    final minY = allYs.isEmpty ? 0.0 : allYs.reduce(min) - 1;
    final maxY = allYs.isEmpty ? 1.0 : allYs.reduce(max) + 1;
    final yInterval = (maxY - minY) <= 0 ? 1.0 : (maxY - minY) / 4;

    final count = _data.length;
    final xInterval = count < 2 ? 1.0 : (count / 6).ceilToDouble();

    return LineChartData(
      minX: 0,
      maxX: (count - 1).toDouble(),
      minY: minY,
      maxY: maxY,
      // Configure grid lines
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: yInterval,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: Colors.grey.withOpacity(0.2), dashArray: [5, 5]),
      ),
      // Draw border around chart
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: Colors.grey.withOpacity(0.4)),
      ),
      titlesData: FlTitlesData(
        // Hide top and right axis titles
        topTitles:   AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        // Configure left Y-axis with label 'Value'
        leftTitles: AxisTitles(
          axisNameWidget: const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child:
            Text('Value', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          axisNameSize: 24,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 50,
            interval: yInterval,
            getTitlesWidget: (v, _) =>
                Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
          ),
        ),
        // Configure bottom X-axis with date labels
        bottomTitles: AxisTitles(
          axisNameWidget: const Padding(
            padding: EdgeInsets.only(top: 8),
            child:
            Text('Date', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          axisNameSize: 24,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            interval: xInterval,
            getTitlesWidget: (v, _) {
              final idx = v.toInt().clamp(0, _data.length - 1);
              return Text(
                DateFormat('MM/dd').format(_data[idx].timestamp),
                style: const TextStyle(fontSize: 10),
              );
            },
          ),
        ),
      ),
      // Define four series for the chart
      lineBarsData: [
        LineChartBarData(
          spots: tSpots,
          isCurved: true,
          color: Colors.blue,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
        LineChartBarData(
          spots: hSpots,
          isCurved: true,
          color: Colors.green,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
        LineChartBarData(
          spots: lTSpots,
          isCurved: true,
          color: Colors.orange,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
        LineChartBarData(
          spots: lWSpots,
          isCurved: true,
          color: Colors.purple,
          barWidth: 2,
          dotData: FlDotData(show: false),
        ),
      ],
      // Enable touch tooltips
      lineTouchData: LineTouchData(
        enabled: true,
        touchTooltipData: LineTouchTooltipData(
          tooltipBgColor: Colors.grey.shade900.withOpacity(0.8),
          getTooltipItems: (spots) => spots.map((spot) {
            return LineTooltipItem(
              spot.y.toStringAsFixed(1),
              TextStyle(color: spot.bar.color, fontWeight: FontWeight.bold),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// Builds a legend row showing color swatches and labels
  Widget _buildLegend() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: const [
          _LegendItem(color: Colors.blue,   label: 'Temp'),
          _LegendItem(color: Colors.green,  label: 'Hum'),
          _LegendItem(color: Colors.orange, label: 'Leaf Temp'),
          _LegendItem(color: Colors.purple, label: 'Leaf Wet'),
        ],
      ),
    );
  }

  /// Builds a vertical list of daily timestamped values below the chart
  Widget _buildDataList() {
    return ListView.separated(
      separatorBuilder: (_, __) => const Divider(height: 0),
      itemCount: _data.length,
      itemBuilder: (ctx, i) {
        final d = _data[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            // Display date and hour
            title: Text(DateFormat('dd/MM/yyyy – HH:00').format(d.timestamp)),
            subtitle: Text(
              'T: ${d.temperature.toStringAsFixed(1)}°C, '
                  'H: ${d.humidity.toStringAsFixed(0)}%, '
                  'L.T: ${d.leafTemp.toStringAsFixed(1)}°C, '
                  'L.W: ${d.leafWetness.toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }
}

/// Legend item widget: a small colored bar with a label
class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext c) => Row(
    children: [
      Container(width: 16, height: 4, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}

// ═══════════════════════════════════════════════════════════
//          FROST PREDICTION PAGE (ML Model Integration)
// ═══════════════════════════════════════════════════════════

class FrostPredictionPage extends StatefulWidget {
  const FrostPredictionPage({Key? key}) : super(key: key);

  @override
  _FrostPredictionPageState createState() => _FrostPredictionPageState();
}

class _FrostPredictionPageState extends State<FrostPredictionPage> {
  static const _skyBlue = Color(0xff87CEEB); // Background color
  // API endpoint switches based on platform (web vs. Android emulator)
  static final _apiUrl = kIsWeb
      ? 'http://localhost:8000/predict'
      : 'http://10.0.2.2:8000/predict';
  final TtnService _ttn = TtnService(); // TTN service for history fetch

  bool _loading = false;    // Indicates if prediction is in progress
  List<FlSpot> _preds = []; // Holds predicted temperature points
  bool? _willFrost;         // True if any predicted temperature ≤ 0°C

  @override
  void initState() {
    super.initState();
    _runPrediction(); // Initial prediction when page loads
  }

  /// Computes dew point (°C) given temperature T (°C) and humidity H (%)
  double _dewPoint(double T, double H) {
    const a = 17.27, b = 237.7;
    final gamma = (a * T / (b + T)) + log(H / 100);
    return b * gamma / (a - gamma);
  }

  /// Fetches last 24h of sensor data, aggregates into hourly features,
  /// sends JSON payload to ML server, and parses predicted temperatures.
  Future<void> _runPrediction() async {
    debugPrint('🌀 _runPrediction starting…');
    setState(() => _loading = true);

    try {
      // 1) Fetch raw history (~720 samples for 24h)
      final raw = await _ttn.fetchHistory('smartvineyardnode', limit: 720);
      debugPrint('📥 raw.length = ${raw.length}');

      final now = DateTime.now();
      // Map hour index (0..23) to list of feature lists [T, LW, H, WS, DP]
      final Map<int, List<List<double>>> hourly = {};

      // 2) Bucket each reading into the appropriate hour
      for (var i = 0; i < raw.length; i++) {
        final m = raw[i];
        // Skip if missing temperature or humidity
        if (!m.containsKey('AT') || !m.containsKey('AH')) continue;
        final T  = double.parse(m['AT']!) / 100;         // Temperature in °C
        final H  = double.parse(m['AH']!) / 100;         // Humidity in %
        final LW = double.parse(m['LW'] ?? '0');         // Leaf wetness (%)
        final WS = double.parse(m['WS'] ?? '0') / 100;   // Wind speed in m/s
        final DP = _dewPoint(T, H);                      // Dew point in °C

        // Estimate timestamp for this reading
        final ts  = now.subtract(Duration(minutes: i * 2));
        final ago = now.difference(ts).inHours; // Hours ago (0..23)
        if (ago < 24) {
          final bucket = 23 - ago; // Reverse index so 0 = 23h ago, 23 = <1h
          hourly.putIfAbsent(bucket, () => []).add([T, LW, H, WS, DP]);
        }
      }

      // 3) Compute hourly mean features for 24 hours and flatten into a 1×24×5 array
      final List<double> features = [];
      for (var h = 0; h < 24; h++) {
        final feats = hourly[h] ?? [];
        if (feats.isEmpty) {
          // If no data for this hour, use zeros
          features.addAll([0, 0, 0, 0, 0]);
        } else {
          // Sum each feature across all samples, then divide by count for mean
          final sums = feats.reduce(
                (a, b) => List.generate(5, (i) => a[i] + b[i]),
          );
          features.addAll(sums.map((s) => s / feats.length));
        }
      }

      // Reshape into 24 sublists of length 5
      final matrix24x5 = List.generate(
        24,
            (i) => features.sublist(i * 5, i * 5 + 5),
      );
      // Create JSON payload: {"features": [[ [h0_f0, h0_f1,…], …, [h23_f0,…] ]]}
      final payload = jsonEncode({'features': [matrix24x5]});

      debugPrint('📤 POST $_apiUrl');
      debugPrint('▶️ Payload: $payload');

      // 4) Send POST request to ML server
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: payload,
      );

      debugPrint('⬅️ Status: ${response.statusCode}');
      debugPrint('⬅️ Body: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }

      // 5) Parse predictions array from response JSON
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final List preds = data['predictions'];
      debugPrint('🔮 preds.length = ${preds.length}');

      if (preds.isEmpty) {
        throw Exception('Empty predictions array');
      }

      // 6) Build FlSpot list for chart and set frost-expected flag
      setState(() {
        _preds = List.generate(
          preds.length,
              (i) => FlSpot(i.toDouble(), (preds[i] as num).toDouble()),
        );
        _willFrost = preds.any((p) => (p as num) <= 0);
      });
    } catch (e, st) {
      debugPrint('❌ _runPrediction error: $e\n$st');
      // Show error snackbar to user
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _loading = false);
      debugPrint('✅ _runPrediction done. loading=$_loading, spots=${_preds.length}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final safe = _willFrost ?? false; // Determines which icon to show

    return Scaffold(
      backgroundColor: _skyBlue,
      appBar: AppBar(
        backgroundColor: _skyBlue,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        title: const Text(
          '3-Hour Frost Prediction',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        // Show spinner if loading; otherwise display status and chart
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
          children: [
            // Card showing frost expected or not
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      safe ? Icons.warning : Icons.check,
                      color: safe ? Colors.red : Colors.green,
                      size: 28,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      safe ? '⚠️ Frost Expected' : '✅ No Frost Expected',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: safe ? Colors.red : Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Display the prediction chart if data is available
            if (_preds.isNotEmpty)
              Expanded(
                child: Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(60, 16, 16, 60),
                    child: LineChart(
                      LineChartData(
                        minX: 0,
                        maxX: (_preds.length - 1).toDouble(),
                        minY: _preds.map((s) => s.y).reduce(min) - 2,
                        maxY: _preds.map((s) => s.y).reduce(max) + 2,
                        // Basic grid and border setup
                        gridData:  FlGridData(show: true),
                        borderData:  FlBorderData(show: true),
                        titlesData: FlTitlesData(
                          bottomTitles: AxisTitles(
                            axisNameWidget: const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('Hours from now',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                            sideTitles:  SideTitles(
                              showTitles: true,
                              interval: 1, // Label each hour
                              getTitlesWidget: (v, _) =>
                                  Text('${v.toInt()}h',
                                      style: TextStyle(fontSize: 10)),
                            ),
                          ),
                          leftTitles: AxisTitles(
                            axisNameWidget: const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Text('Temp (°C)',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                            sideTitles: SideTitles(
                              showTitles: true,
                              interval: ((_preds
                                  .map((s) => s.y)
                                  .reduce(max) -
                                  _preds
                                      .map((s) => s.y)
                                      .reduce(min)) /
                                  4)
                                  .clamp(1, double.infinity),
                              getTitlesWidget: (v, _) =>
                                  Text('${v.toInt()}°',
                                      style: const TextStyle(
                                          fontSize: 10)),
                            ),
                          ),
                        ),
                        // Single series line for predictions
                        lineBarsData: [
                          LineChartBarData(
                            spots: _preds,
                            isCurved: true,
                            barWidth: 3,
                            dotData:  FlDotData(show: false),
                            color:
                            Theme.of(context).colorScheme.secondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            // Button to re-run prediction
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Re-run Prediction'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25)),
              ),
              onPressed: _runPrediction,
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//           NODE HISTORY PAGE (Last 24h Multi-Series)
// ═══════════════════════════════════════════════════════════

class NodeHistoryPage extends StatefulWidget {
  /// Expects a list of maps: { 'timestamp': DateTime, 'data': Map<String,String> }
  final List<Map<String, dynamic>> history;
  const NodeHistoryPage({Key? key, required this.history}) : super(key: key);

  @override
  _NodeHistoryPageState createState() => _NodeHistoryPageState();
}

class _NodeHistoryPageState extends State<NodeHistoryPage> {
  static const _skyBlue = Color(0xff87CEEB);

  List<FlSpot> _tSpots = [], _hSpots = [], _lTSpots = [], _lWSpots = []; // Lists for four metrics
  double _minY = 0, _maxY = 0; // Y-axis range
  bool _loaded = false; // Indicates if data has been processed

  @override
  void initState() {
    super.initState();
    _buildChartData(); // Build chart data immediately
  }

  /// Processes raw history to compute 24-hour average spots for temperature, humidity,
  /// leaf temperature, and leaf wetness.
  void _buildChartData() {
    final now = DateTime.now();
    final hourlyT  = <int, List<double>>{};
    final hourlyH  = <int, List<double>>{};
    final hourlyLT = <int, List<double>>{};
    final hourlyLW = <int, List<double>>{};

    // Bucket each entry by hours ago
    for (final entry in widget.history) {
      final ts   = entry['timestamp'] as DateTime;
      final agoH = now.difference(ts).inHours;
      if (agoH < 24) {
        // Parse raw sensor data map
        final data = Map<String, String>.from(entry['data'] as Map);
        final at = data['AT'] != null ? double.parse(data['AT']!)  / 1000 : null;  // Air temp (°C)
        final ah = data['AH'] != null ? double.parse(data['AH']!)  / 10000 : null; // Humidity (%)
        final lt = data['LT'] != null ? double.parse(data['LT']!)  / 100 : null;   // Leaf temp (°C)
        final lw = data['LW'] != null ? double.parse(data['LW']!)      : null;    // Leaf wetness (%)

        if (at != null)  hourlyT .putIfAbsent(agoH, () => []).add(at);
        if (ah != null)  hourlyH .putIfAbsent(agoH, () => []).add(ah);
        if (lt != null) hourlyLT.putIfAbsent(agoH, () => []).add(lt);
        if (lw != null) hourlyLW.putIfAbsent(agoH, () => []).add(lw);
      }
    }

    // Build 24 hourly-average FlSpot lists
    List<FlSpot> tSp = [], hSp = [], lTSp = [], lWSp = [];
    for (int x = 0; x < 24; x++) {
      final ago = 23 - x; // Reverse index so x=0 is 23h ago
      double avg(List<double>? list) =>
          (list == null || list.isEmpty) ? 0.0 : list.reduce((a,b) => a+b) / list.length;
      tSp .add(FlSpot(x.toDouble(), avg(hourlyT [ago])));
      hSp .add(FlSpot(x.toDouble(), avg(hourlyH [ago])));
      lTSp.add(FlSpot(x.toDouble(), avg(hourlyLT[ago])));
      lWSp.add(FlSpot(x.toDouble(), avg(hourlyLW[ago])));
    }

    // Compute overall Y-axis range with padding
    final allYs = [
      ...tSp.map((s) => s.y),
      ...hSp.map((s) => s.y),
      ...lTSp.map((s) => s.y),
      ...lWSp.map((s) => s.y),
    ];
    final minY = allYs.isEmpty ? 0.0 : allYs.reduce(min) - 1;
    final maxY = allYs.isEmpty ? 1.0 : allYs.reduce(max) + 1;

    setState(() {
      _tSpots  = tSp;
      _hSpots  = hSp;
      _lTSpots = lTSp;
      _lWSpots = lWSp;
      _minY    = minY;
      _maxY    = maxY;
      _loaded  = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _skyBlue,
      appBar: AppBar(
        backgroundColor: _skyBlue,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        title: const Text(
          'Last 24h Sensor History',
          style: TextStyle(color: Colors.white),
        ),
      ),
      // If data is not yet loaded, show spinner
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Chart section: multi-series line chart
            SizedBox(
              height: 300,
              child: Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(60, 16, 16, 40),
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: 23,
                      minY: _minY,
                      maxY: _maxY,
                      // Configure grid lines (horizontal, dashed)
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: (_maxY - _minY) / 4,
                        getDrawingHorizontalLine: (_) => FlLine(
                            color: Colors.grey.withOpacity(0.2),
                            dashArray: [5, 5]),
                      ),
                      // Draw border around chart
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(
                            color: Colors.grey.withOpacity(0.4),
                            width: 1),
                      ),
                      titlesData: FlTitlesData(
                        topTitles:
                        AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles:
                        AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        // Left Y-axis title and tick labels
                        leftTitles: AxisTitles(
                          axisNameWidget: const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text('Value',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                          ),
                          axisNameSize: 20,
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: (_maxY - _minY) / 4,
                            reservedSize: 40,
                            getTitlesWidget: (v, _) => Text(
                                v.toStringAsFixed(0),
                                style: const TextStyle(fontSize: 10)),
                          ),
                        ),
                        // Bottom X-axis title and tick labels
                        bottomTitles: AxisTitles(
                          axisNameWidget: const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('Hours ago',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                          ),
                          axisNameSize: 20,
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 6, // Label every 6 hours
                            reservedSize: 30,
                            getTitlesWidget: (v, _) {
                              final hrsAgo = 23 - v.toInt();
                              return Text('-${hrsAgo}h',
                                  style: const TextStyle(fontSize: 10));
                            },
                          ),
                        ),
                      ),
                      // Four series: temperature, humidity, leaf temp, leaf wetness
                      lineBarsData: [
                        LineChartBarData(
                          spots: _tSpots,
                          isCurved: true,
                          barWidth: 2,
                          dotData: FlDotData(show: false),
                          color: Colors.blue.shade700,
                        ),
                        LineChartBarData(
                          spots: _hSpots,
                          isCurved: true,
                          barWidth: 2,
                          dotData: FlDotData(show: false),
                          color: Colors.green.shade700,
                        ),
                        LineChartBarData(
                          spots: _lTSpots,
                          isCurved: true,
                          barWidth: 2,
                          dotData: FlDotData(show: false),
                          color: Colors.orange.shade700,
                        ),
                        LineChartBarData(
                          spots: _lWSpots,
                          isCurved: true,
                          barWidth: 2,
                          dotData: FlDotData(show: false),
                          color: Colors.purple.shade700,
                        ),
                      ],
                      // Enable touch tooltips
                      lineTouchData: LineTouchData(
                        enabled: true,
                        touchTooltipData: LineTouchTooltipData(
                          tooltipBgColor:
                          Colors.grey.shade900.withOpacity(0.8),
                          getTooltipItems: (spots) => spots.map((s) {
                            return LineTooltipItem(
                              '${s.y.toStringAsFixed(1)}',
                              TextStyle(
                                  color: s.bar.color,
                                  fontWeight: FontWeight.bold),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    swapAnimationDuration:
                    const Duration(milliseconds: 300), // Animation on data change
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Legend row for the chart
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: const [
                _LegendItem(color: Colors.blue, label: 'Temp'),
                _LegendItem(color: Colors.green, label: 'Hum'),
                _LegendItem(color: Colors.orange, label: 'Leaf Temp'),
                _LegendItem(color: Colors.purple, label: 'Leaf Wet'),
              ],
            ),
            const SizedBox(height: 16),
            // List of hourly stats (Temperature, Humidity, Leaf metrics)
            Expanded(
              child: ListView.separated(
                separatorBuilder: (_, __) => const Divider(height: 0),
                itemCount: 24,
                itemBuilder: (ctx, x) {
                  final hrsAgo = 23 - x;
                  final t = _tSpots[x].y;         // Temperature
                  final h = _hSpots[x].y * 100;   // Humidity percentage
                  final lt = _lTSpots[x].y;       // Leaf temperature
                  final lw = _lWSpots[x].y;       // Leaf wetness
                  return Card(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      title: Text(
                        '-${hrsAgo}h',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        'Temperature: ${t.toStringAsFixed(1)}°C, '
                            'Humidity: ${h.toStringAsFixed(0)}%, '
                            'Leaf Temp: ${lt.toStringAsFixed(1)}°C, '
                            'Leaf Wetness: ${lw.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Legend item for charts (color bar + label)
class _LegendItem1 extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem1({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(width: 16, height: 4, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ]);
  }
}
