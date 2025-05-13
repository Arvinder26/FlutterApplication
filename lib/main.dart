// -----------------------------------------------------------
//  main.dart   ––  Frost‑Detection demo (ThingsBoard enabled)
//  Compatible with Flutter 3.x
// -----------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';    // ← NEW


// ────────────────────────────────────────────────────────────
//       Hortplus data model and service (all in main.dart)
// ────────────────────────────────────────────────────────────

class HourlyData {
  final DateTime timestamp;
  final double? airTempC;
  final double? rainfallMm;
  final double? leafWetnessPct;
  final double? humidityPct;
  final double? windSpeedKmh;
  final int? windDirDeg;
  final String? sprayDriftRisk;

  HourlyData({
    required this.timestamp,
    this.airTempC,
    this.rainfallMm,
    this.leafWetnessPct,
    this.humidityPct,
    this.windSpeedKmh,
    this.windDirDeg,
    this.sprayDriftRisk,
  });

  factory HourlyData.fromJson(Map<String, dynamic> json) {
    return HourlyData(
      timestamp: DateTime.parse(json['DateTime'] as String),
      airTempC:       (json['Air Temp (°C)']         as num?)?.toDouble(),
      rainfallMm:     (json['Rainfall (mm)']         as num?)?.toDouble(),
      leafWetnessPct: (json['Leaf Wetness (%)']      as num?)?.toDouble(),
      humidityPct:    (json['Relative Humidity (%)'] as num?)?.toDouble(),
      windSpeedKmh:   (json['Wind Speed (km/h)']     as num?)?.toDouble(),
      windDirDeg:     (json['Wind Direction']        as num?)?.toInt(),
      sprayDriftRisk: json['Spray Drift Risk']       as String?,
    );
  }
}

class HortplusService {
  static const _baseUrl = 'https://api.metwatch.nz/api/legacy/historic/hourly';
  final DateTime start, stop;
  final String station;

  HortplusService({
    this.station = 'KMU',
    required this.start,
    required this.stop,
  });

  Future<List<HourlyData>> fetchHourlyJson() async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'station': station,
      'start': '${_ymd(start)} ${_hm(start)}:00',
      'stop':  '${_ymd(stop)} ${_hm(stop)}:00',
      'sr_type': 'nz_utc',
      'highcharts_format': 'true',
    });

    final res = await http.get(uri, headers: {'Accept':'application/json'});
    if (res.statusCode!=200) throw Exception('Hortplus ${res.statusCode}');
    final body = jsonDecode(res.body) as Map<String,dynamic>;

    // If you have a JSON endpoint already scraped, simply decode that array:
    final List<dynamic> rows = body['data'] ?? [];
    return rows.map((m) => HourlyData.fromJson(m as Map<String,dynamic>)).toList();
  }

  String _two(int n) => n.toString().padLeft(2,'0');
  String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
  String _hm(DateTime d)  => '${_two(d.hour)}:${_two(d.minute)}';
}

// ═══════════════════════════════════════════════════════════
//                TTN  CONFIG & SERVICE
// ═══════════════════════════════════════════════════════════

const String kTtnUrl        = 'https://au1.cloud.thethings.network';
const String kApplicationId = 'smartvineyardiot';
const String kTtnApiKey     = 'NNSXS.E5JOPD6HFWX6NDR6IUJJ7USOTN3LKGYIBOONBYA.DCFBU7CUAGOTSBWLDD3S4UBPGERXLMRTACOGRWHSPH75IN3BJFHQ';

