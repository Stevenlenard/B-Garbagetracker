import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/complaint_center_service.dart';
import '../services/service_area_service.dart';
import '../utils/app_theme.dart';
import '../utils/complaint_flow.dart';
import '../utils/custom_notification.dart';
import '../widgets/app_date_range_picker.dart';

const Color _teal = Color(0xFF007A63);
const Color _tealDark = Color(0xFF00796B);
const Color _ink = Color(0xFF0F172A);
const Color _muted = Color(0xFF64748B);
const Color _surface = Color(0xFFF1F5F9);

/// Admin Complaint Center: Active Complaints / Resolved Archive, each for Residents and Drivers.
/// Every list, counter and status comes from the authoritative store (MySQL through the PHP API
/// for resident complaints, Firebase `truck_issues` for driver reports); nothing is patched locally.
class ComplaintsScreen extends StatefulWidget {
  const ComplaintsScreen({
    super.key,
    this.isEmbedded = false,
    this.onBack,
    this.controller,
    this.listenForNewComplaints = true,
  });

  final bool isEmbedded;
  final VoidCallback? onBack;

  /// For tests; the screen creates its own otherwise.
  final ComplaintCenterController? controller;

  /// Re-reads the list when a new resident complaint notification arrives (Firebase).
  final bool listenForNewComplaints;

  @override
  State<ComplaintsScreen> createState() => _ComplaintsScreenState();
}

class _ComplaintsScreenState extends State<ComplaintsScreen> {
  late final ComplaintCenterController _c;
  late final bool _ownsController;
  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;
  StreamSubscription<DatabaseEvent>? _newComplaintSub;
  bool _baselineSeen = false;

