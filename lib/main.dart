import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DiskWiseApp());
}

const _background = Color(0xFF09111E);
const _surface = Color(0xFF142235);
const _surfaceLight = Color(0xFF1B2D42);
const _accent = Color(0xFFA6F48D);
const _textMuted = Color(0xFF9DADC3);
const _white = Color(0xFFF2F7FF);


class DiskWiseApp extends StatelessWidget {
  const DiskWiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DiskWise Mobile',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          surface: _surface,
          onSurface: _white,
          secondary: Color(0xFF82C5FF),
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.w800, color: _white, letterSpacing: -0.9),
          headlineSmall: TextStyle(fontWeight: FontWeight.w800, color: _white),
          titleLarge: TextStyle(fontWeight: FontWeight.w700, color: _white),
          titleMedium: TextStyle(fontWeight: FontWeight.w700, color: _white),
          bodyMedium: TextStyle(color: _white),
        ),
        cardTheme: CardThemeData(
          color: _surface,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: _background,
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        )),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: _surface,
          indicatorColor: _surfaceLight,
          labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11, color: _white)),
        ),
      ),
      home: const DiskWiseHome(),
    );
  }
}

class DiskWiseHome extends StatefulWidget {
  const DiskWiseHome({super.key});

  @override
  State<DiskWiseHome> createState() => _DiskWiseHomeState();
}

class _DiskWiseHomeState extends State<DiskWiseHome> with WidgetsBindingObserver {
  static const _engine = MethodChannel('diskwise/engine');
  static const _events = EventChannel('diskwise/events');
  StreamSubscription<dynamic>? _subscription;
  int _tab = 0;
  bool _granted = false;
  bool _busy = false;
  bool _hasReport = false;
  String _phase = 'Ready to analyze your phone';
  int _indexed = 0;
  int _days = 180;
  int _largeMB = 100;
  String _selectedRoot = 'all';
  Map<String, dynamic> _summary = {};
  List<Map<String, dynamic>> _roots = [];
  final Map<String, List<Map<String, dynamic>>> _pages = {};
  final Map<String, int> _totals = {};
  final Set<String> _selectedPaths = {};
  String _insightKind = 'folders';
  final Set<String> _fetchingKinds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _events.receiveBroadcastStream().listen(_handleEvent, onError: (Object error) {
      _notify('Engine event issue: $error');
      if (mounted) setState(() => _busy = false);
    });
    _refreshStorage();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStorage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshStorage() async {
    try {
      final permission = await _engine.invokeMethod<bool>('permissionStatus') ?? false;
      final roots = (await _engine.invokeListMethod<dynamic>('listRoots') ?? [])
          .map(asMap).toList();
      if (!mounted) return;
      setState(() {
        _granted = permission;
        _roots = roots;
        if (_selectedRoot != 'all' && !_roots.any((r) => r['id'] == _selectedRoot)) _selectedRoot = 'all';
      });
    } on PlatformException catch (e) { _notify(e.message ?? 'Could not access storage'); }
  }

