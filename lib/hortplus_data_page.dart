import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'hortplus_service.dart';

class HortplusDataPage extends StatelessWidget {
  final List<HourlyData> data;
  const HortplusDataPage({ Key? key, required this.data }) : super(key: key);

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('HortPlus Historical')),
    body: ListView.builder(
      itemCount: data.length,
      itemBuilder: (_, i) {
        final d = data[i];
        return ListTile(
          title: Text(DateFormat('dd/MM/yyyy HH:mm').format(d.timestamp)),
          subtitle: Text(
            'Air Temp:  ${d.airTempC?.toStringAsFixed(1)}°C\n'
                'Leaf Temp: ${d.leafTempC?.toStringAsFixed(1)}°C\n'
                'Leaf Wet:  ${d.leafWetnessPct?.toStringAsFixed(0)}%',
          ),
        );
      },
    ),
  );
}