class TtnService {
  /// Fetches the most recent uplink for [deviceId], returning only
  /// the decoded fields named in [keys].
  Future<Map<String, dynamic>> latestUplink(
      String deviceId,
      List<String> keys,
      ) async {
    final uri = Uri.parse(
      '$kTtnUrl/api/v3/as/applications/$kApplicationId'
          '/devices/$deviceId/packages/storage/uplink_message?limit=1',
    );

    final res = await http.get(uri, headers: {
      'Authorization': 'Bearer $kTtnApiKey',
      'Accept': 'text/event-stream',
    });

    if (res.statusCode != 200) {
      debugPrint('❌ TTN fetch failed (${res.statusCode}): ${res.body}');
      return {};
    }

    // TTN streams NDJSON; split on newlines and grab the last event
    final lines = res.body
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return {};

    // Decode the last line
    final eventJson = jsonDecode(lines.last);

    // 1) Extract the 'result' wrapper
    final result = (eventJson as Map).cast<String, dynamic>()['result'];

    // 2) Extract uplink_message
    final uplink = (result as Map).cast<String, dynamic>()['uplink_message'];

    // 3) Extract decoded_payload and force it into Map<String, dynamic>
    final decodedPayload = Map<String, dynamic>.from(
      (uplink as Map).cast<String, dynamic>()['decoded_payload'] as Map,
    );

    // 4) Return only the keys the caller asked for
    final out = <String, dynamic>{};
    for (var k in keys) {
      if (decodedPayload.containsKey(k)) {
        out[k] = decodedPayload[k];
      }
    }
    return out;
  }
}

extension on TtnService {
  /// Fetches up to [limit] of the most recent uplink messages for [deviceId],
  /// returning for each a map containing `received_at` plus any of the
  /// decoded payload fields named in [keys].
  Future<List<Map<String, dynamic>>> fetchHistory(
      String deviceId,
      List<String> keys, {
        int limit = 96,
      }) async {
    final uri = Uri.parse(
      '$kTtnUrl/api/v3/as/applications/$kApplicationId'
          '/devices/$deviceId/packages/storage/uplink_message'
          '?limit=$limit',
    );
    final res = await http.get(uri, headers: {
      'Authorization': 'Bearer $kTtnApiKey',
      'Accept': 'text/event-stream',
    });
    if (res.statusCode != 200) {
      debugPrint('❌ History fetch failed (${res.statusCode}): ${res.body}');
      return [];
    }

    final lines = res.body
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final out = <Map<String, dynamic>>[];

    for (final line in lines) {
      final eventJson = jsonDecode(line) as Map<String, dynamic>;
      final result = eventJson['result'] as Map<String, dynamic>;
      final uplink = result['uplink_message'] as Map<String, dynamic>;
      final decoded = Map<String, dynamic>.from(
        (uplink['decoded_payload'] ?? {}) as Map,
      );
      final receivedAt = result['received_at'] as String;

      final entry = <String, dynamic>{ 'received_at': receivedAt };
      for (final k in keys) {
        if (decoded.containsKey(k)) {
          entry[k] = decoded[k];
        }
      }
      out.add(entry);
    }

    return out;
  }
}


// ═══════════════════════════════════════════════════════════
//                     DATA  MODELS
// ═══════════════════════════════════════════════════════════
class GraphData {
  final DateTime timestamp;
  final double temperature, humidity;
  GraphData(this.timestamp, this.temperature, this.humidity);
}

List<GraphData> getMockData(String duration) {
  final rnd = Random();
  final days = {
    '1_week': 7,
    '1_month': 30,
    '6_months': 180,
    '1_year': 365,
  }[duration]!;
  final now = DateTime.now();
  return List.generate(days, (i) {
    final dt = now.subtract(Duration(days: days - 1 - i));
    return GraphData(
      dt,
      15 + rnd.nextDouble() * 10,
      50 + rnd.nextDouble() * 10,
    );
  });
}

// ────────────────────────────────────────────────────────────
//  1) WeatherNode model (add all six sensor fields)
// ────────────────────────────────────────────────────────────
class WeatherNode {
  final int id;
  final String name, location;

  // NEW: six live fields
  String temperature, humidity;
  String leafWetness, skyTemp, windDir, windSpeed;

  String status, lastUpdated;

  WeatherNode({
    required this.id,
    required this.name,
    required this.location,
    this.temperature = '--',
    this.humidity    = '--',
    this.leafWetness = '--',
    this.skyTemp     = '--',
    this.windDir     = '--',
    this.windSpeed   = '--',
    this.status      = 'Active',
    this.lastUpdated = '-',
  });
}


