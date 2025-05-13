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

        // LW = leaf wetness → percentage
        if (parsed.containsKey('LW')) {
          _vals['leafWetness'] =
              '${(double.parse(parsed['LW']!) / 100).toStringAsFixed(1)}%';
        }

        // IC = infrared (sky) temp → reading × 10
        if (parsed.containsKey('IC')) {
          final skyRaw = double.parse(parsed['IC']!);
          _vals['skyTemp'] = '${(skyRaw / 10).toStringAsFixed(1)}°C';
        }

        // WD = wind direction → degrees
        if (parsed.containsKey('WD')) {
          final dir = int.parse(parsed['WD']!);
          _vals['windDir'] = '$dir°';
        }

        // WS = wind speed (as before)
        if (parsed.containsKey('WS')) {
          _vals['windSpeed'] =
              '${(double.parse(parsed['WS']!) / 100).toStringAsFixed(1)} m/s';
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