  static const List<String> _residentCategories = <String>[
    'Uncollected Garbage', 'Spilled Waste', 'Driver Behavior', 'Schedule Issue', 'Other'
  ];
  static const List<String> _driverCategories = <String>[
    'Engine', 'Tires', 'Brakes', 'GPS', 'Electrical', 'Fuel', 'Transmission', 'Hydraulic System', 'Body Damage', 'Other'
  ];

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _c = widget.controller ?? ComplaintCenterController();
    _c.addListener(_onChanged);
    _c.start();
    if (widget.listenForNewComplaints) _listenForNewComplaints();
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    if (_ownsController) _c.dispose();
    _searchDebounce?.cancel();
    _newComplaintSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// A saved resident complaint writes an Admin notification; it is only a signal to re-read
  /// the list from MySQL (the notification is never the complaint record).
  void _listenForNewComplaints() {
    try {
      _newComplaintSub = FirebaseDatabase.instance.ref('notifications').limitToLast(1).onChildAdded.listen((DatabaseEvent e) {
        if (!_baselineSeen) {
          _baselineSeen = true;
          return;
        }
        final Object? v = e.snapshot.value;
        if (v is Map && (v['type'] ?? '').toString() == 'RESIDENT_COMPLAINT' && _c.query.source == ComplaintSource.resident) {
          _c.load(silent: true);
        }
      }, onError: (Object e) => debugPrint('complaint notification listener: $e'));
    } catch (e) {
      debugPrint('complaint notification listener unavailable: $e');
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _c.setSearch(value));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildHeader(),
            Expanded(
              child: RefreshIndicator(
                color: _teal,
                onRefresh: () => _c.load(),
                child: LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
                  final bool narrow = box.maxWidth < 600;
                  final double gutter = narrow ? 16 : 24;
                  return CustomScrollView(
                    key: const ValueKey<String>('complaint-center-scroll'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: <Widget>[
                      SliverToBoxAdapter(
                        child: _centered(
                          Padding(
                            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _buildCounters(narrow),
                                const SizedBox(height: 14),
                                _buildScopeTabs(narrow),
                                const SizedBox(height: 12),
                                _buildSourceAndSearch(narrow),
                                const SizedBox(height: 10),
                                _buildFilters(),
                                const SizedBox(height: 10),
                                _buildResultSummary(),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _centered(
                          Padding(
                            padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
                            child: _buildList(box.maxWidth),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _centered(Widget child) =>
      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1100), child: child));

  // ------------------------------------------------------------------ header

  Widget _buildHeader() {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: <BoxShadow>[BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: <Widget>[
          Semantics(
            button: true,
            label: isMobile ? 'Open menu' : 'Back',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                if (isMobile && Scaffold.maybeOf(context)?.hasDrawer == true) {
                  Scaffold.of(context).openDrawer();
                } else if (isMobile) {
                  final ScaffoldState? outer = context.findAncestorStateOfType<ScaffoldState>();
                  if (outer != null && outer.hasDrawer) {
                    outer.openDrawer();
                  } else if (widget.onBack != null) {
                    widget.onBack!();
                  } else {
                    Navigator.maybePop(context);
                  }
                } else if (widget.onBack != null) {
                  widget.onBack!();
                } else {
                  Navigator.maybePop(context);
                }
              },
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: _surface, shape: BoxShape.circle),
                child: Icon(isMobile ? Icons.menu_rounded : Icons.arrow_back_ios_new_rounded,
                    color: const Color(0xFF1E293B), size: isMobile ? 22 : 18),
              ),
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Complaint Center',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink, letterSpacing: -0.3)),
                SizedBox(height: 2),
                Text('Manage, track, and resolve resident and driver complaints',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: _muted, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _c.loading ? null : () => _c.load(),
            icon: const Icon(Icons.refresh_rounded, color: _teal),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ counters + tabs

  Widget _buildCounters(bool narrow) {
    final ComplaintCounts n = _c.counts;
    final bool ready = _c.countsKnown; // unknown counts are "–", never a confirmed 0
    Widget card(String key, String label, int value, IconData icon, Color fg, Color bg, VoidCallback onTap) {
      return Expanded(
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            key: ValueKey<String>('counter-$key'),
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 10 : 16, vertical: narrow ? 10 : 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFEFF2F5)),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, color: fg, size: narrow ? 16 : 18),
                  ),
                  SizedBox(width: narrow ? 8 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(ready ? '$value' : '–',
                            style: TextStyle(fontSize: narrow ? 18 : 22, fontWeight: FontWeight.w900, color: _ink, height: 1.1)),
                        Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: narrow ? 10.5 : 12, fontWeight: FontWeight.w700, color: _muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        card('pending', 'Pending', n.pending, Icons.hourglass_empty_rounded, const Color(0xFFB45309), const Color(0xFFFEF3C7), () {
          _c.showActive(status: ComplaintStatus.pending);
        }),
        SizedBox(width: narrow ? 8 : 12),
        card('in-progress', 'In Progress', n.inProgress, Icons.autorenew_rounded, const Color(0xFF0369A1), const Color(0xFFE0F2FE), () {
          _c.showActive(status: ComplaintStatus.inProgress);
        }),
        SizedBox(width: narrow ? 8 : 12),
        card('resolved', 'Resolved', n.resolved, Icons.verified_rounded, const Color(0xFF15803D), const Color(0xFFDCFCE7),
            () => _c.setScope(ComplaintScope.resolved)),
      ],
    );
  }

  Widget _buildScopeTabs(bool narrow) {
    final ComplaintCounts n = _c.counts;
    final bool ready = _c.countsKnown;
    Widget tab(ComplaintScope scope, String label, int count) {
      final bool selected = _c.query.scope == scope;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            key: ValueKey<String>('scope-${scope.name}'),
            borderRadius: BorderRadius.circular(10),
            onTap: selected ? null : () => _c.setScope(scope),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(color: selected ? _teal : Colors.transparent, borderRadius: BorderRadius.circular(10)),
              child: Text(
                ready ? '$label ($count)' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: narrow ? 12 : 13,
                  letterSpacing: 0.3,
                  color: selected ? Colors.white : const Color(0xFF475569),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: <Widget>[
          tab(ComplaintScope.active, narrow ? 'ACTIVE' : 'ACTIVE COMPLAINTS', n.pending + n.inProgress),
          tab(ComplaintScope.resolved, narrow ? 'RESOLVED ARCHIVE' : 'RESOLVED ARCHIVE', n.resolved),
        ],
      ),
    );
  }

  Widget _buildSourceAndSearch(bool narrow) {
    final Widget sources = Wrap(
      spacing: 8,
      children: <Widget>[
        for (final ComplaintSource s in ComplaintSource.values)
          ChoiceChip(
            key: ValueKey<String>('source-${s.name}'),
            label: Text(s == ComplaintSource.resident ? 'Residents' : 'Drivers'),
            avatar: Icon(s == ComplaintSource.resident ? Icons.home_rounded : Icons.local_shipping_rounded,
                size: 16, color: _c.query.source == s ? Colors.white : _teal),
            selected: _c.query.source == s,
            showCheckmark: false,
            selectedColor: _teal,
            backgroundColor: Colors.white,
            side: BorderSide(color: _c.query.source == s ? _teal : const Color(0xFFE2E8F0)),
            labelStyle: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 12.5, color: _c.query.source == s ? Colors.white : const Color(0xFF334155)),
            onSelected: (bool on) {
              if (!on || _c.query.source == s) return;
              _searchDebounce?.cancel();
              _search.clear();
              _c.setSource(s);
            },
          ),
      ],
    );
    final Widget search = SizedBox(
      height: 44,
      child: TextField(
        key: const ValueKey<String>('complaint-search'),
        controller: _search,
        onChanged: _onSearchChanged,
        onSubmitted: (String v) {
          _searchDebounce?.cancel();
          _c.setSearch(v);
        },
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF1A1A1A)),
        decoration: InputDecoration(
          hintText: _c.query.source == ComplaintSource.resident ? 'Search complaint # or resident name' : 'Search driver, truck or report #',
          hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
          prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF00897B), size: 20),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    _searchDebounce?.cancel();
                    _search.clear();
                    _c.setSearch('');
                  },
                ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _teal, width: 1.5)),
        ),
      ),
    );
    if (narrow) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[sources, const SizedBox(height: 10), search]);
    }
    return Row(children: <Widget>[sources, const SizedBox(width: 16), Expanded(child: search)]);
  }

  // ------------------------------------------------------------------ filters

  Widget _buildFilters() {
    final ComplaintQuery q = _c.query;
    final bool resident = q.source == ComplaintSource.resident;
    final List<String> categories = resident ? _residentCategories : _driverCategories;
    final String dateWord = q.scope == ComplaintScope.resolved ? 'Resolved' : 'Submitted';
    String dateLabel = 'Any date';
    if (q.from != null && q.to != null) {
      final DateFormat f = DateFormat('MMM d');
      dateLabel = DateUtils.isSameDay(q.from, q.to) ?DateFormat('MMM d, yyyy').format(q.from!) : '${f.format(q.from!)} – ${DateFormat('MMM d, yyyy').format(q.to!)}';
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _menuFilter<String>(
          key: 'filter-category',
          icon: Icons.category_rounded,
          label: q.category ?? 'All categories',
          active: q.category != null,
          options: <String?>[null, ...categories],
          optionLabel: (String? v) => v ?? 'All categories',
          selected: q.category,
          onSelected: _c.setCategory,
        ),
        if (resident)
          _menuFilter<String>(
            key: 'filter-location',
            icon: Icons.location_on_rounded,
            label: q.location ?? 'All locations',
            active: q.location != null,
            options: <String?>[null, ...ServiceAreaService.documentedAreaNames],
            optionLabel: (String? v) => v ?? 'All locations',
            selected: q.location,
            onSelected: _c.setLocation,
          ),
        if (q.scope == ComplaintScope.active)
          _menuFilter<ComplaintStatus>(
            key: 'filter-status',
            icon: Icons.flag_rounded,
            label: q.status == null ? 'Pending & In Progress' : ComplaintFlow.label(q.status!),
            active: q.status != null,
            options: const <ComplaintStatus?>[null, ComplaintStatus.pending, ComplaintStatus.inProgress],
            optionLabel: (ComplaintStatus? v) => v == null ? 'Pending & In Progress' : ComplaintFlow.label(v),
            selected: q.status,
            onSelected: _c.setStatus,
          ),
        _chipButton(
          key: 'filter-date',
          icon: Icons.calendar_today_rounded,
          label: '$dateWord: $dateLabel',
          active: q.from != null,
          onTap: _pickDateRange,
        ),
        if (q.hasFilters)
          TextButton.icon(
            key: const ValueKey<String>('filter-clear'),
            onPressed: () {
              _searchDebounce?.cancel();
              _search.clear();
              _c.clearFilters();
            },
            icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
            label: const Text('Clear filters', style: TextStyle(fontWeight: FontWeight.w800)),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFB91C1C)),
          ),
      ],
    );
  }

  Widget _chipButton({required String key, required IconData icon, required String label, required bool active, VoidCallback? onTap}) {
    return Material(
      color: active ? const Color(0xFFE6F4F1) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey<String>(key),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? _teal.withValues(alpha: 0.5) : const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: _teal),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: _ink)),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.arrow_drop_down_rounded, size: 18, color: _muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuFilter<T>({
    required String key,
    required IconData icon,
    required String label,
    required bool active,
    required List<T?> options,
    required String Function(T?) optionLabel,
    required T? selected,
    required Future<void> Function(T?) onSelected,
  }) {
    return PopupMenuButton<int>(
      key: ValueKey<String>(key),
      tooltip: label,
      onSelected: (int i) => onSelected(options[i]),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: Colors.white,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        for (int i = 0; i < options.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: <Widget>[
                Icon(options[i] == selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 16, color: options[i] == selected ? _teal : Colors.grey.shade400),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(optionLabel(options[i]),
                      style: TextStyle(
                          fontWeight: options[i] == selected ? FontWeight.w800 : FontWeight.w600,
                          color: options[i] == selected ? _teal : const Color(0xFF1E293B),
                          fontSize: 13)),
                ),
              ],
            ),
          ),
      ],
      child: IgnorePointer(child: _chipButton(key: '$key-chip', icon: icon, label: label, active: active, onTap: () {})),
    );
  }

  Future<void> _pickDateRange() async {
    final ComplaintQuery q = _c.query;
    final DateTime now = DateTime.now();
    final AppDatePick? pick = await showAppDateRangePicker(
      context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialRange: q.from != null && q.to != null ? DateTimeRange(start: q.from!, end: q.to!) : null,
      title: q.scope == ComplaintScope.resolved ? 'Resolution date' : 'Submission date',
      clearable: q.from != null || q.to != null,
    );
    if (pick == null) return;
    if (pick.cleared) {
      await _c.setDateRange(null, null);
    } else if (pick.range != null) {
      await _c.setDateRange(pick.range!.start, pick.range!.end);
    }
  }

  // ------------------------------------------------------------------ list

  Widget _buildResultSummary() {
    final ComplaintPage? p = _c.page;
    final String what = _c.query.scope == ComplaintScope.resolved ? 'resolved' : 'active';
    final String who = _c.query.source == ComplaintSource.resident ? 'resident complaints' : 'driver reports';
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            p == null
                ? (_c.error != null && !_c.loading ? 'Could not load $what $who' : 'Loading $what $who…')
                : (p.total == 0 ? 'No $what $who' : 'Showing ${p.firstIndex}–${p.lastIndex} of ${p.total} $what $who'),
            key: const ValueKey<String>('result-summary'),
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _muted),
          ),
        ),
        if (_c.loading && p != null) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _teal)),
      ],
    );
  }

  Widget _buildList(double width) {
    final ComplaintPage? p = _c.page;
    final String? error = _c.error;
    if (p == null && error == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF00897B))),
      );
    }
    final List<Widget> children = <Widget>[];
    if (error != null) children.add(_errorBanner(error));
    if (p != null && p.items.isEmpty && error == null) children.add(_emptyState());
    if (p != null && p.items.isNotEmpty) {
      final bool twoColumns = width >= 1000;
      if (twoColumns) {
        for (int i = 0; i < p.items.length; i += 2) {
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _ComplaintCard(record: p.items[i], onOpen: () => _openDetails(p.items[i]))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: i + 1 < p.items.length
                        ? _ComplaintCard(record: p.items[i + 1], onOpen: () => _openDetails(p.items[i + 1]))
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ));
        }
      } else {
        for (final ComplaintRecord r in p.items) {
          children.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: _ComplaintCard(record: r, onOpen: () => _openDetails(r))));
        }
      }
      children.add(_pager(p));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _pager(ComplaintPage p) {
    if (p.pageCount <= 1) return const SizedBox(height: 8);
    final ButtonStyle style = OutlinedButton.styleFrom(
      foregroundColor: _teal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
        final bool compact = box.maxWidth < 420;
        Widget button(String key, bool enabled, int target, IconData icon, String label) {
          final VoidCallback? onPressed = enabled && !_c.loading ? () => _c.goToPage(target) : null;
          return compact
              ? OutlinedButton(key: ValueKey<String>(key), onPressed: onPressed, style: style, child: Icon(icon, semanticLabel: label))
              : OutlinedButton.icon(key: ValueKey<String>(key), onPressed: onPressed, style: style, icon: Icon(icon), label: Text(label));
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            button('page-prev', p.page > 1, p.page - 1, Icons.chevron_left_rounded, 'Previous'),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('Page ${p.page} of ${p.pageCount}',
                    key: const ValueKey<String>('page-label'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w800, color: _ink)),
              ),
            ),
            button('page-next', p.hasMore, p.page + 1, Icons.chevron_right_rounded, 'Next'),
          ],
        );
      }),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      key: const ValueKey<String>('complaint-error'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF991B1B))),
          ),
          TextButton(onPressed: () => _c.load(), child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final bool archive = _c.query.scope == ComplaintScope.resolved;
    final bool filtered = _c.query.hasFilters;
    return Padding(
      key: const ValueKey<String>('complaint-empty'),
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: <Widget>[
          Icon(filtered ? Icons.search_off_rounded : (archive ? Icons.inventory_2_outlined : Icons.task_alt_rounded),
              size: 56, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            filtered ? 'No complaints match your filters' : (archive ? 'No resolved complaints yet' : 'No active complaints'),
            style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w700),
          ),
          if (!filtered && !archive)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Everything has been handled.', style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ details + actions

  Future<void> _openDetails(ComplaintRecord record) async {
    final bool wide = MediaQuery.of(context).size.width >= 700;
    final Widget body = _ComplaintDetailsView(controller: _c, record: record, onTransitioned: _afterTransition);
    if (wide) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760), child: body),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (BuildContext ctx) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
          child: body,
        ),
      );
    }
  }

  /// Called after the store confirmed a status change (details already closed).
  void _afterTransition(ComplaintRecord record, TransitionResult r) {
    if (!mounted) return;
    final String who = record.source == ComplaintSource.resident ? 'resident' : 'driver';
    String msg;
    if (!r.changed) {
      msg = r.message ?? '${record.displayId} is already ${ComplaintFlow.label(r.status).toLowerCase()}.';
    } else if (r.status == ComplaintStatus.resolved) {
      msg = '${record.displayId} resolved and moved to the Resolved Archive.';
    } else {
      msg = '${record.displayId} marked as In Progress.';
    }
    if (r.notification == 'sent' || r.notification == 'already') msg += ' The $who has been notified.';
    CustomNotification.showTopNotification(context, msg, false);
    if (r.notificationFailed) _showNotificationFailure(record, r.status);
  }

  void _showNotificationFailure(ComplaintRecord record, ComplaintStatus status) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Notification not delivered', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text(
          'The status of ${record.displayId} was saved, but the ${record.roleLabel.toLowerCase()} notification could not be '
          'delivered. The complaint history already shows the new status. You can retry the notification now.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _teal),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                // Same target again: no second transition; the server re-checks the notification.
                final TransitionResult again = await _c.retryNotification(record, status);
                if (!mounted) return;
                if (again.notificationFailed) {
                  _showNotificationFailure(record, status);
                } else {
                  CustomNotification.showTopNotification(context, 'Notification delivered for ${record.displayId}.', false);
                }
              } catch (e) {
                if (mounted) CustomNotification.showTopNotification(context, ComplaintFlow.errorMessage(e), true);
              }
            },
            child: const Text('Retry notification'),
          ),
        ],
      ),
    );
  }
}

