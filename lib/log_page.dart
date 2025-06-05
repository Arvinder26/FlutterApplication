import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'data_storage_service.dart';

/// Displays the last 24 uplink entries stored via DataStorageService.
class LogPage extends StatefulWidget {
  const LogPage({Key? key}) : super(key: key);

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final DataStorageService _storage = DataStorageService();
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final all = await _storage.readAll();
    // Keep only the most recent 24 entries
    final recent = all.length <= 24 ? all : all.sublist(all.length - 24);
    // Sort newest first
    recent.sort((a, b) {
      final ta = DateTime.parse(a['timestamp'] as String);
      final tb = DateTime.parse(b['timestamp'] as String);
      return tb.compareTo(ta);
    });
    setState(() => _entries = recent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('24-Hour Uplink Log')),
      body: _entries.isEmpty
          ? const Center(child: Text('No log entries yet.'))
          : ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (ctx, i) {
          final e = _entries[i];
          final tsUtc = DateTime.parse(e['timestamp'] as String);
          final tsLocal = tsUtc.toLocal();
          final timeLabel = DateFormat('dd/MM/yyyy HH:mm').format(tsLocal);
          final dataMap = Map<String, dynamic>.from(e['data'] as Map);

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: ExpansionTile(
              title: Text(timeLabel, style: const TextStyle(fontSize: 14)),
              children: dataMap.entries.map((kv) {
                return ListTile(
                  dense: true,
                  title: Text(
                    '${kv.key}: ${kv.value}',
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}
