import 'dart:convert';
import 'package:http/http.dart' as http;

class HourlyData {
  final DateTime timestamp;
  final double? airTempC, leafTempC, leafWetnessPct;
  HourlyData({
    required this.timestamp,
    this.airTempC,
    this.leafTempC,
    this.leafWetnessPct,
  });
  factory HourlyData.fromJson(Map<String, dynamic> j) => HourlyData(
    timestamp: DateTime.parse(j['DateTime'] as String),
    airTempC:       (j['Air Temp (°C)']    as num?)?.toDouble(),
    leafTempC:      (j['Leaf Temp (°C)']   as num?)?.toDouble(),
    leafWetnessPct: (j['Leaf Wetness (%)'] as num?)?.toDouble(),
  );
}

class HortplusService {
  static const _baseUrl = 'https://api.metwatch.nz/api/legacy/historic/hourly';
  Future<List<HourlyData>> fetchHourlyJson({
    required String station,
    required DateTime start,
    required DateTime stop,
  }) async {
    String two(int n) => n.toString().padLeft(2,'0');
    String ymd(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
    String hm (DateTime d) => '${two(d.hour)}:${two(d.minute)}';
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'station': station,
      'start':   '${ymd(start)} ${hm(start)}:00',
      'stop':    '${ymd(stop)}  ${hm(stop)}:00',
      'sr_type': 'nz_utc',
      'highcharts_format':'true',
    });
    final res = await http.get(uri, headers:{'Accept':'application/json'});
    if (res.statusCode != 200) throw Exception('Hortplus ${res.statusCode}');
    final body = jsonDecode(res.body) as Map<String,dynamic>;
    final rows = body['data'] as List<dynamic>? ?? [];
    return rows.map((e)=>HourlyData.fromJson(e as Map<String,dynamic>)).toList();
  }
}