String _fmtDate(DateTime? d) => d == null ? '—' : DateFormat('MMM d, yyyy • h:mm a').format(d);

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);

  final ComplaintStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (status) {
      ComplaintStatus.pending => (const Color(0xFFFEF3C7), const Color(0xFFB45309)),
      ComplaintStatus.inProgress => (const Color(0xFFE0F2FE), const Color(0xFF0369A1)),
      ComplaintStatus.resolved => (const Color(0xFFDCFCE7), const Color(0xFF15803D)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(ComplaintFlow.label(status).toUpperCase(),
          style: TextStyle(color: fg, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
    );
  }
}

class _ComplaintCard extends StatelessWidget {
  const _ComplaintCard({required this.record, required this.onOpen});

  final ComplaintRecord record;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final bool resident = record.source == ComplaintSource.resident;
    final String? place = resident ? record.locationLabel : (record.truckId != null ? 'Truck ${record.truckId}' : null);
    return Container(
      key: ValueKey<String>('complaint-card-${record.source.name}-${record.id}'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.grey.shade50, width: 1.5),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(10)),
                      child: Text(record.displayId,
                          style: const TextStyle(color: _tealDark, fontWeight: FontWeight.w900, fontSize: 12.5)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(record.category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5, color: Color(0xFF1A1A1A))),
                          const SizedBox(height: 3),
                          Row(
                            children: <Widget>[
                              Icon(resident ? Icons.person_rounded : Icons.badge_rounded, size: 14, color: _muted),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(children: <InlineSpan>[
                                    TextSpan(text: record.reporterName),
                                    TextSpan(
                                      text: ' · ${record.roleLabel}',
                                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: _muted),
                                    ),
                                  ]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Color(0xFF475569), fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(record.status),
                  ],
                ),
                if (place != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Icon(resident ? Icons.location_on_rounded : Icons.local_shipping_rounded, size: 14, color: const Color(0xFF00897B)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(place,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _tealDark, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ],
                if (record.description.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(record.description,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 13)),
                ],
                const SizedBox(height: 12),
                const Divider(height: 1, color: Color(0xFFF1F4F8)),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    const Icon(Icons.access_time_rounded, size: 14, color: Color(0xFF94A3B8)),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        record.isResolved && record.resolvedAt != null
                            ? 'Resolved ${_fmtDate(record.resolvedAt)}'
                            : 'Submitted ${_fmtDate(record.submittedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                      ),
                    ),
                    Text(record.isResolved ? 'View Resolution' : 'View Details',
                        style: const TextStyle(color: _teal, fontWeight: FontWeight.w700, fontSize: 13)),
                    const Icon(Icons.chevron_right_rounded, size: 16, color: _teal),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Complaint details with status history; Active complaints get the lifecycle actions,
/// Resolved ones are read-only.
class _ComplaintDetailsView extends StatefulWidget {
  const _ComplaintDetailsView({required this.controller, required this.record, required this.onTransitioned});

  final ComplaintCenterController controller;
  final ComplaintRecord record;
  final void Function(ComplaintRecord record, TransitionResult result) onTransitioned;

  @override
  State<_ComplaintDetailsView> createState() => _ComplaintDetailsViewState();
}

class _ComplaintDetailsViewState extends State<_ComplaintDetailsView> {
  ComplaintDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final ComplaintDetail d = await widget.controller.detail(widget.record);
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      if (mounted) setState(() => _error = ComplaintFlow.errorMessage(e));
    }
  }

  Future<void> _change(ComplaintStatus to) async {
    final ComplaintRecord current = _detail?.record ?? widget.record;
    final TransitionResult? r = await showDialog<TransitionResult>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => _StatusChangeDialog(controller: widget.controller, record: current, target: to),
    );
    if (r == null || !mounted) return;
    Navigator.of(context).pop(); // close the details; the list was reloaded from the store
    widget.onTransitioned(current, r);
  }

  @override
  Widget build(BuildContext context) {
    final ComplaintRecord c = _detail?.record ?? widget.record;
    final bool resident = c.source == ComplaintSource.resident;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('${resident ? 'Complaint' : 'Driver Report'} ${c.displayId}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _tealDark)),
                    const SizedBox(height: 4),
                    _StatusBadge(c.status),
                  ],
                ),
              ),
              IconButton(tooltip: 'Close', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            children: <Widget>[
              if (_detail == null && _error == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(color: _teal, backgroundColor: _surface),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(children: <Widget>[
                    Expanded(child: Text('Latest details could not be loaded: $_error', style: const TextStyle(color: Color(0xFF991B1B), fontSize: 12.5))),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                ),
              _field('Category', c.category),
              _field('Complainant', '${c.reporterName} (${c.roleLabel})'),
              if (resident) _field('Location / Purok', c.locationLabel ?? 'Not specified'),
              if (!resident) _field('Truck', c.truckId ?? 'N/A'),
              if (!resident && c.urgency != null) _field('Urgency', c.urgency!.toUpperCase()),
              _field('Submitted', _fmtDate(c.submittedAt)),
              _field('Description', c.description.trim().isEmpty ? '—' : c.description),
              const SizedBox(height: 4),
              const Text('STATUS HISTORY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.grey, letterSpacing: 1)),
              const SizedBox(height: 8),
              ..._history(c),
              if (c.isResolved) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey<String>('resolution-panel'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFBBF7D0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Row(children: <Widget>[
                        Icon(Icons.verified_rounded, size: 18, color: Color(0xFF15803D)),
                        SizedBox(width: 8),
                        Text('RESOLUTION', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: Color(0xFF15803D), letterSpacing: 0.8)),
                      ]),
                      const SizedBox(height: 8),
                      Text(c.resolutionNote ?? 'No resolution note was recorded.',
                          style: const TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600, color: Color(0xFF14532D))),
                      const SizedBox(height: 8),
                      Text('Resolved: ${c.resolvedAt == null ? 'date not recorded' : _fmtDate(c.resolvedAt)}',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF166534))),
                      if (c.resolvedBy != null)
                        Text('Resolved by: ${c.resolvedBy}', style: const TextStyle(fontSize: 12, color: Color(0xFF166534))),
                    ],
                  ),
                ),
              ] else if (c.resolutionNote != null) ...<Widget>[
                const SizedBox(height: 8),
                _field('Admin note', c.resolutionNote!),
              ],
            ],
          ),
        ),
        if (!c.isResolved) ...<Widget>[
          const Divider(height: 1),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 16 + MediaQuery.of(context).viewPadding.bottom),
            child: Row(
              children: <Widget>[
                if (c.status == ComplaintStatus.pending) ...<Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey<String>('action-in-progress'),
                      onPressed: () => _change(ComplaintStatus.inProgress),
                      icon: const Icon(Icons.autorenew_rounded),
                      label: const Text('Mark In Progress', style: TextStyle(fontWeight: FontWeight.w800)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF0369A1),
                        side: const BorderSide(color: Color(0xFF0369A1)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey<String>('action-resolve'),
                    onPressed: () => _change(ComplaintStatus.resolved),
                    icon: const Icon(Icons.task_alt_rounded),
                    label: const Text('Mark Resolved', style: TextStyle(fontWeight: FontWeight.w800)),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00897B),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _history(ComplaintRecord c) {
    final List<ComplaintHistoryEvent> events = _detail?.history ?? ComplaintHistoryEvent.derive(c);
    if (events.isEmpty) {
      return const <Widget>[Text('No history recorded.', style: TextStyle(color: _muted, fontSize: 13))];
    }
    return <Widget>[
      for (final ComplaintHistoryEvent e in events)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(padding: const EdgeInsets.only(top: 2), child: _StatusBadge(e.status)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${e.status == ComplaintStatus.pending ? 'Submitted' : ComplaintFlow.label(e.status)} · ${e.at == null ? 'date not recorded' : _fmtDate(e.at)}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink),
                    ),
                    if (e.by != null) Text('by ${e.by}', style: const TextStyle(fontSize: 12, color: _muted)),
                    if (e.note != null && e.status != ComplaintStatus.resolved)
                      Text(e.note!, style: const TextStyle(fontSize: 12.5, color: Color(0xFF334155))),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _field(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.grey, letterSpacing: 1)),
          const SizedBox(height: 3),
          SelectableText(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black87)),
        ],
      ),
    );
  }
}

