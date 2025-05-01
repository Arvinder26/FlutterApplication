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


// ═══════════════════════════════════════════════════════════
//                ThingsBoard  CONFIG & SERVICE
// ═══════════════════════════════════════════════════════════
const String kTbUrl      = 'http://10.62.135.216:8080';   // YOUR server
const String kNode1Token = '4tgo7mm33ujhokbhabi2';        // Device‑token

class ThingsboardService {
  Future<Map<String, dynamic>> latestTelemetry(
      String token, List<String> keys) async {
    final uri = Uri.parse('$kTbUrl/api/v1/$token/telemetry?keys=${keys.join(',')}');
    final res = await http.get(uri);
    if (res.statusCode != 200) return {};
    final raw = jsonDecode(res.body) as Map<String, dynamic>;
    final out = <String, dynamic>{};
    for (final k in keys) {
      final arr = raw[k];
      if (arr is List && arr.isNotEmpty) out[k] = arr.last['value'];
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
    '1_week':   7,
    '1_month': 30,
    '6_months': 180,
    '1_year':  365,
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



class WeatherNode {
  final int id;
  final String name, location;
  String temperature, humidity, status, lastUpdated;
  WeatherNode({
    required this.id,
    required this.name,
    required this.location,
    this.temperature = '--',
    this.humidity = '--',
    this.status = 'Active',
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
  static void send({
    required String title,
    required String message,
    int id = 0,
  }) {
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

// ═══════════════════════════════════════════════════════════
//                           MAIN APP
// ═══════════════════════════════════════════════════════════
void main() => runApp(const FrostApp());

class FrostApp extends StatelessWidget {
  const FrostApp({super.key});

  @override
  Widget build(BuildContext context) {
    final nodes = <int, WeatherNode>{
      1: WeatherNode(id: 1, name: 'Node 1', location: 'Field A'),
      2: WeatherNode(id: 2, name: 'Node 2', location: 'Field B', status: 'Inactive'),
      3: WeatherNode(id: 3, name: 'Node 3', location: 'Field C'),
      4: WeatherNode(id: 4, name: 'Node 4', location: 'Field D'),
    };

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Frost Detection',
      navigatorKey: NotificationHelper.navKey,
      initialRoute: '/login',
      onGenerateRoute: (settings) {
        // Historical
        if (settings.name == '/historical') {
          final dur = settings.arguments as String;
          return MaterialPageRoute(
            builder: (ctx) => HistoricalDataPage(
              durationLabel: dur,
              data:          getMockData(dur),
              onBack:        () => Navigator.pop(ctx),
            ),
          );
        }
        // All Notifications
        if (settings.name == '/all_notifications') {
          return MaterialPageRoute(
            builder: (ctx) => AllNotificationsPage(
              nodes:  nodes.values.toList(),
              onBack: () => Navigator.pop(ctx),
            ),
          );
        }
        // Node Notification
        if (settings.name == '/node_notification') {
          final id = settings.arguments as int;
          return MaterialPageRoute(
            builder: (ctx) => NodeNotificationPage(
              node:   nodes[id]!,
              onBack: () => Navigator.pop(ctx),
            ),
          );
        }
        // Node Location
        if (settings.name == '/node_location') {
          final id = settings.arguments as int;
          final node = nodes[id]!;
          final sensors = {
            'temperature': node.temperature,
            'humidity':    node.humidity,
            'rainfall':    '--',
            'leafWetness': '--',
            'windSpeed':   '--',
            'irTemp':      '--',
          };
          return MaterialPageRoute(
            builder: (ctx) => NodeLocationPage(
              node:    node,
              sensors: sensors,
            ),
          );
        }
        return null;
      },
      routes: {
        '/login': (_) => const LoginPage(),
        '/main':  (_) => WeatherPage(nodes: nodes),
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
//                        LOGIN PAGE
// ═══════════════════════════════════════════════════════════
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
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
            filled: true, fillColor: Colors.white,
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              onPressed: () => setState(() => showPwd = !showPwd),
              icon:       Icon(showPwd ? Icons.visibility : Icons.visibility_off),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 50)),
          onPressed: () => Navigator.pushReplacementNamed(context, '/main'),
          child: const Text('LOG IN',
              style: TextStyle(color: Colors.white, fontSize: 16)),
        )
      ]),
    ),
  );

  InputDecoration _fieldDeco(String lbl, IconData icon) => InputDecoration(
    filled: true, fillColor: Colors.white,
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
  _WeatherPageState createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  bool _showNodeDrop = false, _showHistDrop = false;
  final _tb       = ThingsboardService();
  final _poll     = Timer.periodic;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _updateNode1());
  }

  Future<void> _updateNode1() async {
    final data = await _tb.latestTelemetry(
      kNode1Token,
      ['temperature', 'humidity'],
    );
    if (data.isEmpty) return;
    setState(() {
      final n = widget.nodes[1]!;
      n.temperature =
      data['temperature'] != null ? '${data['temperature']}°C' : '--';
      n.humidity =
      data['humidity'] != null ? '${data['humidity']}%' : '--';
      n.lastUpdated = TimeOfDay.now().format(context);
    });
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
          onPressed: () {
            Navigator.pushNamed(context, '/node_location', arguments: 1);
          },
        ),
        title: const Text('Kumeu Vineyard',
            style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.info, color: Colors.white),
            onPressed: () {
              Navigator.pushNamed(context, '/node_notification',
                  arguments: 1);
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications, color: Colors.white),
            onPressed: () {
              Navigator.pushNamed(context, '/all_notifications');
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          _todayCard(node1),
          const SizedBox(height: 16),
          _dropdownButton(
            title: 'Node Location',
            expanded: _showNodeDrop,
            onTap: () => setState(() => _showNodeDrop = !_showNodeDrop),
          ),
          if (_showNodeDrop) _nodeList(),
          const SizedBox(height: 16),
          _dropdownButton(
            title: 'Historical Data',
            expanded: _showHistDrop,
            onTap: () => setState(() => _showHistDrop = !_showHistDrop),
          ),
          if (_showHistDrop) _historicalList(context),
        ]),
      ),
    );
  }

  Widget _dropdownButton({
    required String title,
    required bool expanded,
    required VoidCallback onTap,
  }) =>
      ElevatedButton(
        style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue,
            minimumSize: const Size(double.infinity, 50)),
        onPressed: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title,
                style:
                const TextStyle(fontSize: 16, color: Colors.white)),
            Icon(
                expanded
                    ? Icons.arrow_drop_up
                    : Icons.arrow_drop_down,
                color: Colors.white),
          ],
        ),
      );

  Card _todayCard(WeatherNode node) => Card(
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            _todayAsDDMMYYYY(),
            style:
            const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            node.temperature,
            style: const TextStyle(
                fontSize: 48, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Status: ${node.status}',
            style:
            const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Last updated: ${node.lastUpdated}',
                style: const TextStyle(color: Colors.grey),
              ),
              Text(
                'Hum: ${node.humidity}',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _nodeList() => Container(
    color: Colors.white,
    child: Column(
      children: widget.nodes.values
          .map((n) => ListTile(
        title: Text(n.name,
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18)),
        subtitle:
        Text('${n.location}  •  ${n.status}'),
        onTap: () {
          setState(() => _showNodeDrop = false);
          Navigator.pushNamed(context, '/node_location',
              arguments: n.id);
        },
      ))
          .toList(),
    ),
  );

  Widget _historicalList(BuildContext ctx) => Container(
    color: Colors.white,
    child: Column(
      children: {
        '1_week': '1 Week',
        '1_month': '1 Month',
        '6_months': '6 Months',
        '1_year': '1 Year'
      }
          .entries
          .map((e) => ListTile(
        title: Text(e.value,
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18)),
        onTap: () {
          setState(() => _showHistDrop = false);
          Navigator.pushNamed(ctx, '/historical',
              arguments: e.key);
        },
      ))
          .toList(),
    ),
  );

  String _todayAsDDMMYYYY() {
    // Use intl to format with slashes
    return DateFormat('dd/MM/yyyy').format(DateTime.now());
  }

}