class NotificationData {
  final String title, message;
  NotificationData(this.title, this.message);
}

// ═══════════════════════════════════════════════════════════
//                    MOCK / HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════
class NotificationHelper {
  static final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
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
    final nodes = <int, WeatherNode>{
      1: WeatherNode(id: 1, name: 'Node 1', location: 'Field A'),
      2: WeatherNode(id: 2, name: 'Node 2', location: 'Field B', status: 'Inactive'),
      3: WeatherNode(id: 3, name: 'Node 3', location: 'Field C'),
      4: WeatherNode(id: 4, name: 'Node 4', location: 'Field D'),
    };
    // In your MaterialApp:
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Frost Detection',
      navigatorKey: NotificationHelper.navKey,
      initialRoute: '/login',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/historical':
            final dur = settings.arguments as String;
            return MaterialPageRoute(
              builder: (ctx) => HistoricalDataPage(
                durationLabel: dur,
                data: getMockData(dur),
                onBack: () => Navigator.pop(ctx),
              ),
            );
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
      routes: {
        '/login': (_) => const LoginPage(),
        '/main': (_) => WeatherPage(nodes: nodes),
        '/frost_prediction': (_) => const FrostPredictionPage(),
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
  bool showPwd = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff87CEEB),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text(
          'Welcome to\nFrost Detection',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, color: Colors.black),
        ),
        const SizedBox(height: 40),
        TextField(decoration: _fieldDeco('Email', Icons.email)),
        const SizedBox(height: 16),
        TextField(
          obscureText: !showPwd,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              onPressed: () => setState(() => showPwd = !showPwd),
              icon: Icon(showPwd ? Icons.visibility : Icons.visibility_off),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.black,
            minimumSize: const Size(double.infinity, 50),
          ),
          onPressed: () => Navigator.pushReplacementNamed(context, '/main'),
          child: const Text(
            'LOG IN',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        )
      ]),
    ),
  );

  InputDecoration _fieldDeco(String lbl, IconData icon) => InputDecoration(
    filled: true,
    fillColor: Colors.white,
    labelText: lbl,
    prefixIcon: Icon(icon),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
  );
}

// ═══════════════════════════════════════════════════════════
//                    WEATHER  (Home)  PAGE
// ═══════════════════════════════════════════════════════════
class WeatherPage extends StatefulWidget {
  final Map<int, WeatherNode> nodes;
  const WeatherPage({Key? key, required this.nodes}) : super(key: key);

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  final _ttn = TtnService();
  Timer? _timer;
  bool _showNodeDrop = false, _showHistDrop = false;

  @override
  void initState() {
    super.initState();
    _fetchNode1();
    _runFrostCheck(); // run once at startup
    _timer = Timer.periodic(
      const Duration(seconds: 30),
          (_) {
        _fetchNode1();
        _runFrostCheck(); // and every 30s
      },
    );
  }

  Future<void> _runFrostCheck() async {
    try {
      final history = await _ttn.fetchHistory(
        'smartvineyardnode',
        ['AT'],
        limit: 48,
      );
      final temps = history
          .map((e) => e['AT']?.toString())
          .where((s) => s != null)
          .map((s) => double.parse(s!) / 100)
          .toList();
      if (temps.length < 2) return;

      final n = temps.length;
      final xs = List<double>.generate(n, (i) => i.toDouble());
      final meanX = xs.reduce((a, b) => a + b) / n;
      final meanY = temps.reduce((a, b) => a + b) / n;
      final num = xs
          .asMap()
          .entries
          .map((e) => (e.value - meanX) * (temps[e.key] - meanY))
          .reduce((a, b) => a + b);
      final den = xs.map((x) => pow(x - meanX, 2)).reduce((a, b) => a + b);
      final m = num / den;
      final b = meanY - m * meanX;

      final preds = List<double>.generate(4, (i) => m * (n + i) + b);
      final willFrost = preds.any((t) => t <= 0);

      NotificationHelper.send(
        title: '4-Hour Frost Check',
        message: willFrost
            ? '⚠️ Frost expected in next 4 hours'
            : '✅ No frost expected',
      );
    } catch (e) {
      debugPrint('❌ Frost check failed: $e');
    }
  }

