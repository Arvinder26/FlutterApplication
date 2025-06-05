// data_storage_service.dart

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class DataStorageService {
  static const _key = 'uplink_log';

  Future<List<Map<String, dynamic>>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_key);
    if (raw == null) return [];
    return List<Map<String,dynamic>>.from(jsonDecode(raw));
  }

  Future<void> append(Map<String, dynamic> entry) async {
    final prefs = await SharedPreferences.getInstance();
    final list  = await readAll();
    list.add(entry);
    await prefs.setString(_key, jsonEncode(list));
  }
}