// ═══════════════════════════════════════════════════════════
//                 ALL NODES  NOTIFICATION  PAGE
// ═══════════════════════════════════════════════════════════
class AllNotificationsPage extends StatelessWidget {
  final List<WeatherNode> nodes;
  final VoidCallback onBack;
  AllNotificationsPage({super.key, required this.nodes, required this.onBack});

  final _notifs = <NotificationData>[
    NotificationData('Low Battery', 'Node 1 reported battery below 20%.'),
    NotificationData('Frost Warning', 'Node 2 temp dropped below 3 °C.'),
    NotificationData('Link Restored','Node 3 connection restored.'),
    NotificationData('Sensor Offline','Node 4 humidity sensor inactive.'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('All Nodes Notifications'),
      leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
    ),
    body: ListView.builder(
      itemCount: _notifs.length,
      itemBuilder: (_, i) => ListTile(
        leading: const Icon(Icons.notifications),
        title: Text(_notifs[i].title),
        subtitle: Text(_notifs[i].message),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════
//             NODE  NOTIFICATION  PAGE
// ═══════════════════════════════════════════════════════════
class NodeNotificationPage extends StatelessWidget {
  final WeatherNode node;
  final VoidCallback onBack;
  NodeNotificationPage({
    super.key,
    required this.node,
    required this.onBack,
  });

  final _notifs = <NotificationData>[
    NotificationData('Low Battery','Node reported battery below 20%.'),
    NotificationData('Frost Warning','Temperature dropped below 3 °C.'),
    NotificationData('Link Restored','Connection to gateway restored.'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${node.name} Notifications'),
      leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
    ),
    body: ListView.builder(
      itemCount: _notifs.length,
      itemBuilder: (_, i) => ListTile(
        leading: const Icon(Icons.notifications),
        title: Text(_notifs[i].title),
        subtitle: Text(_notifs[i].message),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════
//           NODE  LOCATION  PAGE
// ═══════════════════════════════════════════════════════════
class NodeLocationPage extends StatelessWidget {
  final WeatherNode node;
  final Map<String, dynamic> sensors;

  const NodeLocationPage({
    super.key,
    required this.node,
    required this.sensors,
  });

  @override
  Widget build(BuildContext context) {
    final items = <_SensorInfo>[
      _SensorInfo('Temperature', sensors['temperature'], Icons.thermostat),
      _SensorInfo('Humidity',    sensors['humidity'],    Icons.water_drop),
      _SensorInfo('Rainfall',    sensors['rainfall'],    Icons.grain),
      _SensorInfo('Leaf Wetness',sensors['leafWetness'], Icons.energy_savings_leaf),
      _SensorInfo('Wind Speed',  sensors['windSpeed'],   Icons.air),
      _SensorInfo('IR Temp',     sensors['irTemp'],      Icons.wb_sunny),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${node.name} Location'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications),
            onPressed: () {
              Navigator.pushNamed(context, '/node_notification', arguments: node.id);
            },
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          childAspectRatio: 3 / 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          children: items.map((info) {
            return _buildSensorCard(info.title, info.value, info.icon);
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildSensorCard(String title, dynamic value, IconData icon) {
    final display = value != null ? value.toString() : '—';
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: Colors.blueAccent),
            const SizedBox(height: 8),
            Text(title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(display, style: const TextStyle(fontSize: 20)),
          ],
        ),
      ),
    );
  }
}

class _SensorInfo {
  final String title;
  final dynamic value;
  final IconData icon;
  _SensorInfo(this.title, this.value, this.icon);
}

// ═══════════════════════════════════════════════════════════
//         HISTORICAL DATA  PAGE (with Chart)
// ═══════════════════════════════════════════════════════════
class HistoricalDataPage extends StatelessWidget {
  final String durationLabel;
  final List<GraphData> data;
  final VoidCallback onBack;

  const HistoricalDataPage({
    required this.durationLabel,
    required this.data,
    required this.onBack,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Historical – ${durationLabel.replaceAll('_', ' ')}'),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: onBack,
      ),
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
    final tempSpots = <FlSpot>[];
    final humSpots  = <FlSpot>[];
    for (var i = 0; i < data.length; i++) {
      tempSpots.add(FlSpot(i.toDouble(), data[i].temperature));
      humSpots.add(FlSpot(i.toDouble(), data[i].humidity));
    }

    return LineChart(LineChartData(
      lineTouchData: LineTouchData(enabled: true),
      gridData:     FlGridData(show: true),
      titlesData:   FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles:     true,
            reservedSize:   28,
            interval:       (data.length / 5).ceilToDouble(),
            getTitlesWidget: (double value, TitleMeta meta) {
              // figure out which data point this 'value' corresponds to
              final idx = value.toInt().clamp(0, data.length - 1);
              final dt  = data[idx].timestamp;
              final txt = DateFormat('dd/MM/yyyy').format(dt);

              return SideTitleWidget(
                axisSide: meta.axisSide,
                child: Text(txt, style: const TextStyle(fontSize: 10)),
              );
            },

          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, interval: 5),
        ),
      ),
      minX: 0,
      maxX: (data.length - 1).toDouble(),
      minY: [
        ...data.map((d) => d.temperature),
        ...data.map((d) => d.humidity)
      ].reduce(min) - 5,
      maxY: [
        ...data.map((d) => d.temperature),
        ...data.map((d) => d.humidity)
      ].reduce(max) + 5,
      lineBarsData: [
        LineChartBarData(
          spots:    tempSpots,
          isCurved: true,
          barWidth: 2,
          color:    Colors.red,
          dotData:  FlDotData(show: false),
        ),
        LineChartBarData(
          spots:    humSpots,
          isCurved: true,
          barWidth: 2,
          color:    Colors.blue,
          dotData:  FlDotData(show: false),
        ),
      ],
      clipData: FlClipData.all(),
    ));
  }

  Widget _buildList() => ListView.builder(
    itemCount: data.length,
    itemBuilder: (_, i) {
      final d = data[i];

      final formattedDate = DateFormat('dd/MM/yyyy').format(d.timestamp);
      return ListTile(
        title: Text(formattedDate),
        subtitle: Text(
            'Temp ${d.temperature.toStringAsFixed(1)}°C  –  '
                'Hum ${d.humidity.toStringAsFixed(1)}%'),
      );
    },
  );
}
