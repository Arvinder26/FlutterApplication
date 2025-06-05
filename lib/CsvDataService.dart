// lib/services/csv_data_service.dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:csv/csv.dart';
import '../main.dart'; // or wherever GraphData is defined

class CsvDataService {
  /// Loads the six-month daily averages from assets.
  static Future<List<GraphData>> loadSixMonthDailyAverages() async {
    final raw = await rootBundle.loadString('assets/data/daily_avg_6m.csv');
    final rows = const CsvToListConverter().convert(raw, eol: '\n');
    final header = rows.first.cast<String>();
    final dateIdx       = header.indexOf('Date');
    final tempIdx       = header.indexOf('AvgTemp');
    final humIdx        = header.indexOf('AvgHumidity');
    final lwIdx         = header.indexOf('AvgLeafWetness');
    // if you had AvgLeafTemp in the CSV, index it here
    return rows
        .skip(1)
        .map((r) {
      final date = DateTime.parse(r[dateIdx] as String);
      return GraphData(
        date,
        (r[tempIdx]        as num).toDouble(),
        (r[humIdx]         as num).toDouble(),
        (r[lwIdx]          as num).toDouble(),
        // if you want leafTemp add it as a fifth field
        0.0,
      );
    })
        .toList();
  }
}