/// Confirmation for one transition. Resolving requires a resolution note. The dialog waits for
/// the store's confirmation and returns it; errors stay in the dialog (nothing is claimed early).
class _StatusChangeDialog extends StatefulWidget {
  const _StatusChangeDialog({required this.controller, required this.record, required this.target});

  final ComplaintCenterController controller;
  final ComplaintRecord record;
  final ComplaintStatus target;

  @override
  State<_StatusChangeDialog> createState() => _StatusChangeDialogState();
}

class _StatusChangeDialogState extends State<_StatusChangeDialog> {
  final TextEditingController _note = TextEditingController();
  bool _saving = false;
  String? _error;

  bool get _resolving => widget.target == ComplaintStatus.resolved;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (_resolving) {
      final String? invalid = ComplaintFlow.validateResolutionNote(_note.text);
      if (invalid != null) {
        setState(() => _error = invalid);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final TransitionResult r = await widget.controller.transition(widget.record, widget.target, _note.text);
      if (mounted) Navigator.of(context).pop(r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = ComplaintFlow.errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final String id = widget.record.displayId;
    final String who = widget.record.source == ComplaintSource.resident ? 'resident' : 'driver';
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(_resolving ? 'Resolve $id?' : 'Mark $id as In Progress?', style: const TextStyle(fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                _resolving
                    ? 'Confirm that this complaint has been addressed. It will move to the Resolved Archive and the $who will be notified.'
                    : 'Confirm that you are now working on this complaint. The $who will be notified.',
                style: const TextStyle(color: _muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey<String>('status-note'),
                controller: _note,
                enabled: !_saving,
                maxLines: 4,
                maxLength: ComplaintFlow.resolutionNoteMaxLength,
                decoration: InputDecoration(
                  labelText: _resolving ? 'Resolution note (required)' : 'Note to the $who (optional)',
                  hintText: _resolving ? 'Describe the action taken, e.g. "Garbage collected on Monday by truck GT-007."' : null,
                  alignLabelWithHint: true,
                  filled: true,
                  fillColor: const Color(0xFFF7F8FA),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
              if (_error != null)
                Text(_error!, key: const ValueKey<String>('status-error'), style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey<String>('status-confirm'),
          onPressed: _saving ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: _resolving ? const Color(0xFF00897B) : const Color(0xFF0369A1)),
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(_resolving ? 'Mark Resolved' : 'Mark In Progress'),
        ),
      ],
    );
  }
}