  void _handleEvent(dynamic raw) {
    if (!mounted) return;
    final event = asMap(raw);
    switch (string(event['event'])) {
      case 'progress':
        setState(() {
          _phase = string(event['phase']);
          _indexed = number(event['count']);
        });
        break;
      case 'complete':
        setState(() {
          _busy = false;
          _hasReport = true;
          _summary = asMap(event['summary']);
          _phase = 'Analysis complete';
          _selectedPaths.clear();
          _pages.clear();
          _totals.clear();
        });
        _loadPage('duplicates');
        _loadPage('folders');
        break;
      case 'cancelled':
        setState(() { _busy = false; _phase = 'Scan cancelled'; });
        break;
      case 'deleted':
        setState(() {
          _busy = false;
          _hasReport = false;
          _selectedPaths.clear();
          _summary = {};
          _pages.clear();
          _phase = 'Deletion finished — scan again';
        });
        _refreshStorage();
        _notify('Deleted ${event['count']} duplicates (${prettyBytes(number(event['bytes']))}); ${event['failed']} skipped. Rescan required.');
        break;
      case 'error':
        setState(() { _busy = false; _phase = 'Operation failed'; });
        _notify(string(event['message']));
        break;
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: _surfaceLight,
      duration: const Duration(seconds: 5),
    ));
  }

  Future<void> _grantAccess() async {
    try {
      await _engine.invokeMethod('requestPermission');
    } on PlatformException catch (e) { _notify(e.message ?? 'Unable to open permission settings'); }
  }

  Future<void> _scan() async {
    if (!_granted) { await _grantAccess(); return; }
    if (_busy) return;
    setState(() {
      _busy = true;
      _hasReport = false;
      _summary.clear();
      _selectedPaths.clear();
      _pages.clear();
      _totals.clear();
      _indexed = 0;
      _phase = 'Preparing native scanner';
    });
    try {
      await _engine.invokeMethod('scan', {
        'root': _selectedRoot,
        'days': _days,
        'largeMB': _largeMB,
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _busy = false);
      _notify(e.message ?? 'Failed to start scan');
    }
  }

  Future<void> _cancel() async {
    try { await _engine.invokeMethod('cancelScan'); }
    on PlatformException catch (e) { _notify(e.message ?? 'Unable to cancel'); }
  }

  Future<void> _loadPage(String kind) async {
    if (!_hasReport || _fetchingKinds.contains(kind)) return;
    _fetchingKinds.add(kind);
    try {
      final offset = _pages[kind]?.length ?? 0;
      final result = asMap(await _engine.invokeMethod('getPage', {
        'kind': kind,
        'offset': offset,
        'limit': 40,
      }));
      final newItems = (result['items'] as List).map(asMap).toList();
      if (mounted) setState(() {
        _pages.putIfAbsent(kind, () => []).addAll(newItems);
        _totals[kind] = number(result['count']);
      });
    } on PlatformException catch (e) { _notify(e.message ?? 'Could not load results'); }
    finally { _fetchingKinds.remove(kind); }
  }

  Future<void> _deleteDuplicates() async {
    if (_selectedPaths.isEmpty || _busy) return;
    final count = _selectedPaths.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _surfaceLight,
        title: const Text('Permanently delete files?'),
        content: Text('$count selected duplicate files will be permanently deleted. This is NOT the Recycle Bin and cannot be undone. The engine verifies an identical unselected copy is still available before each deletion. Back up irreplaceable data.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete permanently')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() { _busy = true; _phase = 'Verifying safe keepers before deletion'; });
    try {
      await _engine.invokeMethod('deleteSelected', {'paths': _selectedPaths.toList()});
    } on PlatformException catch (e) {
      if (mounted) setState(() => _busy = false);
      _notify(e.message ?? 'Deletion failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
            child: Row(children: [
              Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(
                color: _accent, borderRadius: BorderRadius.circular(14),
              ), child: const Icon(Icons.bolt_rounded, color: _background, size: 22)),
              const SizedBox(width: 11),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('DiskWise', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: -0.9)),
                Text('POCKET  /  STORAGE INTELLIGENCE', style: TextStyle(color: _textMuted, fontSize: 10, letterSpacing: 1.2)),
              ])),
              Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(
                color: _surface, borderRadius: BorderRadius.circular(20),
              ), child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.shield_outlined, color: _accent, size: 15),
                const SizedBox(width: 5),
                Text(_granted ? 'LOCAL' : 'LOCKED', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
              ])),
            ]),
          ),
          Expanded(child: IndexedStack(index: _tab, children: [
            _dashboard(), _duplicates(), _insights(), _settings(),
          ])),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        height: 72,
        selectedIndex: _tab,
        onDestinationSelected: (value) {
          setState(() => _tab = value);
          if (value == 1 && _hasReport && !_pages.containsKey('duplicates')) _loadPage('duplicates');
          if (value == 2 && _hasReport && !_pages.containsKey(_insightKind)) _loadPage(_insightKind);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.space_dashboard_outlined), selectedIcon: Icon(Icons.space_dashboard), label: 'Overview'),
          NavigationDestination(icon: Icon(Icons.content_copy_outlined), selectedIcon: Icon(Icons.content_copy), label: 'Duplicates'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Insights'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Controls'),
        ],
      ),
    );
  }

  Widget _dashboard() => ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 26), children: [
    const Text('A clearer phone.', style: TextStyle(fontSize: 33, fontWeight: FontWeight.w900, letterSpacing: -1.4)),
    const Text('No guesses. No automatic deletion.', style: TextStyle(fontSize: 14, color: _textMuted)),
    const SizedBox(height: 19),
    _storageCard(),
    const SizedBox(height: 14),
    if (!_granted) _permissionCard(),
    _sectionHeader('Scan configuration', 'Choose exactly where to look'),
    _tile(children: [
      const Text('STORAGE SCOPE', style: TextStyle(fontSize: 10, letterSpacing: 1.2, color: _textMuted)),
      const SizedBox(height: 5),
      DropdownButtonFormField<String>(
        key: ValueKey('root-$_selectedRoot-${_roots.length}'),
        initialValue: _selectedRoot,
        dropdownColor: _surfaceLight,
        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
        items: [
          const DropdownMenuItem(value: 'all', child: Text('All available storage')),
          ..._roots.map((r) => DropdownMenuItem(value: string(r['id']), child: Text(string(r['label']), overflow: TextOverflow.ellipsis))),
        ],
        onChanged: _busy ? null : (v) => setState(() => _selectedRoot = v ?? 'all'),
      ),
      const Divider(height: 22),
      Row(children: [
        Expanded(child: _settingSelector('Unused after', '$_days days', () => _showDaysPicker())),
        const SizedBox(width: 10),
        Expanded(child: _settingSelector('Large files', '${_largeMB} MB+', () => _showLargePicker())),
      ]),
    ]),
    const SizedBox(height: 15),
    if (_busy) ...[
      _tile(children: [
        Row(children: [const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12), Expanded(child: Text(_phase, overflow: TextOverflow.ellipsis))]),
        const SizedBox(height: 12),
        LinearProgressIndicator(color: _accent, backgroundColor: _surfaceLight, minHeight: 4),
        const SizedBox(height: 8),
        Text('$_indexed files indexed • running off the UI thread', style: const TextStyle(fontSize: 12, color: _textMuted)),
        TextButton.icon(onPressed: _cancel, icon: const Icon(Icons.close_rounded), label: const Text('Stop scan')),
      ]),
    ] else FilledButton.icon(onPressed: _scan, icon: const Icon(Icons.radar), label: Text(_granted ? 'Start smart analysis' : 'Grant storage access')),
    if (_hasReport) ...[
      const SizedBox(height: 9),
      _sectionHeader('Scan results', 'Review before removing anything'),
      Row(children: [
        Expanded(child: _metricCard('Files checked', '${_summary['filesChecked'] ?? 0}', Icons.folder_open)),
        const SizedBox(width: 9),
        Expanded(child: _metricCard('Duplicate space', prettyBytes(number(_summary['duplicateBytes'])), Icons.content_copy)),
      ]),
      const SizedBox(height: 9),
      Row(children: [
        Expanded(child: _metricCard('Unused candidates', '${_summary['unusedFiles'] ?? 0}', Icons.history)),
        const SizedBox(width: 9),
        Expanded(child: _metricCard('Duplicate groups', '${_summary['duplicateGroups'] ?? 0}', Icons.layers_outlined)),
      ]),
      if (_summary['truncated'] == true) const Padding(padding: EdgeInsets.only(top: 12), child:
        Text('⚠ File indexing cap reached (250,000 files). Results are partial; scan a smaller volume for completeness.', style: TextStyle(color: Color(0xFFFFD18C)))),
      if (number(_summary['inaccessible']) > 0) Padding(padding: const EdgeInsets.only(top: 10),
        child: Text('${_summary['inaccessible']} inaccessible items skipped by Android permissions.', style: const TextStyle(color: _textMuted))),
    ],
    const SizedBox(height: 15),
    const Text('PRIVATE BY DESIGN  ·  OFFLINE ENGINE  ·  NO TELEMETRY', textAlign: TextAlign.center,
        style: TextStyle(color: _textMuted, fontSize: 10, letterSpacing: 0.7)),
  ]);

  Widget _storageCard() {
    final total = _roots.fold<int>(0, (sum, r) => sum + number(r['total']));
    final free = _roots.fold<int>(0, (sum, r) => sum + number(r['free']));
    final usedFraction = total > 0 ? (total - free) / total : 0.0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1D3643), Color(0xFF162239)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0xFF36565B)),
      ),
      child: Row(children: [
        SizedBox(width: 110, height: 110, child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(child: CircularProgressIndicator(value: usedFraction, strokeWidth: 11,
              backgroundColor: const Color(0xFF355268), color: _accent, strokeCap: StrokeCap.round)),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${(usedFraction * 100).round()}%', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            const Text('USED', style: TextStyle(color: _textMuted, fontSize: 9, letterSpacing: 1.5)),
          ]),
        ])),
        const SizedBox(width: 19),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Your storage', style: TextStyle(color: _textMuted, fontSize: 13)),
          const SizedBox(height: 5),
          Text(prettyBytes(free), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 28, letterSpacing: -0.8)),
          const Text('available', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Text('${prettyBytes(total)} capacity', style: const TextStyle(color: _textMuted, fontSize: 12)),
        ])),
      ]),
    );
  }

  Widget _permissionCard() => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: _tile(children: [
      const Row(children: [Icon(Icons.lock_outline, color: Color(0xFFFFD18C)), SizedBox(width: 8),
        Expanded(child: Text('Storage permission required', style: TextStyle(fontWeight: FontWeight.w800)))]),
      const SizedBox(height: 7),
      const Text('Android requires you to enable “Allow access to manage all files” in system settings. DiskWise never sends your files anywhere.', style: TextStyle(color: _textMuted)),
      const SizedBox(height: 10),
      OutlinedButton(onPressed: _grantAccess, child: const Text('Open Android settings')),
    ]),
  );

  Widget _duplicates() => ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 25), children: [
    const Text('Real duplicates.', style: TextStyle(fontSize: 31, fontWeight: FontWeight.w900, letterSpacing: -1)),
    const SizedBox(height: 4),
    const Text('Same bytes, even when filenames differ.', style: TextStyle(color: _textMuted)),
    const SizedBox(height: 17),
    if (!_hasReport) _emptyState('Run an analysis first', 'Duplicate comparisons start with file size, followed by partial and full SHA-256 checks.', Icons.content_copy_outlined),
    if (_hasReport) ...[
      _tile(children: [
        const Text('VERIFIED RECOVERABLE SPACE', style: TextStyle(color: _textMuted, fontSize: 11, letterSpacing: 1)),
        const SizedBox(height: 6),
        Text(prettyBytes(number(_summary['duplicateBytes'])), style: const TextStyle(fontSize: 33, fontWeight: FontWeight.w900, color: _accent)),
        Text('${_summary['duplicateGroups']} distinct duplicate groups', style: const TextStyle(color: _textMuted)),
      ]),
      const SizedBox(height: 12),
      if (_selectedPaths.isNotEmpty) Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FilledButton.icon(onPressed: _busy ? null : _deleteDuplicates,
          icon: const Icon(Icons.delete_forever_outlined),
          label: Text('Review permanent deletion (${_selectedPaths.length})')),
      ),
      ...(_pages['duplicates'] ?? []).map(_duplicateGroupCard),
      _moreButton('duplicates'),
      const SizedBox(height: 8),
      const Text('The first copy in each group is locked in the UI. For every deletion, the engine additionally checks a non-selected identical copy still exists.',
          style: TextStyle(color: _textMuted, fontSize: 12)),
    ],
  ]);

  Widget _duplicateGroupCard(Map<String, dynamic> group) {
    final items = (group['items'] as List).map(asMap).toList();
    final recoverable = number(group['reclaimable']);
    return Padding(padding: const EdgeInsets.only(bottom: 11), child: _tile(children: [
      Row(children: [
        const Icon(Icons.library_add_check_outlined, color: _accent), const SizedBox(width: 9),
        Expanded(child: Text('${items.length} identical files', style: const TextStyle(fontWeight: FontWeight.w800))),
        Text(prettyBytes(recoverable), style: const TextStyle(color: _accent, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 11),
      ...items.asMap().entries.map((entry) {
        final index = entry.key;
        final item = entry.value;
        final path = string(item['path']);
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Container(
            decoration: BoxDecoration(color: _surfaceLight, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              if (index == 0) const Padding(padding: EdgeInsets.symmetric(horizontal: 14),
                child: Icon(Icons.lock_outline, color: _accent, size: 21))
              else Checkbox(value: _selectedPaths.contains(path),
                onChanged: _busy ? null : (checked) => setState(() {
                  if (checked == true) { _selectedPaths.add(path); } else { _selectedPaths.remove(path); }
                })),
              Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(string(item['name']), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _textMuted, fontSize: 10)),
                ]))),
              IconButton(icon: const Icon(Icons.copy_outlined, size: 17), tooltip: 'Copy path',
                onPressed: () async { await Clipboard.setData(ClipboardData(text: path)); _notify('File path copied'); }),
            ]),
          ),
        );
      }),
    ]));
  }

  Widget _insights() {
    final kinds = {'folders': 'Folders', 'unused': 'Unused', 'large': 'Large', 'tiny': 'Tiny'};
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 25), children: [
      const Text('Find what matters.', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -1)),
      const Text('Recommendations only — not proof a file is unneeded.', style: TextStyle(color: _textMuted)),
      const SizedBox(height: 16),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: kinds.entries.map((entry) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(label: Text(entry.value), selected: _insightKind == entry.key,
          onSelected: (_) {
            setState(() => _insightKind = entry.key);
            if (!_pages.containsKey(entry.key)) _loadPage(entry.key);
          }),
      )).toList())),
      const SizedBox(height: 14),
      if (!_hasReport) _emptyState('Analyze storage first', 'Choose all storage or one volume, then explore old folders and large files.', Icons.folder_copy_outlined),
      if (_hasReport) ...[
        if (_insightKind == 'unused') const Padding(padding: EdgeInsets.only(bottom: 12),
            child: Text('“Unused” means not modified in the chosen period. Android does not reliably report last-opened time.',
                style: TextStyle(color: _textMuted, fontSize: 12))),
        ...(_pages[_insightKind] ?? []).map((r) => _insightRow(r, folder: _insightKind == 'folders')),
        _moreButton(_insightKind),
      ],
    ]);
  }

  Widget _insightRow(Map<String, dynamic> data, {required bool folder}) {
    final label = folder ? string(data['path']) : string(data['name']);
    final size = number(folder ? data['unusedBytes'] : data['size']);
    final path = string(data['path']);
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: _tile(children: [
      Row(children: [
        Icon(folder ? Icons.folder_open_rounded : Icons.insert_drive_file_outlined, color: _accent),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(folder ? '${data['unusedCount']} older files • ${data['fileCount']} total' : path,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _textMuted, fontSize: 11)),
        ])),
        const SizedBox(width: 5),
        Text(prettyBytes(size), style: const TextStyle(color: _accent, fontSize: 12, fontWeight: FontWeight.w800)),
      ]),
    ]));
  }

  Widget _settings() => ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 28), children: [
    const Text('You decide.', style: TextStyle(fontSize: 31, fontWeight: FontWeight.w900)),
    const Text('Configure safe, deliberate storage reviews.', style: TextStyle(color: _textMuted)),
    _sectionHeader('Engine preferences', 'Recommendations, not automatic actions'),
    _tile(children: [
      _settingSelector('Older than', '$_days days', _showDaysPicker),
      const Divider(height: 20),
      _settingSelector('Large file minimum', '${_largeMB} MB', _showLargePicker),
      const Divider(height: 20),
      _settingSelector('Android access', _granted ? 'Allowed' : 'Not allowed', _grantAccess),
    ]),
    _sectionHeader('Privacy & protection', 'Designed to remain on your phone'),
    _tile(children: const [
      _InfoLine(Icons.offline_bolt_outlined, 'Runs locally', 'No account, telemetry or file upload.'),
      Divider(height: 22),
      _InfoLine(Icons.rule_folder_outlined, 'Scoped by Android', 'Never reads other apps’ protected private storage.'),
      Divider(height: 22),
      _InfoLine(Icons.phonelink_lock_outlined, 'No background cleaning', 'Every removal requires your explicit confirmation.'),
      Divider(height: 22),
      _InfoLine(Icons.warning_amber_outlined, 'Deletion is permanent', 'No undo or trash in this version. Back up first.'),
      Divider(height: 22),
      _InfoLine(Icons.speed_outlined, 'Bounded indexing', 'Up to 250,000 files per analysis; partial results clearly labeled.'),
    ]),
    const SizedBox(height: 14),
    const Text('DiskWise Mobile v3.0 • Android 11+ • Material 3 • Native Kotlin engine',
        textAlign: TextAlign.center, style: TextStyle(color: _textMuted, fontSize: 11)),
  ]);

  Widget _settingSelector(String title, String value, VoidCallback onTap) => InkWell(
    onTap: _busy ? null : onTap, borderRadius: BorderRadius.circular(12),
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: _textMuted, fontSize: 11)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ])),
      const Icon(Icons.chevron_right_rounded, color: _textMuted),
    ])),
  );

  Future<int?> _customNumber(String title, int current, int minimum, int maximum) async {
    final controller = TextEditingController(text: '$current');
    final answer = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        backgroundColor: _surfaceLight,
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(hintText: '$minimum–$maximum'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final parsed = int.tryParse(controller.text.trim());
            if (parsed == null || parsed < minimum || parsed > maximum) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
                content: Text('Enter a whole number between $minimum and $maximum'),
              ));
              return;
            }
            Navigator.pop(dialogContext, parsed);
          }, child: const Text('Apply')),
        ],
      ),
    );
    controller.dispose();
    return answer;
  }

  Future<void> _showDaysPicker() async {
    final answer = await showDialog<int>(context: context, builder: (dialogContext) => SimpleDialog(
      backgroundColor: _surfaceLight,
      title: const Text('Consider files older than'),
      children: [
        ...[30, 60, 90, 180, 365, 730, 1095, 1825].map((n) => SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, n), child: Text('$n days'),
        )),
        SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, -1),
            child: const Text('Custom number of days…', style: TextStyle(color: _accent))),
      ],
    ));
    if (!mounted || answer == null) return;
    final selected = answer == -1 ? await _customNumber('Unused threshold (days)', _days, 1, 3650) : answer;
    if (selected != null && mounted) setState(() => _days = selected);
  }

  Future<void> _showLargePicker() async {
    final answer = await showDialog<int>(context: context, builder: (dialogContext) => SimpleDialog(
      backgroundColor: _surfaceLight, title: const Text('Minimum large file size'),
      children: [
        ...[10, 50, 100, 250, 500, 1024, 2048, 4096].map((n) => SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, n),
          child: Text(n >= 1024 ? '${n ~/ 1024} GB' : '$n MB'),
        )),
        SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, -1),
          child: const Text('Custom size in MB…', style: TextStyle(color: _accent))),
      ],
    ));
    if (!mounted || answer == null) return;
    final selected = answer == -1 ? await _customNumber('Large file threshold (MB)', _largeMB, 1, 100000) : answer;
    if (selected != null && mounted) setState(() => _largeMB = selected);
  }

  Widget _moreButton(String kind) {
    final current = _pages[kind]?.length ?? 0;
    final count = _totals[kind] ?? 0;
    if (count <= current) return const SizedBox.shrink();
    return Center(child: TextButton.icon(onPressed: () => _loadPage(kind),
      icon: const Icon(Icons.expand_more_rounded),
      label: Text('Load more ($current/$count)')));
  }

  Widget _emptyState(String title, String description, IconData icon) => _tile(children: [
    const SizedBox(height: 24),
    Center(child: Icon(icon, size: 56, color: _accent)),
    const SizedBox(height: 15),
    Center(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
    const SizedBox(height: 8),
    Text(description, textAlign: TextAlign.center, style: const TextStyle(color: _textMuted)),
    const SizedBox(height: 25),
    Center(child: OutlinedButton(onPressed: () => setState(() => _tab = 0), child: const Text('Go to overview'))),
  ]);

  Widget _metricCard(String title, String value, IconData icon) => _tile(children: [
    Icon(icon, color: _accent, size: 20),
    const SizedBox(height: 7),
    Text(value, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
    const SizedBox(height: 3),
    Text(title, style: const TextStyle(color: _textMuted, fontSize: 11)),
  ]);

  Widget _sectionHeader(String title, String subtitle) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 19, 0, 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
      const SizedBox(height: 2),
      Text(subtitle, style: const TextStyle(color: _textMuted, fontSize: 12)),
    ]),
  );

  Widget _tile({required List<Widget> children}) => Container(
    decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(22)),
    padding: const EdgeInsets.all(17),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, color: _accent, size: 22),
    const SizedBox(width: 12),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(fontSize: 12, color: _textMuted)),
    ])),
  ]);
}
