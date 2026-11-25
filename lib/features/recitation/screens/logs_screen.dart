// Session logs: list, summarize, export (local file only — no upload).

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../event_log.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<File> _files = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final files = await EventLog.listLogs();
    if (mounted) setState(() => _files = files);
  }

  Future<String> _summary(File f) async {
    final events = await EventLog.read(f);
    var positions = 0;
    var confirmed = 0;
    var uncertain = 0;
    var resolved = 0;
    for (final e in events) {
      if (e['type'] == 'position') positions++;
      if (e['type'] == 'checker') {
        switch (e['payload']?['state']) {
          case 'confirmed':
            confirmed++;
          case 'uncertain':
            uncertain++;
          case 'resolved':
            resolved++;
        }
      }
    }
    final lat = LogMetrics.highlightLatenciesMs(events);
    final med = lat.isEmpty
        ? '—'
        : '${LogMetrics.median(lat).toStringAsFixed(0)}ms';
    return '$positions موضع • $confirmed خطأ مؤكد • $uncertain غير متأكد • '
        '$resolved تصحيح ذاتي • وسيط التظليل $med';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: _files.isEmpty
            ? const EmptyState(
                icon: Icons.history,
                text: 'لا سجلات بعد — نفّذ جلسة تسميع أولاً.',
              )
            : ListView.builder(
                padding: const EdgeInsets.all(spacePage),
                itemCount: _files.length,
                itemBuilder: (context, i) {
                  final f = _files[i];
                  final name = f.path.split('/').last;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: spaceSection),
                    child: TilawaCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: FutureBuilder<String>(
                        future: _summary(f),
                        builder: (context, snap) => ListTile(
                          title: Text(name),
                          subtitle: Text(
                            snap.data ?? '…',
                            style: const TextStyle(color: muted),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.share),
                            tooltip: 'تصدير (ملف محلي فقط)',
                            onPressed: () =>
                                Share.shareXFiles([XFile(f.path)]),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