  Future<void> _fetchNode1() async {
    try {
      final data = await _ttn.latestUplink('smartvineyardnode', ['message']);
      final raw = data['message'] as String? ?? '';
      if (raw.isEmpty) return;

      final parsed = <String, String>{};
      for (var part in raw.split(',')) {
        final kv = part.split(':');
        if (kv.length == 2) parsed[kv[0]] = kv[1];
      }

      final n = widget.nodes[1]!;
      setState(() {
        if (parsed.containsKey('AT')) {
          n.temperature = '${double.parse(parsed['AT']!) / 100}°C';
        }
        if (parsed.containsKey('AH')) {
          n.humidity = '${double.parse(parsed['AH']!) / 100}%';
        }
        n.lastUpdated = TimeOfDay.now().format(context);
      });
    } catch (e) {
      debugPrint('WeatherPage fetch error: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const sky = Color(0xff87CEEB);
    final node1 = widget.nodes[1]!;

    return Scaffold(
      backgroundColor: sky,
      appBar: AppBar(
        backgroundColor: sky,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.location_on, color: Colors.white),
          onPressed: () => Navigator.pushNamed(context, '/node_location', arguments: 1),
        ),
        title: const Text('Kumeu Vineyard', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.info, color: Colors.white),
            onPressed: () => Navigator.pushNamed(context, '/node_notification', arguments: 1),
          ),
          IconButton(
            icon: const Icon(Icons.notifications, color: Colors.white),
            onPressed: () => Navigator.pushNamed(context, '/all_notifications'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _todaySummaryCard(node1),
            const SizedBox(height: 16),
            _dropdownButton('Node Location', _showNodeDrop, () => setState(() => _showNodeDrop = !_showNodeDrop)),
            if (_showNodeDrop) _nodeList(),
            const SizedBox(height: 16),
            _dropdownButton('Historical Data', _showHistDrop, () => setState(() => _showHistDrop = !_showHistDrop)),
            if (_showHistDrop) _historicalList(context),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, minimumSize: const Size.fromHeight(50)),
              onPressed: () => Navigator.pushNamed(context, '/frost_prediction'),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('Frost Prediction Model', style: TextStyle(fontSize: 16, color: Colors.white)),
                  Icon(Icons.chevron_right, color: Colors.white),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Card _todaySummaryCard(WeatherNode n) => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Text(_todayAsDDMMYYYY(), style: const TextStyle(fontSize: 18, color: Colors.grey)),
        const SizedBox(height: 8),
        Text(n.temperature, style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Status: ${n.status}', style: const TextStyle(fontSize: 18, color: Colors.grey)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Last: ${n.lastUpdated}', style: const TextStyle(color: Colors.grey)),
          Text('Hum: ${n.humidity}', style: const TextStyle(color: Colors.grey)),
        ]),
      ]),
    ),
  );

  Widget _dropdownButton(String title, bool open, VoidCallback onTap) => ElevatedButton(
    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, minimumSize: const Size.fromHeight(50)),
    onPressed: onTap,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(title, style: const TextStyle(fontSize: 16, color: Colors.white)), Icon(open ? Icons.arrow_drop_up : Icons.arrow_drop_down, color: Colors.white)],
    ),
  );

  Widget _nodeList() => Container(
    color: Colors.white,
    child: Column(
      children: widget.nodes.values
          .map((n) => ListTile(
        title: Text(n.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        subtitle: Text('${n.location} • ${n.status}'),
        onTap: () => Navigator.pushNamed(context, '/node_location', arguments: n.id),
      ))
          .toList(),
    ),
  );

  Widget _historicalList(BuildContext ctx) => Container(
    color: Colors.white,
    child: Column(
      children: {
        '1_week': '1 Week',
        '1_month': '1 Month',
        '6_months': '6 Months',
        '1_year': '1 Year'
      }
          .entries
          .map((e) => ListTile(
        title: Text(e.value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        onTap: () {
          Navigator.pop(ctx);
          Navigator.pushNamed(ctx, '/historical', arguments: e.key);
        },
      ))
          .toList(),
    ),
  );

  String _todayAsDDMMYYYY() => DateFormat('dd/MM/yyyy').format(DateTime.now());
}


// ═══════════════════════════════════════════════════════════
//                 ALL NODES  NOTIFICATION  PAGE
// ═══════════════════════════════════════════════════════════
class AllNotificationsPage extends StatelessWidget {
  final List<WeatherNode> nodes;
  final VoidCallback onBack;

  const AllNotificationsPage({
    Key? key,
    required this.nodes,
    required this.onBack,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Build "New" notification: current temperature of node 1
    final node1 = nodes.firstWhere((n) => n.id == 1);
    final newNotif = NotificationData(
      'Temperature Update',
      'Current temperature is ${node1.temperature}.',
    );

    // Example "Earlier" notifications
    final earlierNotifs = <NotificationData>[
      NotificationData('Humidity Update', 'Current humidity is ${node1.humidity}.'),
      NotificationData('Leaf Wetness', 'Leaf wetness reading: ${node1.leafWetness}%.'),
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
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('New', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
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
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('Earlier', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
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

class NodeNotificationPage extends StatelessWidget {
  final WeatherNode node;
  final VoidCallback onBack;

  const NodeNotificationPage({
    Key? key,
    required this.node,
    required this.onBack,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Single node notifications
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
// ────────────────────────────────────────────────────────────
//           NODE  LOCATION  PAGE
// ────────────────────────────────────────────────────────────
class NodeLocationPage extends StatefulWidget {
  final WeatherNode node;
  const NodeLocationPage({Key? key, required this.node}) : super(key: key);

  @override
  _NodeLocationPageState createState() => _NodeLocationPageState();
}

class _NodeLocationPageState extends State<NodeLocationPage> {
  final _ttn = TtnService();
  late Timer _timer;

  // our six sensor values
  Map<String, String> _vals = {
    'temperature': '--',
    'humidity':    '--',
    'leafWetness': '--',
    'skyTemp':     '--',
    'windDir':     '--',
    'windSpeed':   '--',
  };

  @override
  void initState() {
    super.initState();
    _refresh(); // fetch on load
    _timer = Timer.periodic(
      const Duration(seconds: 30),
          (_) => _refresh(),
    );
  }

  Future<void> _refresh() async {
    try {
      final data = await _ttn.latestUplink(
        'smartvineyardnode',
        ['message'],
      );
      final raw = data['message'] as String? ?? '';
      if (raw.isEmpty) return;

      final parsed = <String, String>{};
      for (var part in raw.split(',')) {
        final kv = part.split(':');
        if (kv.length == 2) parsed[kv[0]] = kv[1];
      }
      if (parsed.isEmpty) return;

      setState(() {
        // AT = ambient temperature, AH = ambient humidity
        if (parsed.containsKey('AT')) {
          _vals['temperature'] = '${double.parse(parsed['AT']!) / 100}°C';
        }
        if (parsed.containsKey('AH')) {
          _vals['humidity'] = '${double.parse(parsed['AH']!) / 100}%';
        }
      });
    } catch (e) {
      debugPrint('Location fetch error: $e');
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = <SensorInfo>[
      SensorInfo('Temperature', _vals['temperature']!, Icons.thermostat),
      SensorInfo('Humidity',    _vals['humidity']!,    Icons.water_drop),
      SensorInfo('Leaf Wetness',_vals['leafWetness']!, Icons.energy_savings_leaf),
      SensorInfo('Sky Temp',    _vals['skyTemp']!,     Icons.cloud),
      SensorInfo('Wind Dir',    _vals['windDir']!,     Icons.explore),
      SensorInfo('Wind Speed',  _vals['windSpeed']!,   Icons.air),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.node.name} Location'),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          childAspectRatio: 3/2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          children: items.map((info) => Card(
            elevation: 4,
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
                  Text(info.title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
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
//         HISTORICAL DATA  PAGE (with Chart)
// ═══════════════════════════════════════════════════════════
class HistoricalDataPage extends StatelessWidget {
  final String durationLabel;
  final List<GraphData> data;
  final VoidCallback onBack;

  const HistoricalDataPage({
    Key? key,
    required this.durationLabel,
    required this.data,
    required this.onBack,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Historical – ${durationLabel.replaceAll('_', ' ')}'),
      leading: BackButton(onPressed: onBack),
    ),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Expanded(child: _buildChart(context)),
        const SizedBox(height: 16),
        Expanded(child: _buildList()),
      ]),
    ),
  );

  Widget _buildChart(BuildContext context) {
    final spots = <FlSpot>[
      for (var i = 0; i < data.length; i++)
        FlSpot(i.toDouble(), data[i].temperature),
    ];
    final minY = data.map((d) => d.temperature).reduce(min) - 2;
    final maxY = data.map((d) => d.temperature).reduce(max) + 2;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (data.length - 1).toDouble(),
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          horizontalInterval: 2,
          verticalInterval: (data.length / 4).ceilToDouble(),
        ),
        borderData: FlBorderData(show: true),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (data.length / 4).ceilToDouble(),
              getTitlesWidget: (v, meta) {
                final idx = v.toInt().clamp(0, data.length - 1);
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    DateFormat('HH:mm').format(data[idx].timestamp),
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 2,
              getTitlesWidget: (v, meta) => SideTitleWidget(
                axisSide: meta.axisSide,
                child: Text('${v.toInt()}°C',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            dotData: FlDotData(show: true),
            barWidth: 3,
            color: Theme.of(context).colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildList() => ListView.builder(
    itemCount: data.length,
    itemBuilder: (_, i) {
      final d = data[i];
      return ListTile(
        title: Text(DateFormat('dd/MM/yyyy').format(d.timestamp)),
        subtitle: Text('Temp ${d.temperature.toStringAsFixed(1)}°C'),
      );
    },
  );
}

//--------------------------------------------------------
// FROST PREDICTION PAGE
//--------------------------------------------------------

class FrostPredictionPage extends StatelessWidget {
  const FrostPredictionPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final preds = <FlSpot>[
      FlSpot(0, 10),
      FlSpot(1, 9.5),
      FlSpot(2, 9),
      FlSpot(3, 8.5),
    ];
    final willFrost = preds.any((p) => p.y <= 0);
    final color = willFrost ? Colors.red : Colors.green;
    final icon = willFrost ? Icons.ac_unit : Icons.check_circle;

    return Scaffold(
      backgroundColor: const Color(0xff87CEEB),
      appBar: AppBar(
        backgroundColor: const Color(0xff87CEEB),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '4-Hour Frost Prediction',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        leading: BackButton(color: Colors.white),
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 32),
                  const SizedBox(width: 12),
                  Text(
                    willFrost ? '⚠️ Frost Expected' : '✅ No Frost Expected',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: color),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: 3,
                      minY: preds.map((p) => p.y).reduce(min) - 2,
                      maxY: preds.map((p) => p.y).reduce(max) + 2,
                      gridData: FlGridData(
                        show: true,
                        horizontalInterval: 2,
                        verticalInterval: 1,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(strokeWidth: 0.5, dashArray: [4, 4]),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 1,
                            getTitlesWidget: (value, meta) {
                              final time = now.add(Duration(hours: value.toInt()));
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  DateFormat('HH:mm').format(time),
                                  style: const TextStyle(fontSize: 10),
                                ),
                              );
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 2,
                            reservedSize: 32,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                '${value.toInt()}°C',
                                style: const TextStyle(fontSize: 10),
                              );
                            },
                          ),
                        ),
                        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: preds,
                          isCurved: true,
                          barWidth: 3,
                          dotData: FlDotData(show: true),
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xff87CEEB),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                side: BorderSide(color: const Color(0xff87CEEB)),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Re-run Prediction'),
              onPressed: () {
                // TODO: trigger fresh prediction
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
