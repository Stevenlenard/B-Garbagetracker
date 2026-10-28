import '../widgets/period_selector.dart';
import '../utils/route_history_navigation.dart';
import '../utils/trip_links.dart';
import '../utils/eta_evaluation.dart';
import '../utils/predictive_models.dart';
import '../utils/analytics_report_data.dart';
import '../services/analytics_pdf_builder.dart';
import '../services/analytics_xlsx_builder.dart';
import '../utils/report_file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import '../services/load_history_repository.dart';
import '../utils/load_history.dart';
import '../utils/collection_visits.dart';
import '../utils/analytics_recommendations.dart';
import '../utils/analytics_narrative.dart';
import '../models/route_assignment.dart';
import '../services/route_assignment_service.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../utils/custom_notification.dart';
import '../utils/fleet_snapshot.dart';
import '../utils/fleet_status.dart';
import '../services/truck_locations_feed.dart';
import '../widgets/custom_snackbar.dart';
import '../utils/app_theme.dart';
import '../api/api_service.dart';
import '../utils/prediction_engine.dart';
import '../utils/system_logger.dart';
import '../services/service_area_service.dart';
import '../models/driver_trip.dart';
import '../models/user.dart';
import '../services/driver_route_history_service.dart';
import 'route_history_screen.dart';
import '../widgets/app_date_range_picker.dart';
import '../widgets/predictive_models_card.dart';
import '../utils/trip_archive.dart';

class AnalyticsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  final Function(int)? onNavigate;

  /// When hosted in the Admin shell, "View Collection Route" opens Route History inside it.
  final OpenRouteHistory? onOpenRouteHistory;
  const AnalyticsScreen({super.key, this.isEmbedded = false, this.onBack, this.onNavigate, this.onOpenRouteHistory});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> with TickerProviderStateMixin {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();
  bool _showHeaderShadow = true;
  bool _isRefreshing = false;
  bool _showRefreshSpinner = false;
  double _manualPullDepth = 0.0;
  late AnimationController _refreshRotationController;

  Map<String, double> _truckStatusData = {"Active": 0, "Full": 0, "Idle": 0};
  Map<String, double> _complaintStatusData = {"Pending": 0, "In Progress": 0, "Resolved": 0};
  Map<String, double> _complaintSourceData = {"Residents": 0, "Drivers": 0};
  Map<String, int> _purokFrequencyData = {};
  Map<String, int> _purokVisitCounts = {};
  Map<String, int> _purokComplaintData = {};

  // Verified collection visits (GPS evidence; utils/collection_visits.dart).
  VisitSummary? _visitSummary;
  List<AreaGeofence> _geofences = const <AreaGeofence>[];
  Object? _etaRawNotifications;
  bool _geofencesFromDefaults = false;
  Timer? _visitDebounce;

  // Route assignments (backend get_assignments.php) for the selected period.
  final RouteAssignmentService _assignmentService = RouteAssignmentService();
  AssignmentList? _assignments;
  AssignmentFailure _assignmentFailure = AssignmentFailure.none;
  String? _assignmentMessage;

  // Resident-filed complaints only (MySQL), selected period and area.
  int _residentComplaintsTotal = 0;
  int _residentComplaintsUnresolved = 0;
  String _selectedArea = "All Areas";
  // Period (same presets as the Dashboard and Route History). Analytics opens on the last 30 days:
  // trends, regression and moving averages need more than one day of trips.
  ReportPeriod _period = ReportPeriod.lastDays(30);
  DateTimeRange _selectedDateRange = ReportPeriod.lastDays(30).range;

  void _applyPeriod(ReportPeriod p) {
    setState(() {
      _period = p;
      _selectedDateRange = p.range;
      _isDateRange = true;
    });
    refreshAllData();
  }

  bool _isDateRange = true;

  double _avgCollectionTime = 0.0; // median collection duration (hours) of the period's FULL trips
  int _collectionDurationTrips = 0;
  int _stopsPerRoute = 0;
  double _distanceCovered = 0.0;

  int _totalRoutes = 0;
  int _completedRoutes = 0;
  double _coveragePercent = 0.0;
  String? _routeTrend;
  bool _routeTrendPositive = true;

  int _prevCompletedRoutes = 0;
  int _prevTotalRoutes = 0;
  double _routeCompletionRate = 0.0;
  double _prevRouteCompletionRate = 0.0;
  String? _routeCompletionTrendText;
  bool _routeCompletionTrendPositive = true;

  int _matchedResidents = 0;
  int _matchedDrivers = 0;
  double _issueReportingRate = 0.0;
  double _prevIssueReportingRate = 0.0;
  String? _issueReportingTrendText;
  bool _issueReportingTrendPositive = true;

  int _missedPickupsCount = 0;
  int _missedPickupsPending = 0;
  int _missedPickupsResolved = 0;
  int _prevMissedPickupsCount = 0;
  String? _missedPickupsTrendText;
  bool _missedPickupsTrendPositive = true;

  double _issueRate = 0.0;
  String? _coverageTrend;
  bool _coverageTrendPositive = true;
  String? _issueTrend;
  bool _issueTrendPositive = true;

  String get _dateRangeDisplayStr => _isDateRange
      ? "${DateFormat('MMM dd').format(_selectedDateRange.start)} - ${DateFormat('MMM dd').format(_selectedDateRange.end)}"
      : DateFormat('MMM dd, yyyy').format(_selectedDateRange.start);

  StreamSubscription? _trucksSubscription;
  Timer? _fleetAgingTimer;
  StreamSubscription? _routesSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription? _weeklyProgressSubscription;
  StreamSubscription? _truckIssuesSubscription;
  StreamSubscription? _truckRegistrySubscription;
  StreamSubscription? _residentComplaintsFbSubscription;

  // Cache for raw data
  Map _allDriverRoutes = {};
  Map _allCollectionProgress = {};
  Map _allWeeklyCollectionProgress = {};
  Map _allTruckLocations = {};
  Map _truckRegistry = {};
  List<dynamic> _allResidentComplaints = [];
  List<dynamic> _allDriverIssues = [];
  List<dynamic> _allFirebaseComplaints = [];

  // AI Insights & ETA Performance variables
  String? _geminiSummary;
  int _forecastSamples = 0; // recorded collection weights behind the volume forecast
  double _tomorrowWaste = 5000.0;
  double _weeklyWaste = 15000.0;
  double _totalFleetCapacity = 5000.0;
  String _selectedTruckSummary = "GT-007";
  String _selectedPeriodSummary = "All time";
  bool _showLoadHistorySection = true;

  // Load History & Waste Summary State
  bool _isLoadingLoadData = false;
  String? _loadError; // set when the data could not be loaded (never shown as "0 trips")
  bool _loadPartial = false; // some sources failed: totals may be incomplete
  bool _loadHasLoaded = false; // at least one load finished
  int _loadOngoingCount = 0; // unfinished, recent activity
  int _loadStaleCount = 0; // unfinished, old or no recorded start (abandoned/legacy)
  int _loadLegacyCount = 0; // counted loads without a recorded FULL event
  int _loadUnattributedCount = 0; // loads with no recorded area (not matched by the area filter)
  int _loadUnfinishedCount = 0; // seen but not counted (collection not finalized)
  int _lastFinalizedRouteCount = -1;
  Timer? _loadRefreshDebounce;
  final LoadHistoryRepository _loadRepository = LoadHistoryRepository.standard();
  int _loadTripsCount = 0;
  double _loadTotalWeightKg = 0.0;
  double _loadTotalWeightTons = 0.0;
  int _loadDaysSelected = 30;
  int _loadSelectedYear = DateTime.now().year;
  int _loadEstimatedCount = 0;
  int _loadMeasuredCount = 0;
  List<DriverTrip> _loadTrips = [];
  List<Map<String, dynamic>> _loadYearlyMonths = [];
  String _loadAiSummary = "";
  bool _loadAiIsAi = false; // true only when the server returned a Gemini-written sentence, not its built-in one
  bool _isLoadAiLoading = false;
  double _measuredTodayVolume = 4200.0;
  double _measuredMonthlyVolume = 38600.0;
  /// Every ETA visit evaluated from the persisted notifications (one authoritative dataset).
  /// The card and the ETA Performance details both derive from it with the same filter.
  List<EtaVisit> _etaVisits = [];
  bool _etaLoaded = false;
  // Recommendations and insights are derived deterministically from the dashboard metrics
  // for the selected period and area (see the getters near _generateRuleBasedRecommendations).
  bool _isAiLoading = false;

  bool _expCoverageRoutes = true;
  bool _expCommunityIssues = false;
  bool _expFleetPrediction = false;
  bool _expAreaBreakdown = false;
  bool _expDataNotes = false;

  final _purokNames = [
    'Ayala Highway',
    'Brixton Homes',
    'Central (Purok 1)',
    'Purok 2',
    'Purok 3',
    'Purok 4 / El Pueblo',
    'Purok Paraiso',
    'Riverside',
    'San Nicolas',
    'T.M. Kalaw Street',
  ];

  StreamSubscription? _etaNotifSubscription;

  @override
  void initState() {
    super.initState();
    _refreshRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _fetchChartData();
    refreshAllData();
    _fetchLoadHistoryData();
    _listenToFirebaseEtaNotifications();
    _scrollController.addListener(() {
      if (_scrollController.offset <= 0 && !_showHeaderShadow) {
        setState(() => _showHeaderShadow = true);
      } else if (_scrollController.offset > 0 && _showHeaderShadow) {
        setState(() => _showHeaderShadow = false);
      }
    });
  }

  @override
  void dispose() {
    _visitDebounce?.cancel();
    _refreshRotationController.dispose();
    _scrollController.dispose();
    _trucksSubscription?.cancel();
    _fleetAgingTimer?.cancel();
    _loadRefreshDebounce?.cancel();
    _routesSubscription?.cancel();
    _progressSubscription?.cancel();
    _truckIssuesSubscription?.cancel();
    _truckRegistrySubscription?.cancel();
    _residentComplaintsFbSubscription?.cancel();
    _etaNotifSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshAllStats({bool manual = false}) async {
    if (_isRefreshing) return;
    
    if (mounted) {
      setState(() {
        _isRefreshing = true;
        _showRefreshSpinner = manual;
        _manualPullDepth = manual ? 80.0 : 0.0; // Stick at 80 if manual
      });
    }
    _refreshRotationController.repeat();

    await Future.wait([
      _calculateAnalytics(),
      _generateAiInsights(),
      _fetchLoadHistoryData(),
      Future.delayed(const Duration(milliseconds: 1500)),
    ]);

    _fetchChartData();
    _recalculateRoutesMetrics();

    if (manual) {
      // Hold and keep spinning for 2 seconds after data is loaded for visual confirmation
      await Future.delayed(const Duration(seconds: 2));
    }

    if (mounted) {
      setState(() {
        _isRefreshing = false;
      });
      // Delay setting _showRefreshSpinner to false to allow retreat animation
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        setState(() {
          _showRefreshSpinner = false;
          _manualPullDepth = 0.0;
        });
      }
      _refreshRotationController.stop();

      if (manual) {
        showDialog(
          context: context,
          barrierColor: Colors.black.withOpacity(0.1),
          barrierDismissible: false,
          builder: (context) {
            // Close THIS dialog only, and only while it is still open: a plain pop could close the page
            // underneath (e.g. the admin dashboard) when the dialog was already dismissed.
            final ModalRoute<dynamic>? autoRoute = ModalRoute.of(context);
            final NavigatorState autoNav = Navigator.of(context);
            Future.delayed(const Duration(milliseconds: 1500), () {
              if (autoRoute != null && autoRoute.isActive) autoNav.removeRoute(autoRoute);
            });
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 15, offset: const Offset(0, 5))
                  ],
                ),
                child: const Material(
                  color: Colors.transparent,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded, color: Colors.green, size: 20),
                      SizedBox(width: 12),
                      Text(
                        "Analytics metrics synchronized",
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A)),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }
    }
  }

  Future<void> refreshAllData() async {
    await _refreshAllStats(manual: false);
  }

  void _processComplaintsAndIssues() {
    final Map<String, int> purokCounts = {};

    // 1. RAW DATA GATHERING & NORMALIZATION
    // This follows the suggestion to use a unified model in-memory
    final List<Map<String, dynamic>> normalizedItems = [];

    String normalizeStatus(dynamic s) {
      if (s == null) return 'Pending';
      String str = s.toString().toUpperCase().trim().replaceAll('_', ' ');
      if (str == 'PENDING' || str == 'SUBMITTED' || str == '0') return 'Pending';
      if (str == 'IN PROGRESS' || str == 'UNDER REVIEW' || str.contains('PROGRESS') || str == '1') return 'In Progress';
      if (str == 'RESOLVED' || str == 'COMPLETED' || str == '2') return 'Resolved';
      return 'Pending';
    }

    DateTime? parseAnyDate(dynamic raw) {
      if (raw == null) return null;
      String s = raw.toString();
      if (s.contains('-')) {
        try {
          if (s.length >= 10) return DateTime.parse(s.substring(0, 10));
        } catch (_) {}
        try {
          return DateFormat('dd-MM-yyyy').parse(s.substring(0, 10));
        } catch (_) {}
      }
      int? ts = int.tryParse(s);
      if (ts != null) {
        if (ts < 10000000000) ts *= 1000;
        return DateTime.fromMillisecondsSinceEpoch(ts);
      }
      return null;
    }

    // Add Resident Complaints (from API/MySQL)
    for (var c in _allResidentComplaints) {
      if (ComplaintArchive.isArchived(c)) continue; // test or invalid records, kept but not counted
      DateTime? dt = parseAnyDate(c['created_at'] ?? c['timestamp'] ?? c['date']);
      if (dt != null) {
        String category = (c['category'] ?? c['type'] ?? c['issue_type'] ?? '').toString();
        bool isUncollectedGarbage = category.isEmpty ||
            category.toLowerCase().contains('uncollected') ||
            category.toLowerCase().contains('missed') ||
            category.toLowerCase().contains('pickup');

        normalizedItems.add({
          'id': c['id']?.toString() ?? '',
          'source': 'RESIDENT',
          'category': category,
          'isUncollectedGarbage': isUncollectedGarbage,
          'status': normalizeStatus(c['status']),
          'createdAt': dt,
          'purok': c['purok']?.toString() ?? c['location']?.toString(),
        });
      }
    }

    // Add Driver Issues (from Firebase truck_issues)
    for (var i in _allDriverIssues) {
      DateTime? dt = parseAnyDate(i['createdAt'] ?? i['timestamp']);
      if (dt != null) {
        normalizedItems.add({
          'id': i['id']?.toString() ?? '',
          'source': 'DRIVER',
          'category': 'Truck Issue',
          'isUncollectedGarbage': false,
          'status': normalizeStatus(i['status']),
          'createdAt': dt,
          'purok': i['purok']?.toString(),
        });
      }
    }

    // 2. FILTERING
    final String startDayStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final String endDayStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);

    int matchedResidents = 0;
    int residentPending = 0;
    int residentResolved = 0;
    int matchedDrivers = 0;
    int residentTotalAll = 0;
    int residentUnresolvedAll = 0;
    // Resident complaints only: driver truck issues are not complaints and are counted separately.
    final Map<String, double> filteredStatusCounts = {"Pending": 0, "In Progress": 0, "Resolved": 0};

    for (var item in normalizedItems) {
      // 1. Date Filtering
      DateTime dt = item['createdAt'] as DateTime;
      String itemDayStr = DateFormat('yyyy-MM-dd').format(dt);
      bool dateMatch = itemDayStr.compareTo(startDayStr) >= 0 && itemDayStr.compareTo(endDayStr) <= 0;
      if (!dateMatch) continue;

      // 2. Area Filtering & Canonicalization
      String? rawPurok = item['purok'];
      String? canonicalPurok = ServiceAreaService.canonicalizeAreaName(rawPurok) ?? rawPurok;

      bool areaMatch = _selectedArea == "All Areas" ||
          (canonicalPurok != null && canonicalPurok.toLowerCase().trim() == _selectedArea.toLowerCase().trim()) ||
          (rawPurok != null && rawPurok.toLowerCase().trim() == _selectedArea.toLowerCase().trim());
      
      if (!areaMatch) continue;

      // 3. Update Counts for Chart & Statistics
      String status = item['status'] as String;
      if (item['source'] == 'RESIDENT') filteredStatusCounts[status] = filteredStatusCounts[status]! + 1;

      if (item['source'] == 'RESIDENT') {
        if (item['isUncollectedGarbage'] == true) {
          matchedResidents++;
          if (status == 'Resolved') {
            residentResolved++;
          } else {
            residentPending++;
          }
        }
      } else {
        matchedDrivers++;
      }

      // Complaints by area count RESIDENT complaints only (MySQL). Driver truck issues are not
      // resident complaints and are reported separately (canonical names, e.g. Dos Riles -> Purok 3).
      if (item['source'] == 'RESIDENT') {
        residentTotalAll++;
        if (status != 'Resolved') residentUnresolvedAll++;
        final String targetPurokKey = canonicalPurok ?? rawPurok ?? "Unknown";
        purokCounts[targetPurokKey] = (purokCounts[targetPurokKey] ?? 0) + 1;
      }
    }

    if (mounted) {
      setState(() {
        // Use REAL FILTERED counts for the visual chart and legend
        _complaintStatusData = filteredStatusCounts;

        // Use REAL FILTERED counts for the info text breakdown
        _complaintSourceData = {"Residents": residentTotalAll.toDouble(), "Drivers": matchedDrivers.toDouble()};
        _purokComplaintData = purokCounts;
        _residentComplaintsTotal = residentTotalAll;
        _residentComplaintsUnresolved = residentUnresolvedAll;

        _matchedResidents = matchedResidents;
        _matchedDrivers = matchedDrivers;

        final int totalFilteredIssues = (matchedResidents + matchedDrivers);
        _issueRate = _completedRoutes > 0 ? (totalFilteredIssues / _completedRoutes) * 100 : 0.0;
        _issueReportingRate = _issueRate;

        final DateTimeRange prevRange = _getPreviousPeriod(_selectedDateRange, _isDateRange);
        final Map<String, dynamic> prevMetrics = _calculateMetricsInRange(prevRange.start, prevRange.end, _selectedArea);
        int prevCompleted = prevMetrics['completed'] as int? ?? 0;

        // Calculate prev resident uncollected garbage reports
        int prevResidentCount = 0;
        final startStr = DateFormat('yyyy-MM-dd').format(prevRange.start);
        final endStr = DateFormat('yyyy-MM-dd').format(prevRange.end);
        for (var c in _allResidentComplaints) {
          if (ComplaintArchive.isArchived(c)) continue;
          DateTime? dt = parseAnyDate(c['created_at'] ?? c['timestamp'] ?? c['date']);
          if (dt != null) {
            String itemDayStr = DateFormat('yyyy-MM-dd').format(dt);
            if (itemDayStr.compareTo(startStr) >= 0 && itemDayStr.compareTo(endStr) <= 0) {
              String? rawPurok = c['purok']?.toString() ?? c['location']?.toString();
              String? canonicalPurok = ServiceAreaService.canonicalizeAreaName(rawPurok) ?? rawPurok;
              bool areaMatch = _selectedArea == "All Areas" ||
                  (canonicalPurok != null && canonicalPurok.toLowerCase().trim() == _selectedArea.toLowerCase().trim()) ||
                  (rawPurok != null && rawPurok.toLowerCase().trim() == _selectedArea.toLowerCase().trim());
              String category = (c['category'] ?? c['type'] ?? c['issue_type'] ?? '').toString();
              bool isUncollectedGarbage = category.isEmpty ||
                  category.toLowerCase().contains('uncollected') ||
                  category.toLowerCase().contains('missed') ||
                  category.toLowerCase().contains('pickup');
              if (areaMatch && isUncollectedGarbage) prevResidentCount++;
            }
          }
        }

        _missedPickupsCount = matchedResidents;
        _missedPickupsPending = residentPending;
        _missedPickupsResolved = residentResolved;
        _prevMissedPickupsCount = prevResidentCount;

        int missedDiff = _missedPickupsCount - prevResidentCount;
        if (prevResidentCount > 0 || _missedPickupsCount > 0) {
          if (missedDiff == 0) {
            _missedPickupsTrendText = "No change vs previous";
            _missedPickupsTrendPositive = true;
          } else if (missedDiff < 0) {
            _missedPickupsTrendText = "${missedDiff.abs()} fewer vs previous";
            _missedPickupsTrendPositive = true;
          } else {
            _missedPickupsTrendText = "+${missedDiff.abs()} vs previous";
            _missedPickupsTrendPositive = false;
          }
        } else {
          _missedPickupsTrendText = "N/A";
        }

        double prevIssueRate = prevCompleted > 0 ? (prevResidentCount / prevCompleted) * 100 : 0.0;
        _prevIssueReportingRate = prevIssueRate;
        double issueDiff = _issueReportingRate - prevIssueRate;

        if (prevCompleted > 0 || _completedRoutes > 0) {
          if (issueDiff == 0) {
            _issueReportingTrendText = "No change vs previous";
            _issueReportingTrendPositive = true;
          } else if (issueDiff < 0) {
            _issueReportingTrendText = "${issueDiff.abs().toStringAsFixed(0)} fewer per 100 vs previous";
            _issueReportingTrendPositive = true;
          } else {
            _issueReportingTrendText = "${issueDiff.abs().toStringAsFixed(0)} more per 100 vs previous";
            _issueReportingTrendPositive = false;
          }
        } else {
          _issueReportingTrendText = "N/A";
        }
        _issueTrend = _missedPickupsTrendText;
        _issueTrendPositive = _missedPickupsTrendPositive;
      });
    }

    debugPrint("ANALYTICS AGGREGATION DEBUG:");
    debugPrint("- Total Raw Items: ${normalizedItems.length} (Res: ${_allResidentComplaints.length}, Drv: ${_allDriverIssues.length})");
    debugPrint("- Matched Date & Area: ${matchedResidents + matchedDrivers} (Res: $matchedResidents, Drv: $matchedDrivers)");
    debugPrint("- Status Distribution: $filteredStatusCounts");
  }

  /// Collection areas the trucks serve in the current area selection (sweeping areas excluded).
  List<String> get _expectedVisitAreas {
    final bool all = _selectedArea == "All Areas";
    return _geofences
        .where((AreaGeofence g) => g.isTruckStop && (all || g.name == _selectedArea))
        .map((AreaGeofence g) => g.name)
        .toSet()
        .toList();
  }

  int get _coverageScaleMax {
    int m = 0;
    for (final String a in _purokNames) {
      m = math.max(m, _purokFrequencyData[a] ?? 0);
      m = math.max(m, _purokComplaintData[a] ?? 0);
    }
    return m <= 4 ? 4 : ((m + 1) ~/ 2) * 2;
  }

  int get _areasVisitedCount {
    final Map<String, int> c = _visitSummary?.countByArea() ?? const <String, int>{};
    return _expectedVisitAreas.where((String a) => (c[a] ?? 0) > 0).length;
  }

  /// "42 min" / "1.6 h" / "n/a", from the median collection duration.
  String get _collectionTimeText {
    if (_avgCollectionTime <= 0) return "n/a";
    final double m = _avgCollectionTime * 60;
    return m < 90 ? "${m.round()} min" : "${_avgCollectionTime.toStringAsFixed(1)} h";
  }

  String get _periodLabel => _isDateRange
      ? "${DateFormat('yyyy-MM-dd').format(_selectedDateRange.start)} to ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.end)}"
      : DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);

  /// Everything the narrative blocks need, from the figures this screen already shows for the same area and period.
  /// [combined]: complaint counts include driver truck issues (the operational blocks), not just resident complaints.
  NarrativeInput _narrativeInput({bool combined = true}) {
    final VisitSummary? v = _visitSummary;
    final List<String> expected = _expectedVisitAreas;
    final Map<String, int> counts = v?.countByArea() ?? const <String, int>{};
    final int visited = expected.where((String a) => (counts[a] ?? 0) > 0).length;
    final DateTime now = DateTime.now();
    final bool includesToday = !_selectedDateRange.end.isBefore(DateTime(now.year, now.month, now.day));
    final int unresolvedResident = _residentComplaintsUnresolved;
    return NarrativeInput(
      area: _selectedArea,
      periodLabel: _periodLabel,
      periodIncludesToday: includesToday,
      loadTrips: _loadError == null ? _loadTripsCount : 0,
      measuredLoads: _loadError == null ? _loadMeasuredCount : 0,
      pending: combined ? (_complaintStatusData['Pending'] ?? 0).toInt() : unresolvedResident,
      inProgress: combined ? (_complaintStatusData['In Progress'] ?? 0).toInt() : 0,
      resolved: combined ? (_complaintStatusData['Resolved'] ?? 0).toInt() : (_residentComplaintsTotal - unresolvedResident),
      expectedAreas: expected.length,
      visitedAreas: visited,
      verifiedVisits: v?.visits.length ?? 0,
      tripsConsidered: v?.tripsConsidered ?? 0,
      tripsWithoutEvidence: v?.tripsWithoutEvidence ?? 0,
      collectionDataAvailable: v != null && _loadError == null,
      complaintNoun: combined ? 'complaint/issue' : 'resident complaint',
      complaintNounPlural: combined ? 'complaints/issues' : 'resident complaints',
    );
  }

  List<Recommendation> _buildRecommendations() {
    final VisitSummary? v = _visitSummary;
    return AnalyticsRecommendations.build(RecommendationInput(
      periodLabel: _periodLabel,
      area: _selectedArea,
      residentComplaintsByArea: _purokComplaintData,
      pendingResidentComplaints: _residentComplaintsUnresolved,
      totalResidentComplaints: _residentComplaintsTotal,
      visitsByArea: v?.countByArea() ?? const <String, int>{},
      truckStopAreas: _expectedVisitAreas,
      unconfirmedPasses: v?.unconfirmedPasses ?? const <String, int>{},
      tripsConsidered: v?.tripsConsidered ?? 0,
      tripsWithoutEvidence: v?.tripsWithoutEvidence ?? 0,
      completedTrips: _loadError == null ? _loadTripsCount : 0,
      measuredWeightTrips: _loadError == null ? _loadMeasuredCount : 0,
      collectionDataAvailable: v != null,
    ));
  }

  String _generateRuleBasedRecommendations() => AnalyticsRecommendations.asText(_buildRecommendations());

  String get _recommendations => _generateRuleBasedRecommendations();

  String get _fleetInsight {
    final int active = (_truckStatusData['Active'] ?? 0).toInt();
    final int idle = (_truckStatusData['Idle'] ?? 0).toInt();
    final int full = (_truckStatusData['Full'] ?? 0).toInt();
    return "Current snapshot: $active collecting, $full full and $idle not collecting (paused, offline or completed) "
        "of ${active + idle + full} registered truck(s). This is live status, not a figure for the selected period.";
  }

  String get _complaintInsight {
    if (_residentComplaintsTotal == 0) {
      return "No resident complaints were filed in $_selectedArea for $_periodLabel. This does not measure resident satisfaction.";
    }
    return "$_residentComplaintsTotal resident complaint(s) were filed in $_selectedArea for $_periodLabel: "
        "$_residentComplaintsUnresolved unresolved and ${_residentComplaintsTotal - _residentComplaintsUnresolved} resolved.";
  }

  String get _coverageInsight {
    final VisitSummary? v = _visitSummary;
    if (v == null) return "Collection visits are still loading.";
    final List<String> expected = _expectedVisitAreas;
    final int visited = expected.where((String a) => (v.countByArea()[a] ?? 0) > 0).length;
    final StringBuffer b = StringBuffer(
        "${v.visits.length} verified collection visit(s) across $visited of ${expected.length} collection area(s).");
    if (v.tripsWithoutEvidence > 0) {
      b.write(" ${v.tripsWithoutEvidence} of ${v.tripsConsidered} trip(s) had no usable GPS points, so their visits cannot be verified.");
    }
    return b.toString();
  }

  /// Volume forecast from RECORDED collection weights only (no AI call). The forecast is
  /// unavailable when no weights were recorded; it is never validated, so no accuracy or
  /// confidence is claimed.
  ///
  /// The previous client-side Gemini call (with an API key embedded in the app) was removed:
  /// a key in Flutter Web is public. AI-written text needs a server-side proxy (pending approval).
  Future<void> _generateAiInsights() async {
    if (!mounted) return;
    final String topArea = _selectedArea;

    double totalRecordedKg = 0.0;
    int validSessions = 0;
    _allCollectionProgress.forEach((sId, progress) {
      if (progress is Map) {
        progress.forEach((purokKey, purokData) {
          if (purokData is Map) {
            final rawName = purokData['name']?.toString() ?? purokKey.toString();
            final String canonical = ServiceAreaService.canonicalizeAreaName(rawName) ?? rawName;
            if (topArea == "All Areas" || canonical == topArea) {
              final num? weight = num.tryParse(purokData['weight']?.toString() ?? '') ??
                  num.tryParse(purokData['volume']?.toString() ?? '') ??
                  num.tryParse(purokData['actual_weight']?.toString() ?? '');
              if (weight != null && weight > 0) {
                totalRecordedKg += weight.toDouble();
                validSessions++;
              }
            }
          }
        });
      }
    });
    final double? histAvgKg = validSessions > 0 ? (totalRecordedKg / validSessions) : null;

    if (mounted) {
      setState(() {
        _forecastSamples = validSessions;
        if (histAvgKg != null) {
          _tomorrowWaste = PredictionEngine.predictWasteVolume(topArea, stopCount: _stopsPerRoute, historicalAvgKg: histAvgKg);
          _weeklyWaste = PredictionEngine.predictWeeklyVolume(topArea, avgStops: _stopsPerRoute, historicalAvgKg: histAvgKg);
        } else {
          _tomorrowWaste = 0;
          _weeklyWaste = 0;
        }
        _geminiSummary = null;
        _isAiLoading = false;
      });
    }
  }

  Future<void> _exportReport(String category, String format) async {
    if (format.contains('PDF')) {
      _showPdfConfirmationDialog(category);
      return;
    }

    // Built on the device from the same snapshot as the PDF, so the spreadsheet matches the
    // dashboard; a real .xlsx (opens in Excel, Google Sheets and phone viewers).
    CustomNotification.showTopNotification(context, "Generating Excel report...", false);
    try {
      await _fetchLoadHistoryData();
      final AnalyticsReportData data = _collectReportData();
      final ReportCategory kind = ReportCategoryLabel.parse(category);
      final Uint8List bytes = AnalyticsXlsxBuilder.build(data, kind);
      final bool ok = await ReportFileSaver.save(
        bytes,
        AnalyticsXlsxBuilder.fileName(data, kind),
        ReportFileSaver.xlsxMime,
        subject: '${kind.label} - $_selectedArea',
      );
      if (!ok) throw StateError('the file could not be handed to the device');
      await SystemLogger.logEvent("EXPORT", "Exported Excel report for $_selectedArea");
      if (mounted && kIsWeb) {
        _showSuccessDialog(context, "Excel Report Downloaded",
            "${ReportCategoryLabel.parse(category).label} for $_selectedArea was saved to your Downloads folder.");
      }
    } catch (e) {
      debugPrint("Excel export error: $e");
      if (mounted) {
        CustomNotification.showTopNotification(context, "The Excel report could not be generated.", true);
      }
    }
  }

  void _showSuccessDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, fontSize: 14)),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00897B),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: const Text("CLOSE", style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPdfConfirmationDialog(String category) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: 450,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Confirm PDF Generation",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
              const SizedBox(height: 12),
              Text("You are about to generate a detailed analytics report for $_selectedArea.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, fontSize: 14)),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.grey),
                        minimumSize: const Size(0, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("CANCEL", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _exportToNativePdf(category);
                        CustomNotification.showTopNotification(context, "Generating PDF report...", false);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00897B),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text("GENERATE", style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Snapshot of exactly what the dashboard shows for the selected range and area. The PDF only
  /// formats this object, so the report cannot disagree with itself or with the dashboard.
  AnalyticsReportData _collectReportData() {
    final DateTime nowManila = LoadHistory.manila(DateTime.now());
    final ReportMeta meta = ReportMeta(
      start: _selectedDateRange.start,
      end: _selectedDateRange.end,
      area: _selectedArea,
      generatedAtManila: nowManila,
    );

    // Fleet: same live definition as the dashboard (FleetSnapshot), registered trucks only.
    ReportFleet fleet;
    if (_truckRegistry.isEmpty) {
      fleet = const ReportFleet.unavailable('the truck registry has not loaded');
    } else {
      final FleetSnapshot snap = FleetSnapshot.derive(_allTruckLocations, includeCompleted: true);
      final Map<String, LiveTruck> live = <String, LiveTruck>{for (final LiveTruck t in snap.trucks) t.nodeKey: t};
      final Map<String, int> counts = <String, int>{'Active': 0, 'Paused': 0, 'Full': 0, 'Completed': 0, 'Offline': 0};
      _truckRegistry.forEach((Object? id, Object? _) {
        final LiveTruck? t = live[id.toString()];
        if (t == null) {
          counts['Offline'] = counts['Offline']! + 1;
        } else if (t.isCompleted) {
          counts['Completed'] = counts['Completed']! + 1;
        } else {
          final String st = FleetStatus.collectionState(t.node);
          if (st == 'FULL') {
            counts['Full'] = counts['Full']! + 1;
          } else if (st.contains('IDLE') || st.contains('PAUSED')) {
            counts['Paused'] = counts['Paused']! + 1;
          } else {
            counts['Active'] = counts['Active']! + 1;
          }
        }
      });
      fleet = ReportFleet.available(counts);
    }

    // Waste / load history: the same period loads the Waste Collection Summary card uses.
    ReportWaste waste;
    if (_loadError != null) {
      waste = const ReportWaste.unavailable('collection data could not be loaded');
    } else if (!_loadHasLoaded) {
      waste = const ReportWaste.unavailable('collection data has not finished loading');
    } else {
      waste = ReportWaste.available(
        rows: _timedFirst(_loadTrips
            .map((DriverTrip t) => ReportLoadRow(
                  tripId: t.tripId,
                  driver: t.driverName,
                  truck: t.truckId,
                  fullAtManila: LoadHistory.manila(LoadHistory.eventTime(t)),
                  kg: t.weightKg,
                  measured: t.isMeasured,
                  status: t.routeStatus,
                  // No FULL/end time, no GPS point and a start time of "now": nothing was recorded.
                  timeRecorded: !(t.fullTime == null &&
                      t.endTime == null &&
                      t.points.isEmpty &&
                      DateTime.now().difference(t.startTime).inMinutes.abs() < 10),
                ))
            .toList()),
        partial: _loadPartial,
        ongoingUnfinished: _loadOngoingCount,
        staleUnfinished: _loadStaleCount,
      );
    }

    // Coverage: the same verified visits as the Purok Coverage chart and the Areas visited card.
    ReportCoverage coverage;
    final VisitSummary? vs = _visitSummary;
    if (vs == null) {
      coverage = const ReportCoverage.unavailable('collection visits have not loaded');
    } else {
      final Map<String, int> counts = vs.countByArea();
      final List<String> expected = _expectedVisitAreas;
      coverage = ReportCoverage.available(
        rows: <ReportCoverageRow>[
          for (final String area in expected)
            ReportCoverageRow(area: area, visits: counts[area] ?? 0, unconfirmed: vs.unconfirmedPasses[area] ?? 0),
        ],
        areasVisited: _areasVisitedCount,
        expectedAreas: expected.length,
        tripsWithoutEvidence: vs.tripsWithoutEvidence,
      );
    }

    // ETA: the same filtered visits and summary as the ETA card and its details.
    ReportEta eta;
    if (!_etaLoaded) {
      eta = const ReportEta.unavailable('ETA notifications have not loaded');
    } else {
      final List<EtaVisit> visits = _etaFilteredVisits;
      final EtaSummary es = EtaEvaluation.summarize(visits);
      String label(EtaVisit v) {
        switch (v.status) {
          case EtaVisitStatus.evaluated:
            return 'Evaluated';
          case EtaVisitStatus.awaiting:
            return 'Awaiting arrival';
          case EtaVisitStatus.noArrival:
            return 'No arrival recorded';
          case EtaVisitStatus.withdrawn:
            return 'Withdrawn';
          case EtaVisitStatus.noEstimate:
            return 'No ETA stated';
        }
      }
      eta = ReportEta.available(
        rows: visits
            .map((EtaVisit v) => ReportEtaRow(
                  area: v.area,
                  truck: v.truckId,
                  tripId: v.tripId ?? 'not recorded',
                  sentAt: EtaEvaluation.manila(v.sentMs),
                  etaMinutes: v.predictedMinutes,
                  predictedAt: v.predictedArrivalMs == null ? null : EtaEvaluation.manila(v.predictedArrivalMs!),
                  actualAt: v.arrivalMs == null ? null : EtaEvaluation.manila(v.arrivalMs!),
                  signedErrorMin: v.signedErrorMin,
                  status: label(v),
                ))
            .toList(),
        evaluated: es.evaluatedVisits,
        awaiting: es.awaitingVisits,
        noArrival: es.noArrivalVisits,
        withdrawn: es.withdrawnVisits,
        noEstimate: es.noEstimateVisits,
        avgAbsErrorMin: es.avgAbsErrorMin,
        within5Pct: es.within5Pct,
        totalVisits: es.visits,
      );
    }

    final ReportComplaints complaints = ReportComplaints.available(
      counts: <String, int>{
        'Pending': (_complaintStatusData['Pending'] ?? 0).toInt(),
        'In Progress': (_complaintStatusData['In Progress'] ?? 0).toInt(),
        'Resolved': (_complaintStatusData['Resolved'] ?? 0).toInt(),
      },
      byArea: Map<String, int>.from(_purokComplaintData),
    );

    // A volume forecast only exists when it is derived from recorded collection weights.
    final ReportForecast forecast = _forecastSamples > 0
        ? ReportForecast.available(tomorrowKg: _tomorrowWaste, weeklyKg: _weeklyWaste, samples: _forecastSamples)
        : const ReportForecast.unavailable('no recorded collection weights exist to base a forecast on');

    return AnalyticsReportData(
      meta: meta,
      fleet: fleet,
      waste: waste,
      coverage: coverage,
      eta: eta,
      complaints: complaints,
      forecast: forecast,
      aiNarrative: _geminiSummary ?? (_loadAiIsAi && _loadAiSummary.trim().isNotEmpty ? _loadAiSummary.trim() : null),
      operations: ReportOperations(
        distanceKm: _distanceCovered > 0 ? _distanceCovered : null,
        stopsPerRoute: _stopsPerRoute > 0 ? _stopsPerRoute : null,
        avgCollectionHours: _avgCollectionTime > 0 ? _avgCollectionTime : null,
        missedPickups: _missedPickupsCount,
        missedPending: _missedPickupsPending,
        missedResolved: _missedPickupsResolved,
      ),
      assignments: _reportAssignments(),
      predictive: _reportPredictive(),
    );
  }

  /// Trips with no recorded time have no place in a newest-first list: they go last (order kept).
  static List<ReportLoadRow> _timedFirst(List<ReportLoadRow> rows) => <ReportLoadRow>[
        ...rows.where((ReportLoadRow r) => r.timeRecorded),
        ...rows.where((ReportLoadRow r) => !r.timeRecorded),
      ];

  /// Scheduled routes with the same rules as the Scheduled Routes card.
  ReportAssignments _reportAssignments() {
    final AssignmentList? data = _assignments;
    if (data == null || _assignmentFailure != AssignmentFailure.none) {
      return ReportAssignments.unavailable(_assignmentMessage ?? 'route assignments are not available');
    }
    final List<RouteAssignment> items =
        data.items.where((RouteAssignment a) => AssignedAreaCoverage.includesArea(a, _selectedArea)).toList();
    final AssignmentSummary s = AssignmentSummary.fromItems(items, data.today);
    final Map<String, Set<String>> visitedByTrip = <String, Set<String>>{};
    for (final CollectionVisit x in _visitSummary?.visits ?? const <CollectionVisit>[]) {
      (visitedByTrip[x.tripId] ??= <String>{}).add(x.area);
    }
    final AssignedAreaCoverage cov = AssignedAreaCoverage.compute(items, visitedByTrip, areaFilter: _selectedArea);
    return ReportAssignments.available(
      total: s.total,
      pending: s.pending,
      inProgress: s.inProgress,
      completed: s.completed,
      missed: s.missed,
      cancelled: s.cancelled,
      due: s.due,
      completionRate: s.completionRate,
      assignedAreas: cov.assignedAreas,
      verifiedAreas: cov.verifiedAreas,
    );
  }

  /// Objective 3 figures, computed exactly as the Predictive Models card computes them.
  ReportPredictive _reportPredictive() {
    try {
      final ArrivalRegressionReport reg = ArrivalRegression.evaluate(ArrivalRegression.extract(_allDriverRoutes, _geofences));
      final ({List<DateTime> days, List<double> kg}) daily =
          MovingAverageForecast.dailyLoadsFrom(_loadTrips, from: _selectedDateRange.start, to: _selectedDateRange.end);
      final MovingAverageReport ma = MovingAverageForecast.evaluate(daily.days, daily.kg);
      final List<double> act = <double>[], pred = <double>[];
      for (final EtaVisit v in _etaFilteredVisits) {
        if (v.status != EtaVisitStatus.evaluated || v.predictions.isEmpty) continue;
        final EtaPrediction p = v.predictions.first;
        if (p.predictedMinutes == null || p.signedErrorMin == null) continue;
        pred.add(p.predictedMinutes!.toDouble());
        act.add(p.predictedMinutes! + p.signedErrorMin!);
      }
      final ErrorMetrics live = ErrorMetrics.of(act, pred);
      ReportModelMetric m(String label, ErrorMetrics e, String unit) =>
          ReportModelMetric(label: label, n: e.n, mae: e.mae, rmse: e.rmse, r2: e.r2, unit: unit);
      final int k = ma.backtestActual.length;
      final int from = k > 14 ? k - 14 : 0;
      final int offset = ma.days.length - k; // backtest covers the last k days
      return ReportPredictive.available(
        samples: reg.samples,
        trips: reg.trips,
        intercept: reg.fit?.intercept,
        slope: reg.fit?.slope,
        method: reg.method,
        metrics: <ReportModelMetric>[
          m('Arrival time: linear regression (test samples)', reg.regression, 'min'),
          m('Arrival time: live rule, distance / recent speed (same samples)', reg.baseline, 'min'),
          m('Arrival time: estimates notified to residents', live, 'min'),
          m('Daily collected load: ${ma.window}-day moving average', ma.metrics, 'kg'),
        ],
        maWindow: ma.window,
        maDays: ma.days.length,
        maNextKg: ma.nextForecast,
        recent: <(DateTime, double, double)>[
          for (int i = from; i < k; i++) (ma.days[offset + i], ma.backtestActual[i], ma.backtestForecast[i]),
        ],
      );
    } catch (e) {
      return ReportPredictive.unavailable('the models could not be computed ($e)');
    }
  }

  Future<void> _exportToNativePdf(String category) async {
    try {
      // Refresh the period loads so the report reflects the selected range right now.
      await _fetchLoadHistoryData();
      final AnalyticsReportData data = _collectReportData();
      final pw.Document pdf = AnalyticsPdfBuilder.build(data);
      final bytes = await pdf.save();
      await Printing.sharePdf(
        bytes: bytes,
        filename: "Analytics_Report_${DateFormat('yyyyMMdd').format(_selectedDateRange.start)}_"
            "${DateFormat('yyyyMMdd').format(_selectedDateRange.end)}.pdf",
      );
      await SystemLogger.logEvent("EXPORT", "Generated PDF Report for $_selectedArea");
    } catch (e) {
      debugPrint("PDF Error: $e");
      if (mounted) {
        CustomNotification.showTopNotification(context, "The PDF report could not be generated.", true);
      }
    }
  }


  /// Operational figures of the selected period, from the recorded trips (driver_routes):
  ///   distance  = sum of the recorded trip distances (simulations excluded)
  ///   avg time  = median collection duration of the trips finalized FULL (start to FULL; a median,
  ///               so one trip left running for hours does not distort it; under 1 minute ignored)
  ///   stops     = average number of areas with a verified visit per trip that visited any area
  /// (The old `collection_logs` node has not been written since August and is no longer read.)
  Future<void> _calculateAnalytics() async {
    final String startStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final String endStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);
    final bool allAreas = _selectedArea == "All Areas";
    double totalDist = 0.0;
    final List<double> durationsMin = <double>[];
    _allDriverRoutes.forEach((key, data) {
      if (data is! Map) return;
      if (data['is_simulation'] == true || data['is_simulation'] == 'true' || TripArchive.isArchived(data)) return;
      final String dateStr = data['date']?.toString() ?? "";
      if (dateStr.compareTo(startStr) < 0 || dateStr.compareTo(endStr) > 0) return;
      if (!allAreas) {
        final String purok = ServiceAreaService.canonicalizeAreaName(data['purok']?.toString()) ?? (data['purok']?.toString() ?? '');
        final bool visited = _visitSummary?.visits.any((CollectionVisit v) => v.tripId == key.toString()) ?? false;
        if (purok != _selectedArea && !visited) return;
      }
      totalDist += double.tryParse((data['final_distance'] ?? data['total_distance'] ?? 0).toString()) ?? 0.0;
      final String rs = (data['route_status'] ?? '').toString().toUpperCase();
      final double? secs = double.tryParse((data['collection_duration_s'] ?? '').toString());
      if ((rs == 'FULL' || rs == 'COMPLETED' || data['collection_finalized'] == true) && secs != null && secs >= 60) {
        durationsMin.add(secs / 60.0);
      }
    });
    durationsMin.sort();
    final double medianMin = durationsMin.isEmpty
        ? 0.0
        : (durationsMin.length.isOdd
            ? durationsMin[durationsMin.length ~/ 2]
            : (durationsMin[durationsMin.length ~/ 2 - 1] + durationsMin[durationsMin.length ~/ 2]) / 2);
    final Map<String, Set<String>> areasByTrip = <String, Set<String>>{};
    for (final CollectionVisit v in _visitSummary?.visits ?? const <CollectionVisit>[]) {
      (areasByTrip[v.tripId] ??= <String>{}).add(v.area);
    }
    final int stops = areasByTrip.isEmpty
        ? 0
        : (areasByTrip.values.fold<int>(0, (int a, Set<String> x) => a + x.length) / areasByTrip.length).round();
    if (mounted) {
      setState(() {
        _avgCollectionTime = medianMin / 60.0; // hours
        _collectionDurationTrips = durationsMin.length;
        _distanceCovered = totalDist;
        _stopsPerRoute = stops;
      });
    }
  }

  Future<void> _fetchLoadHistoryData() async {
    if (!mounted) return;
    setState(() => _isLoadingLoadData = true);

    // The Analytics date range is the authoritative selection for the Waste Collection Summary.
    final DateTime now = DateTime.now();
    final DateTime start = _selectedDateRange.start;
    final DateTime end = _selectedDateRange.end;
    final int calculatedDays = DateTime(end.year, end.month, end.day)
            .difference(DateTime(start.year, start.month, start.day))
            .inDays +
        1;

    final String startStr = DateFormat('yyyy-MM-dd').format(start);
    final String endStr = DateFormat('yyyy-MM-dd').format(end);

    try {
      // ONE repository for every Load History consumer: the Waste Collection Summary,
      // its yearly chart and the Load History dialog all start from this same
      // finalized, de-duplicated list.
      final LoadHistoryResult result = await _loadRepository.load(start: start, end: end);

      if (result.isError) {
        // Every source failed: say so instead of reporting "0 trips".
        if (mounted) {
          setState(() => _loadError = "Collection data could not be loaded. Check the connection and try again.");
        }
      } else {
        _loadSelectedYear = start.year;
        _loadYearlyMonths = LoadHistory.monthly(result.loads, _loadSelectedYear);

        // Date (Asia/Manila FULL day) then area, with the SAME shared functions Load History uses.
        final ({List<DriverTrip> matched, int unattributed}) byArea = LoadHistory.forArea(
          LoadHistory.inRange(result.loads, start, end),
          _selectedArea,
          canonicalize: ServiceAreaService.canonicalizeAreaName,
        );
        final List<DriverTrip> periodTrips = byArea.matched;
        periodTrips.sort((a, b) => LoadHistory.eventTime(b).compareTo(LoadHistory.eventTime(a)));
        final LoadTotals totals = LoadHistory.totals(periodTrips);
        final ({List<DriverTrip> ongoing, List<DriverTrip> stale}) unfinishedSplit =
            LoadHistory.splitUnfinished(LoadHistory.inRange(result.unfinished, start, end), now);
        final int legacyInPeriod = periodTrips.where((DriverTrip t) => !LoadHistory.isGenuineFull(t)).length;

        if (mounted) {
          setState(() {
            _loadError = null;
            _loadPartial = result.isPartial;
            _loadDaysSelected = calculatedDays;
            _loadTrips = periodTrips;
            _loadTripsCount = totals.trips;
            _loadTotalWeightKg = totals.weightKg;
            _loadTotalWeightTons = totals.weightTons;
            _loadMeasuredCount = totals.measuredCount;
            _loadEstimatedCount = totals.estimatedCount;
            _loadUnfinishedCount = unfinishedSplit.ongoing.length + unfinishedSplit.stale.length;
            _loadOngoingCount = unfinishedSplit.ongoing.length;
            _loadStaleCount = unfinishedSplit.stale.length;
            _loadLegacyCount = legacyInPeriod;
            _loadUnattributedCount = byArea.unattributed;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching load history: $e");
      if (mounted) setState(() => _loadError = "Collection data could not be loaded. Please try again.");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingLoadData = false;
          _loadHasLoaded = true;
        });
      }
    }

    _fetchAiLoadSummary(startStr, endStr);
  }

  Future<void> _fetchAiLoadSummary(String? startStr, String? endStr) async {
    if (!mounted) return;
    setState(() => _isLoadAiLoading = true);

    try {
      final response = await _apiService.getAiLoadSummary(
        startDate: startStr,
        endDate: endStr,
      );
      if (response.data != null && response.data['success'] == true) {
        if (mounted) {
          setState(() {
            _loadAiSummary = response.data['summary'] ?? "";
            _loadAiIsAi = response.data['is_ai_generated'] == true;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching AI load summary: $e");
    } finally {
      if (mounted) setState(() => _isLoadAiLoading = false);
    }
  }

  void _showEditWeightDialog(BuildContext context, DriverTrip trip) {
    final TextEditingController ctrl = TextEditingController(
      text: trip.weightKg.toInt().toString(),
    );
    double liveKg = trip.weightKg;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: const [
                Icon(Icons.scale_rounded, color: Color(0xFF0F766E), size: 22),
                SizedBox(width: 8),
                Text("Edit Weight", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF0F172A))),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Enter measured scale reading for ${trip.tripNumber} (${trip.fullDate}):",
                  style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (val) {
                    final parsed = double.tryParse(val.trim());
                    if (parsed != null && parsed >= 0) {
                      setDialogState(() => liveKg = parsed);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: "Measured Weight (kg)",
                    suffixText: "kg",
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF00796B), width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFBBF7D0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF15803D)),
                      const SizedBox(width: 6),
                      Text(
                        "Converted: ${(liveKg / 1000.0).toStringAsFixed(2)} tons",
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF15803D)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel", style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
              ),
              ElevatedButton(
                onPressed: () async {
                  final newKg = double.tryParse(ctrl.text.trim());
                  if (newKg == null || newKg < 0) {
                    CustomSnackBar.show(context, message: "Please enter a valid non-negative weight.", isError: true);
                    return;
                  }
                  Navigator.pop(context);
                  try {
                    final res = await _apiService.updateTripWeight(
                      tripId: trip.tripId,
                      weightKg: newKg,
                    );
                    if (res.data != null && res.data['success'] == true) {
                      CustomNotification.showTopNotification(
                        context,
                        "Weight updated to ${newKg.toInt().toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')} kg (${(newKg / 1000).toStringAsFixed(1)} tons)",
                        false,
                      );
                      await _fetchLoadHistoryData();
                    }
                  } catch (e) {
                    CustomSnackBar.show(context, message: "Failed to update trip weight.", isError: true);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00796B),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text("Save Weight", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  AreaGeofence _toGeofence(ServiceArea a) => AreaGeofence(
        name: ServiceAreaService.canonicalizeAreaName(a.name) ?? a.name,
        lat: a.entranceLat,
        lng: a.entranceLng,
        radiusM: AreaGeofence.areaRadiusM, // the stored boundaries are placeholders; one 100 m circle per area
        isTruckStop: a.isTruckStop && a.verificationStatus.toUpperCase() == 'VERIFIED',
      );

  /// Reads the configured service areas (read-only). Falls back to the documented default
  /// areas only when none can be read, and says so on the chart.
  Future<void> _loadGeofences() async {
    final List<AreaGeofence> list = <AreaGeofence>[];
    try {
      final DataSnapshot snap = await _database.ref('puroks').get().timeout(const Duration(seconds: 10));
      if (snap.exists && snap.value is Map) {
        (snap.value as Map).forEach((k, v) {
          if (v is! Map) return;
          try {
            final Map<String, dynamic> m = Map<String, dynamic>.from(v);
            m['id'] ??= k.toString();
            list.add(_toGeofence(ServiceArea.fromJson(m)));
          } catch (e) {
            debugPrint("[VISITS] Skipping malformed area $k: $e");
          }
        });
      }
    } catch (e) {
      debugPrint("[VISITS] Service areas could not be read: $e");
    }
    final bool defaults = list.isEmpty;
    if (defaults) list.addAll(ServiceAreaService.defaultServiceAreas.map(_toGeofence));
    if (!mounted) return;
    setState(() {
      _geofences = list;
      _geofencesFromDefaults = defaults;
      _applyVisitSummary();
    });
    _etaAreas = list;
    _refreshEtaVisits();
  }

  /// ETA arrivals are the verified (green) visits, so the ETA list is rebuilt whenever the
  /// trips or the areas change, not only when a notification arrives.
  void _refreshEtaVisits() {
    if (_etaRawNotifications == null || !mounted) return;
    setState(() => _etaVisits = _buildEtaVisits(_etaRawNotifications));
  }

  /// Recomputes verified visits for the selected period and area (no setState).
  void _applyVisitSummary() {
    if (_geofences.isEmpty) return;
    final VisitSummary v = CollectionVisits.detect(
      trips: _allDriverRoutes,
      areas: _geofences,
      start: _selectedDateRange.start,
      end: _selectedDateRange.end,
      areaFilter: _selectedArea,
    );
    final Map<String, int> counts = v.countByArea();
    _visitSummary = v;
    _purokFrequencyData = <String, int>{for (final String a in _purokNames) a: counts[a] ?? 0};
    _purokVisitCounts = Map<String, int>.from(_purokFrequencyData);
    Future<void>.microtask(_calculateAnalytics); // stops per route use the visits
  }

  /// driver_routes changes with every GPS point while trucks are out: recompute at most
  /// once every 2 seconds.
  void _scheduleVisitRecompute() {
    _visitDebounce?.cancel();
    _visitDebounce = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(_applyVisitSummary);
    });
  }

  Future<void> _loadAssignments() async {
    final AssignmentResult<AssignmentList> r = await _assignmentService.list(
      startDate: DateFormat('yyyy-MM-dd').format(_selectedDateRange.start),
      endDate: DateFormat('yyyy-MM-dd').format(_selectedDateRange.end),
    );
    if (!mounted) return;
    setState(() {
      _assignmentFailure = r.failure;
      _assignmentMessage = r.message;
      _assignments = r.isOk ? r.value : null;
    });
  }

  void _fetchChartData() {
    _loadGeofences();
    _loadAssignments();
    _trucksSubscription?.cancel();
    _routesSubscription?.cancel();
    _progressSubscription?.cancel();
    _truckIssuesSubscription?.cancel();
    _truckRegistrySubscription?.cancel();
    _residentComplaintsFbSubscription?.cancel();

    _truckRegistrySubscription = _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _truckRegistry = event.snapshot.value as Map;
        _updateTruckStatusData();
      }
    });

    _trucksSubscription = TruckLocationsFeed.shared().events.listen((event) {
      _allTruckLocations = (event.snapshot.exists && event.snapshot.value is Map)
          ? event.snapshot.value as Map
          : <dynamic, dynamic>{};
      _updateTruckStatusData();
    });
    // Freshness changes without any event (a crashed driver writes nothing).
    _fleetAgingTimer?.cancel();
    _fleetAgingTimer = Timer.periodic(const Duration(seconds: 15), (_) => _updateTruckStatusData());

    _routesSubscription = _database.ref('driver_routes').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allDriverRoutes = event.snapshot.value as Map;
        _etaClosedTripIds = _closedTripIds(_allDriverRoutes);
        _etaRoutes = _allDriverRoutes;
        _refreshEtaVisits();
        _recalculateRoutesMetrics();
        _calculateAnalytics();

        // A newly finalized collection (FULL) must show up in Load History and the
        // Waste Collection Summary: reload once, debounced, only when the number of
        // finalized collections actually changed (no polling).
        int finalized = 0;
        _allDriverRoutes.forEach((_, v) {
          if (v is Map && v['collection'] is Map && (v['collection'] as Map)['finalized_at_ms'] != null) finalized++;
        });
        if (_lastFinalizedRouteCount >= 0 && finalized != _lastFinalizedRouteCount) {
          _loadRefreshDebounce?.cancel();
          _loadRefreshDebounce = Timer(const Duration(seconds: 2), () {
            if (mounted) _fetchLoadHistoryData();
          });
        }
        _lastFinalizedRouteCount = finalized;
      }
    });

    _progressSubscription = _database.ref('collection_progress').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allCollectionProgress = event.snapshot.value as Map;
        _recalculateRoutesMetrics();
        _calculateAnalytics();
      }
    });

    _weeklyProgressSubscription = _database.ref('weekly_collection_progress').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allWeeklyCollectionProgress = event.snapshot.value as Map;
        _recalculateRoutesMetrics();
        _calculateAnalytics();
      }
    });

    _truckIssuesSubscription = _database.ref('truck_issues').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List list = [];
        data.forEach((key, value) {
          list.add({...Map<String, dynamic>.from(value as Map), 'id': key});
        });
        _allDriverIssues = list;
        _processComplaintsAndIssues();
      }
    });

    _residentComplaintsFbSubscription = _database.ref('complaints').onValue.listen((event) {
      // Keep listener to ensure real-time consistency if system uses it,
      // but _processComplaintsAndIssues now strictly aligns with Resolve Radar (API + truck_issues).
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List list = [];
        data.forEach((key, value) {
          if (value is Map) {
            list.add({...Map<String, dynamic>.from(value), 'id': key});
          }
        });
        _allFirebaseComplaints = list;
        _processComplaintsAndIssues();
      }
    });

    _apiService.getComplaints().then((response) {
      debugPrint("API COMPLAINTS RESPONSE: ${response.data['success']}");
      if (response.data['success'] == true) {
        _allResidentComplaints = response.data['data'];
        debugPrint("API COMPLAINTS LOADED: ${_allResidentComplaints.length} records");
        _processComplaintsAndIssues();
      }
    }).catchError((e) {
      debugPrint("API COMPLAINTS ERROR: $e");
    });
  }

  void _updateTruckStatusData() {
    final Map<String, double> counts = {"Active": 0, "Idle": 0, "Full": 0};

    // Same live definition as the Admin/Resident cards and the live maps
    // (FleetSnapshot): online flag, not OFFLINE/COMPLETED/FINISHED, fresh within
    // FleetStatus.freshnessWindowMs, one entry per driver.
    final FleetSnapshot fleet = FleetSnapshot.derive(_allTruckLocations);
    final Map<String, Map> liveByNode = <String, Map>{
      for (final LiveTruck t in fleet.trucks) t.nodeKey: t.node,
    };

    // Iterate over the official registry to ensure we only count valid trucks
    _truckRegistry.forEach((truckId, registryData) {
      final Map? live = liveByNode[truckId.toString()];
      if (live == null) {
        // Offline, stale, completed, or no live record: not in service.
        counts['Idle'] = counts['Idle']! + 1;
        return;
      }
      final String status = FleetStatus.collectionState(live);
      if (status == 'FULL') {
        counts['Full'] = counts['Full']! + 1;
      } else if (status.contains('IDLE') || status.contains('PAUSED')) {
        // Connected but paused: not collecting.
        counts['Idle'] = counts['Idle']! + 1;
      } else {
        counts['Active'] = counts['Active']! + 1;
      }
    });

    if (mounted) setState(() => _truckStatusData = counts);
  }



  void _recalculateRoutesMetrics() {
    // Current period metrics
    var currentMetrics = _calculateMetricsInRange(
        _selectedDateRange.start,
        _selectedDateRange.end,
        _selectedArea,
        debug: true
    );

    // Previous period metrics for trend
    DateTimeRange prevRange = _getPreviousPeriod(_selectedDateRange, _isDateRange);
    var prevMetrics = _calculateMetricsInRange(
        prevRange.start,
        prevRange.end,
        _selectedArea,
        debug: false
    );

    if (mounted) {
      setState(() {
        _totalRoutes = currentMetrics['total'] as int;
        _completedRoutes = currentMetrics['completed'] as int;
        _coveragePercent = _totalRoutes > 0 ? (_completedRoutes / _totalRoutes) * 100 : 0.0;

        // Purok Coverage shows VERIFIED VISIT COUNTS (not a percentage of a synthetic
        // days x areas denominator). Debounced: this runs on every new GPS point.
        _scheduleVisitRecompute();

        // Calculate Trends
        int prevCompleted = prevMetrics['completed'] as int? ?? 0;
        int prevTotal = prevMetrics['total'] as int? ?? 0;
        _prevCompletedRoutes = prevCompleted;
        _prevTotalRoutes = prevTotal;

        int completedDiff = _completedRoutes - prevCompleted;
        if (prevCompleted > 0 || _completedRoutes > 0) {
          if (completedDiff == 0) {
            _routeTrend = "No change vs previous";
            _routeTrendPositive = true;
          } else {
            _routeTrend = "${completedDiff > 0 ? '+' : ''}$completedDiff vs previous";
            _routeTrendPositive = completedDiff >= 0;
          }
        } else {
          _routeTrend = "N/A";
        }

        _routeCompletionRate = _totalRoutes > 0 ? (_completedRoutes / _totalRoutes) * 100 : 0.0;
        _prevRouteCompletionRate = prevTotal > 0 ? (prevCompleted / prevTotal) * 100 : 0.0;
        double completionDiffPoints = _routeCompletionRate - _prevRouteCompletionRate;

        if (prevTotal > 0 || _totalRoutes > 0) {
          if (completionDiffPoints == 0) {
            _routeCompletionTrendText = "0 percentage points";
            _routeCompletionTrendPositive = true;
          } else {
            _routeCompletionTrendText = "${completionDiffPoints > 0 ? '+' : ''}${completionDiffPoints.toStringAsFixed(0)} percentage points";
            _routeCompletionTrendPositive = completionDiffPoints >= 0;
          }
        } else {
          _routeCompletionTrendText = "N/A";
        }

        _coverageTrend = _routeTrend;
        _coverageTrendPositive = _routeTrendPositive;

        // Process complaints will handle issue trends
        _processComplaintsAndIssues();
      });
    }
  }

  void _calculateIssueTrends(DateTimeRange prevRange, String areaFilter, int currentCompleted, int prevCompleted) {
    final startStr = DateFormat('yyyy-MM-dd').format(prevRange.start);
    final endStr = DateFormat('yyyy-MM-dd').format(prevRange.end);

    int prevIssues = 0;

    for (var c in _allResidentComplaints) {
      String? createdAt = c['created_at']?.toString();
      if (createdAt != null && createdAt.length >= 10) {
        String cDate = createdAt.substring(0, 10);
        if (cDate.compareTo(startStr) >= 0 && cDate.compareTo(endStr) <= 0) {
          String? purok = c['purok']?.toString();
          if (areaFilter == "All Areas" || purok == areaFilter) {
            prevIssues++;
          }
        }
      }
    }

    for (var i in _allDriverIssues) {
      dynamic rawTs = i['createdAt'];
      if (rawTs != null) {
        int ts = rawTs is int ? rawTs : int.tryParse(rawTs.toString()) ?? 0;
        if (ts > 0) {
          String iDate = DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(ts));
          if (iDate.compareTo(startStr) >= 0 && iDate.compareTo(endStr) <= 0) {
            if (areaFilter == "All Areas") prevIssues++;
          }
        }
      }
    }

    double prevRate = prevCompleted > 0 ? (prevIssues / prevCompleted) * 100 : 0.0;

    if (prevCompleted > 0 || currentCompleted > 0) {
      double diff = _issueRate - prevRate;
      _issueTrend = "${diff.abs().toStringAsFixed(1)}%";
      _issueTrendPositive = diff <= 0; // Negative is good for issues
    } else {
      _issueTrend = "N/A";
    }
  }

  // Helper for debug logging
  List<String> relevantSessionsInRange = [];

  Map<String, dynamic> _calculateMetricsInRange(DateTime start, DateTime end, String areaFilter, {bool debug = false}) {
    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);

    // Calculate days in range
    int days = end.difference(start).inDays + 1;

    // Determine which puroks to expect
    List<String> expectedPuroks = areaFilter == "All Areas" ? _purokNames : [areaFilter];

    // Key: date_areaName
    final Set<String> expectedUniqueKeys = {};
    final Set<String> completedUniqueKeys = {};

    // Per-purok stats
    final Map<String, int> purokExpected = {};
    final Map<String, int> purokCompleted = {};

    for (var p in expectedPuroks) {
      purokExpected[p] = days;
      purokCompleted[p] = 0;
      for (int i = 0; i < days; i++) {
        String dStr = DateFormat('yyyy-MM-dd').format(start.add(Duration(days: i)));
        expectedUniqueKeys.add("${dStr}_$p");
      }
    }

    int duplicatesRemoved = 0;
    int rawSessionsFound = 0;

    _allDriverRoutes.forEach((sessionId, data) {
      if (data is Map) {
        final String sId = sessionId.toString();
        final dateStr = data['date']?.toString() ?? "";
        bool inRange = dateStr.compareTo(startStr) >= 0 && dateStr.compareTo(endStr) <= 0;

        if (inRange) {
          rawSessionsFound++;
          // Check collection progress for this session
          final progress = _allCollectionProgress[sId];
          if (progress is Map) {
            progress.forEach((purokKey, purokData) {
              if (purokData is Map) {
                final rawName = purokData['name']?.toString() ?? purokKey.toString();
                final String? canonical = ServiceAreaService.canonicalizeAreaName(rawName) ?? (purokCompleted.containsKey(rawName) ? rawName : null);
                if (canonical != null && canonical.isNotEmpty) {
                  // Apply area filter
                  if (areaFilter == "All Areas" || canonical == areaFilter) {
                    final String uniqueKey = "${dateStr}_$canonical";

                    if (purokData['completed'] == true) {
                      if (!completedUniqueKeys.contains(uniqueKey)) {
                        completedUniqueKeys.add(uniqueKey);
                        if (purokCompleted.containsKey(canonical)) {
                          purokCompleted[canonical] = (purokCompleted[canonical] ?? 0) + 1;
                        }
                      } else {
                        duplicatesRemoved++;
                      }
                    }

                    // In case a driver does a route not in our default expected set
                    if (!expectedUniqueKeys.contains(uniqueKey)) {
                      expectedUniqueKeys.add(uniqueKey);
                      purokExpected[canonical] = (purokExpected[canonical] ?? 0) + 1;
                    }
                  }
                }
              }
            });
          }
        }
      }
    });

    // Also process weekly_collection_progress entries as an additional data source
    if (_allWeeklyCollectionProgress.isNotEmpty) {
      _allWeeklyCollectionProgress.forEach((weekKey, weekData) {
        if (weekData is Map) {
          weekData.forEach((driverId, driverData) {
            if (driverData is Map && driverData['areas'] is Map) {
              final Map areasMap = driverData['areas'] as Map;
              areasMap.forEach((areaKey, areaData) {
                if (areaData is Map && areaData['completed'] == true) {
                  String dateStr = "";
                  if (areaData['completedAt'] != null) {
                    final String raw = areaData['completedAt'].toString();
                    if (raw.length >= 10) {
                      dateStr = raw.substring(0, 10);
                    }
                  }
                  if (dateStr.isEmpty) {
                    dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
                  }

                  bool inRange = dateStr.compareTo(startStr) >= 0 && dateStr.compareTo(endStr) <= 0;
                  if (inRange) {
                    final rawName = areaData['name']?.toString() ?? areaKey.toString();
                    final String? canonical = ServiceAreaService.canonicalizeAreaName(rawName) ?? (purokCompleted.containsKey(rawName) ? rawName : null);
                    if (canonical != null && canonical.isNotEmpty) {
                      if (areaFilter == "All Areas" || canonical == areaFilter) {
                        final String uniqueKey = "${dateStr}_$canonical";
                        if (!completedUniqueKeys.contains(uniqueKey)) {
                          completedUniqueKeys.add(uniqueKey);
                          if (purokCompleted.containsKey(canonical)) {
                            purokCompleted[canonical] = (purokCompleted[canonical] ?? 0) + 1;
                          }
                        }
                      }
                    }
                  }
                }
              });
            }
          });
        }
      });
    }

    if (debug) {
      debugPrint("==================================================");
      debugPrint("ANALYTICS ROUTE DEBUG:");
      debugPrint("- SELECTED AREA: $areaFilter");
      debugPrint("- START DATE: $startStr");
      debugPrint("- END DATE: $endStr");
      debugPrint("- RAW SESSIONS IN RANGE: $rawSessionsFound");
      debugPrint("- TOTAL EXPECTED ASSIGNMENTS: ${expectedUniqueKeys.length}");
      debugPrint("- UNIQUE COMPLETED ROUTES: ${completedUniqueKeys.length}");
      debugPrint("- DUPLICATES REMOVED: $duplicatesRemoved");
      debugPrint("- FINAL: ${completedUniqueKeys.length} / ${expectedUniqueKeys.length}");
      debugPrint("==================================================");
    }

    return {
      'total': expectedUniqueKeys.length,
      'completed': completedUniqueKeys.length,
      'purokExpected': purokExpected,
      'purokCompleted': purokCompleted,
    };
  }

  DateTimeRange _getPreviousPeriod(DateTimeRange current, bool isRange) {
    if (!isRange) {
      // Single day: previous day
      final prevDay = current.start.subtract(const Duration(days: 1));
      return DateTimeRange(start: prevDay, end: prevDay);
    } else {
      // Date range: previous period of same duration
      final duration = current.end.difference(current.start);
      final prevEnd = current.start.subtract(const Duration(days: 1));
      final prevStart = prevEnd.subtract(duration);
      return DateTimeRange(start: prevStart, end: prevEnd);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobile = constraints.maxWidth < 900;
        return Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          body: Stack(
            children: [
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerMove: (event) {
                  // Track pull depth when at the very top of the scroll or already pulling
                  bool atTop = _scrollController.hasClients && _scrollController.offset <= 0;
                  if (!_isRefreshing && (atTop || _manualPullDepth > 0)) {
                    if (event.delta.dy > 0 || _manualPullDepth > 0) {
                      setState(() {
                        _manualPullDepth += event.delta.dy * 0.5; // Dampen the pull
                        if (_manualPullDepth < 0) _manualPullDepth = 0;
                        if (_manualPullDepth > 120) _manualPullDepth = 120; // Max pull depth
                        _showRefreshSpinner = _manualPullDepth > 0;
                      });
                    }
                  }
                },
                onPointerUp: (event) {
                  if (_manualPullDepth > 70 && !_isRefreshing) {
                    _refreshAllStats(manual: true);
                  } else if (!_isRefreshing) {
                    setState(() {
                      _manualPullDepth = 0;
                      _showRefreshSpinner = false;
                    });
                  }
                },
                child: Column(
                  children: [
                    _buildHeader(isMobile),
                    if (isMobile) _buildFilterBar(),
                    Expanded(
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(overscroll: false), // Disable glow/bounce
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          physics: (_manualPullDepth > 0 || _isRefreshing) 
                              ? const NeverScrollableScrollPhysics() 
                              : const ClampingScrollPhysics(), // Content stays 100% fixed at the top
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              constraints.maxWidth < 600 ? 16 : (constraints.maxWidth < 1024 ? 24 : 48),
                              24,
                              constraints.maxWidth < 600 ? 16 : (constraints.maxWidth < 1024 ? 24 : 48),
                              constraints.maxWidth < 1024 ? 115 : 28,
                            ),
                            child: Center(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  isMobile
                                      ? Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              crossAxisAlignment: CrossAxisAlignment.baseline,
                                              textBaseline: TextBaseline.alphabetic,
                                              children: [
                                                const Text(
                                                  "Overview",
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 18,
                                                    color: Color(0xFF1A1A1A),
                                                    letterSpacing: -0.3,
                                                  ),
                                                ),
                                                Text(
                                                  "Tap a card for details",
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    color: Colors.grey.shade600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 12),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: _buildCompactMobileMetricCard(
                                                    title: "Full loads",
                                                    value: _loadError != null ? "N/A" : (_loadHasLoaded ? "$_loadTripsCount" : "..."),
                                                    subtitle: "Trips that reached FULL",
                                                    icon: Icons.local_shipping_rounded,
                                                    cardBgColor: const Color(0xFFF3F9F3),
                                                    borderColor: const Color(0xFFE2F0E2),
                                                    iconBgColor: const Color(0xFFE8F5E9),
                                                    iconColor: const Color(0xFF2E7D32),
                                                    onTap: () => _showInsightDialog("routes_done"),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: _buildCompactMobileMetricCard(
                                                    title: "Areas visited",
                                                    value: _visitSummary == null ? "..." : "$_areasVisitedCount/${_expectedVisitAreas.length}",
                                                    subtitle: "Verified by GPS",
                                                    icon: Icons.map_rounded,
                                                    cardBgColor: const Color(0xFFF0F6FE),
                                                    borderColor: const Color(0xFFE1EDFE),
                                                    iconBgColor: const Color(0xFFE3F2FD),
                                                    iconColor: const Color(0xFF1976D2),
                                                    onTap: () => _showInsightDialog("route_completion"),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: _buildCompactMobileMetricCard(
                                                    title: "Missed pickups",
                                                    value: "$_missedPickupsCount",
                                                    subtitle: "Reported",
                                                    icon: Icons.warning_rounded,
                                                    cardBgColor: const Color(0xFFFFF6ED),
                                                    borderColor: const Color(0xFFFEE8D6),
                                                    iconBgColor: const Color(0xFFFFE0B2),
                                                    iconColor: const Color(0xFFE65100),
                                                    onTap: () => _showInsightDialog("missed_pickups"),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        )
                                      : Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text("Viewing Dashboard: $_selectedArea", style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF1A1A1A))),
                                            const SizedBox(height: 24),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: _buildMetricCard(
                                                    title: "Full loads",
                                                    value: _loadError != null ? "N/A" : (_loadHasLoaded ? "$_loadTripsCount" : "..."),
                                                    subtitle: "collection trips that reached FULL capacity",
                                                    icon: Icons.local_shipping_rounded,
                                                    color: const Color(0xFF4CAF50),
                                                    trendText: "N/A",
                                                    isPositive: _routeTrendPositive,
                                                    onTap: () => _showInsightDialog("routes_done"),
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: _buildMetricCard(
                                                    title: "Areas visited",
                                                    value: _visitSummary == null ? "..." : "$_areasVisitedCount/${_expectedVisitAreas.length}",
                                                    subtitle: "collection areas with a verified visit",
                                                    icon: Icons.map_rounded,
                                                    color: const Color(0xFF2196F3),
                                                    trendText: "N/A",
                                                    isPositive: _routeCompletionTrendPositive,
                                                    onTap: () => _showInsightDialog("route_completion"),
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: _buildMetricCard(
                                                    title: "Missed Pickups",
                                                    value: "$_missedPickupsCount",
                                                    subtitle: "uncollected trash reports",
                                                    icon: Icons.report_problem_rounded,
                                                    color: const Color(0xFFE65100),
                                                    trendText: _missedPickupsTrendText ?? "N/A",
                                                    isPositive: _missedPickupsTrendPositive,
                                                    onTap: () => _showInsightDialog("missed_pickups"),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                  const SizedBox(height: 32),
                                  if (isMobile) ...[
                                    _buildChartSection("Truck Status", _buildTruckDonutChart(), legend: [
                                      _buildLegendItem("Active", (_truckStatusData['Active'] ?? 0).toInt(), Colors.green),
                                      _buildLegendItem("Full", (_truckStatusData['Full'] ?? 0).toInt(), Colors.amber),
                                      _buildLegendItem("Not collecting", (_truckStatusData['Idle'] ?? 0).toInt(), Colors.grey.shade300),
                                    ], onView: () => widget.onNavigate?.call(1)),
                                    const SizedBox(height: 24),
                                    _buildChartSection("Complaints", Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(height: 150, child: _buildComplaintsDonutChart()),
                                        const SizedBox(height: 12),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                                          child: Text("${_complaintSourceData['Residents']?.toInt() ?? 0} resident complaint(s)  ·  ${_complaintSourceData['Drivers']?.toInt() ?? 0} driver truck issue(s), shown separately",
                                              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                        ),
                                      ],
                                    ), legend: [
                                      _buildLegendItem("Pending", (_complaintStatusData['Pending'] ?? 0).toInt(), Colors.red),
                                      _buildLegendItem("In Progress", (_complaintStatusData['In Progress'] ?? 0).toInt(), Colors.blue),
                                      _buildLegendItem("Resolved", (_complaintStatusData['Resolved'] ?? 0).toInt(), Colors.green),
                                    ], onView: () => widget.onNavigate?.call(3)),
                                    const SizedBox(height: 24),
                                    _buildPurokChartSection(),
                                    const SizedBox(height: 24),
                                    _buildInsightsSection(isMobile),
                                  ] else ...[
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: Column(
                                            children: [
                                              _buildPurokChartSection(),
                                              const SizedBox(height: 24),
                                              _buildInsightsSection(isMobile),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 24),
                                        Expanded(
                                          flex: 2,
                                          child: Column(
                                            children: [
                                              _buildChartSection("Truck Status", _buildTruckDonutChart(), legend: [
                                                _buildLegendItem("Active", (_truckStatusData['Active'] ?? 0).toInt(), Colors.green),
                                                _buildLegendItem("Full", (_truckStatusData['Full'] ?? 0).toInt(), Colors.amber),
                                                _buildLegendItem("Not collecting", (_truckStatusData['Idle'] ?? 0).toInt(), Colors.grey.shade300),
                                              ], onView: () => widget.onNavigate?.call(1)),
                                              const SizedBox(height: 24),
                                              _buildChartSection("Complaints", Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Expanded(child: _buildComplaintsDonutChart()),
                                                  const SizedBox(height: 24), // Added healthy spacing below the pie chart on desktop to completely push the container down
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                                                    child: Text("${_complaintSourceData['Residents']?.toInt() ?? 0} resident complaint(s)  ·  ${_complaintSourceData['Drivers']?.toInt() ?? 0} driver truck issue(s), shown separately",
                                                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                                  ),
                                                ],
                                              ), legend: [
                                                _buildLegendItem("Pending", (_complaintStatusData['Pending'] ?? 0).toInt(), Colors.red),
                                                _buildLegendItem("In Progress", (_complaintStatusData['In Progress'] ?? 0).toInt(), Colors.blue),
                                                _buildLegendItem("Resolved", (_complaintStatusData['Resolved'] ?? 0).toInt(), Colors.green),
                                              ], onView: () => widget.onNavigate?.call(3)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 24), // Reduced from 120 to 24 to keep content tight and clean near the bottom
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedBuilder(
                animation: _refreshRotationController,
                builder: (context, child) {
                  // Logic to show spinner: 
                  // 1. If currently performing a manual pull (_manualPullDepth > 0)
                  // 2. If currently performing a refresh (_showRefreshSpinner)
                  bool shouldShow = _showRefreshSpinner || _manualPullDepth > 0;
                  
                  if (!shouldShow) {
                    return const SizedBox.shrink();
                  }

                  // If refreshing, stick at 80. 
                  // If just pulling, follow the manual depth up to 80.
                  final double targetTop = (_isRefreshing && _showRefreshSpinner)
                      ? 80.0 
                      : (-40 + _manualPullDepth).clamp(-40.0, 80.0);
                  
                  final double opacity = (_isRefreshing && _showRefreshSpinner)
                      ? 1.0 
                      : (_manualPullDepth / 60).clamp(0.0, 1.0);

                  return AnimatedPositioned(
                    duration: Duration(milliseconds: _isRefreshing ? 200 : 400),
                    curve: Curves.easeOutCubic,
                    top: targetTop,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Opacity(
                        opacity: opacity,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Transform.rotate(
                            // Interactive rotation: rotates as you pull (clockwise)
                            angle: (_isRefreshing && _showRefreshSpinner)
                                ? 0 
                                : (_manualPullDepth / 80) * 2 * math.pi,
                            child: RotationTransition(
                              turns: _refreshRotationController,
                              child: const Icon(
                                Icons.refresh_rounded,
                                color: Color(0xFF00796B),
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(bool isMobile) {
    if (!isMobile) {
      String dateLabel = _isDateRange
          ? "${DateFormat('MMM dd').format(_selectedDateRange.start)} - ${DateFormat('MMM dd').format(_selectedDateRange.end)}"
          : DateFormat('MMM dd, yyyy').format(_selectedDateRange.start);

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            if (_showHeaderShadow)
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 15,
                offset: const Offset(0, 4),
              )
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2F1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.analytics_rounded, color: Color(0xFF00897B), size: 28),
            ),
            const SizedBox(width: 20),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Analytics & Reports",
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A1A),
                        letterSpacing: -0.5)),
                Text("Comprehensive system performance overview",
                    style: TextStyle(
                        color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
            const Spacer(),
            _buildAreaDropdown(),
            const SizedBox(width: 24),
            Tooltip(message: dateLabel, child: PeriodSelector(value: _period, onChanged: _applyPeriod)),
            const SizedBox(width: 24),
            ElevatedButton.icon(
              onPressed: () => _showExportDialog(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text("EXPORT", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00796B), // Balanced deep teal matching the app system colors
                foregroundColor: Colors.white,
                elevation: 4, // Added shadow depth elevation
                shadowColor: const Color(0xFF00796B).withOpacity(0.4), // Tailored shadow tint color
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), // Better rounded edges structure
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16), // Enhanced padding layout
              ),
            ),
          ],
        ),
      );
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    // Adaptive font sizes
    final double titleFontSize = (screenWidth * 0.055).clamp(18.0, 22.0);
    final double subtitleFontSize = (screenWidth * 0.03).clamp(10.0, 12.0);
    final double iconContainerSize = (screenWidth * 0.12).clamp(40.0, 48.0);
    final double iconSize = (screenWidth * 0.06).clamp(20.0, 24.0);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: const Color(0xFFEEEEEE), width: _showHeaderShadow ? 0 : 1)),
        boxShadow: [
          if (_showHeaderShadow)
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Row(
            children: [
              if (!widget.isEmbedded || widget.onBack != null) ...[
                _buildCircularBackButton(),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Analytics", style: TextStyle(fontSize: titleFontSize, fontWeight: FontWeight.w900, color: const Color(0xFF1A1A1A), letterSpacing: -0.5)),
                    Text("System performance overview", style: TextStyle(fontSize: subtitleFontSize, color: const Color(0xFF757575), fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => _showExportDialog(context),
                child: Container(
                  width: iconContainerSize,
                  height: iconContainerSize,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00796B), // Changed to solid deep teal brand color matching modern standard
                    borderRadius: BorderRadius.circular(16), // Rounded smoothly matching web button
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00796B).withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(Icons.download_rounded, color: Colors.white, size: iconSize), // White icon contrasting against deep teal
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCircularBackButton() {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    return GestureDetector(
      onTap: () {
        if (isMobile) {
          Scaffold.of(context).openDrawer();
        } else if (widget.onBack != null) {
          widget.onBack!();
        } else {
          Navigator.pop(context);
        }
      },
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(
          isMobile ? Icons.menu_rounded : Icons.arrow_back_ios_new_rounded,
          color: const Color(0xFF1A1A1A),
          size: isMobile ? 22 : 18,
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    String dateLabel = _isDateRange
        ? "${DateFormat('MMM dd').format(_selectedDateRange.start)} - ${DateFormat('MMM dd').format(_selectedDateRange.end)}"
        : DateFormat('MMM dd, yyyy').format(_selectedDateRange.start);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          _buildAreaDropdown(),
          const SizedBox(width: 12),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Tooltip(message: dateLabel, child: PeriodSelector(value: _period, compact: true, onChanged: _applyPeriod)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAreaDropdown() {
    return PopupMenuButton<String>(
      onSelected: (area) {
        setState(() => _selectedArea = area);
        refreshAllData();
      },
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
      color: Colors.white,
      itemBuilder: (context) => ["All Areas", ..._purokNames].map((area) {
        bool isSelected = area == _selectedArea;
        return PopupMenuItem<String>(
          value: area,
          child: Row(
            children: [
              Icon(
                isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 18,
                color: isSelected ? const Color(0xFF00897B) : Colors.grey.shade400,
              ),
              const SizedBox(width: 12),
              Text(
                area,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                  color: isSelected ? const Color(0xFF00897B) : const Color(0xFF2C3E50),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      }).toList(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on_rounded, size: 18, color: Color(0xFF00897B)),
          const SizedBox(width: 8),
          Text(_selectedArea, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF1A1A1A))),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down_rounded, size: 24, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String trendText,
    required bool isPositive,
    required VoidCallback onTap,
  }) {
    final bool isMobile = MediaQuery.of(context).size.width < 900;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(isMobile ? 16 : 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(color: Colors.grey.shade200, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, color: color, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: isMobile ? 13 : 14,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1A1A1A),
                        ),
                      ),
                    ],
                  ),
                  if (trendText != "N/A")
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: (isPositive ? Colors.green : Colors.red).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        trendText,
                        style: TextStyle(
                          color: isPositive ? Colors.green.shade700 : Colors.red.shade700,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: isMobile ? 24 : 32,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF1A1A1A),
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    "View insight",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 14, color: color),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactMobileMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color cardBgColor,
    required Color borderColor,
    required Color iconBgColor,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconColor, size: 18),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Colors.grey.shade600,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A1A1A),
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A1A1A),
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showInsightDialog(String metricType) {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    final String dateStr = _dateRangeDisplayStr;
    final String filterStr = "$_selectedArea • $dateStr";

    Widget content;
    String title;
    IconData icon;
    Color color;
    String actionLabel;
    VoidCallback onAction;

    if (metricType == "routes_done") {
      title = "Full loads";
      icon = Icons.local_shipping_rounded;
      color = const Color(0xFF4CAF50);
      actionLabel = "View load history →";
      onAction = () {
        Navigator.pop(context);
        _showLoadHistoryModal(context);
      };

      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _loadError != null ? "N/A" : "$_loadTripsCount",
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 12),
          Text(
            _loadError ??
                "Distinct collection trips that reached FULL capacity in this period, counted once per trip ID. "
                    "FULL stops collection and finalizes the load; COMPLETED only confirms unloading. "
                    "The same records as Load History and the Waste Collection Summary.",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
          const SizedBox(height: 20),
          _buildDialogRow("Full loads", "$_loadTripsCount"),
          const Divider(height: 24),
          _buildDialogRow("Ongoing (not finished)", "$_loadOngoingCount"),
          const Divider(height: 24),
          _buildDialogRow("Stale unfinished (excluded)", "$_loadStaleCount"),
        ],
      );
    } else if (metricType == "route_completion") {
      title = "Areas visited";
      icon = Icons.map_rounded;
      color = const Color(0xFF2196F3);
      actionLabel = "Close";
      onAction = () => Navigator.pop(context);

      final VisitSummary? v = _visitSummary;
      final Map<String, int> counts = v?.countByArea() ?? const <String, int>{};
      final List<String> expected = _expectedVisitAreas;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            v == null ? "..." : "$_areasVisitedCount of ${expected.length}",
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 12),
          Text(
            "Collection areas with at least one verified visit in this period. A visit needs at least 2 accurate "
            "GPS fixes inside the area, at least 1 minute apart, while the trip is ACTIVE (paused, full and completed "
            "travel is excluded), counted once per trip and area. It shows the truck was there to collect, not that "
            "every household was serviced. There is no schedule data, so no completion rate is shown.",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
          const SizedBox(height: 20),
          for (final String area in expected) ...<Widget>[
            _buildDialogRow(area, "${counts[area] ?? 0} visit(s)"),
            const Divider(height: 20),
          ],
          if (v != null && v.tripsWithoutEvidence > 0)
            _buildDialogRow("Trips without usable GPS", "${v.tripsWithoutEvidence} of ${v.tripsConsidered}"),
        ],
      );
    } else {
      title = "Missed Pickups";
      icon = Icons.report_problem_rounded;
      color = const Color(0xFFE65100);
      actionLabel = "View complaint records →";
      onAction = () {
        Navigator.pop(context);
        widget.onNavigate?.call(3);
      };

      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                "$_missedPickupsCount",
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
              ),
              const SizedBox(width: 8),
              Text(
                "uncollected trash reports",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _missedPickupsPending > 0
                ? "$_missedPickupsCount uncollected trash reports were submitted by residents in this area. $_missedPickupsPending report${_missedPickupsPending > 1 ? 's are' : ' is'} currently pending response; dispatch a backup truck to assist these residents."
                : "All uncollected trash reports submitted by residents in this area during this period have been resolved.",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
          const SizedBox(height: 20),
          _buildDialogRow("Pending response", "$_missedPickupsPending"),
          const Divider(height: 24),
          _buildDialogRow("Resolved", "$_missedPickupsResolved"),
          const Divider(height: 24),
          _buildDialogRow("Previous period", "$_prevMissedPickupsCount"),
        ],
      );
    }

    if (isMobile) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                          child: Icon(icon, color: color, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
                            const SizedBox(height: 2),
                            Text(filterStr, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                content,
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: color,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(actionLabel, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          contentPadding: const EdgeInsets.all(24),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                          child: Icon(icon, color: color, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
                            const SizedBox(height: 2),
                            Text(filterStr, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                content,
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: color,
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(actionLabel, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  Widget _buildDialogRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
      ],
    );
  }

  Widget _buildChartSection(String title, Widget chart, {List<Widget>? legend, VoidCallback? onView}) {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    return Container(
      padding: EdgeInsets.all(isMobile ? 20 : 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
              if (onView != null)
                TextButton(
                  onPressed: onView,
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFFE0F2F1),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text("VIEW", style: TextStyle(color: Color(0xFF00897B), fontWeight: FontWeight.w900, fontSize: 12)),
                ),
            ],
          ),
          SizedBox(height: isMobile ? 16 : 32),
          // Increased desktop chart container height slightly to 240 to give the larger chart and its badge container room to breathe without overlapping
          SizedBox(height: isMobile ? 230 : 240, child: chart), 
          if (legend != null) ...[
            SizedBox(height: isMobile ? 16 : 24),
            SizedBox(
              width: double.infinity,
              child: Wrap(spacing: isMobile ? 16 : 12, runSpacing: 8, alignment: WrapAlignment.center, children: legend),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, int value, Color color) {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: isMobile ? 14 : 10, 
          height: isMobile ? 14 : 10, 
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(isMobile ? 4 : 3))
        ),
        const SizedBox(width: 10),
        Text("$label ($value)", style: TextStyle(fontSize: isMobile ? 14 : 12, fontWeight: FontWeight.w800, color: const Color(0xFF2C3E50))),
      ],
    );
  }

  Widget _buildPurokChartSection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Purok Coverage", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 2),
                  Text("Verified collection visits & resident complaints", style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(color: Color(0xFFE3F2FD), shape: BoxShape.circle),
                child: const Icon(Icons.visibility_rounded, color: Color(0xFF2196F3), size: 18),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFF8E24AA), borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 6),
              const Text("Verified visits", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))),
              const SizedBox(width: 24),
              Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFF2196F3), borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 6),
              const Text("Resident complaints", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))),
            ],
          ),
          const SizedBox(height: 20),

          // Scale Header (same scale on both sides, from the largest value shown)
          Row(
            children: [
              const Expanded(flex: 3, child: SizedBox()),
              Expanded(
                flex: 4,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <String>["$_coverageScaleMax", "${(_coverageScaleMax / 2).round()}", "0", "${(_coverageScaleMax / 2).round()}", "$_coverageScaleMax"]
                      .map((String t) => Text(t, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)))
                      .toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Purok Rows
          ..._purokNames.map((area) {
            int visits = _purokFrequencyData[area] ?? 0;
            int complaints = (_purokComplaintData[area] ?? 0).toInt();

            final double maxScale = _coverageScaleMax.toDouble();
            double visitRatio = (visits / maxScale).clamp(0.0, 1.0);
            double complaintRatio = (complaints / maxScale).clamp(0.0, 1.0);

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      area,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50)),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                area == "San Nicolas" ? "-" : "$visits",
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF8E24AA)),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: FractionallySizedBox(
                                  widthFactor: area == "San Nicolas" ? 0.0 : visitRatio,
                                  alignment: Alignment.centerRight,
                                  child: Container(
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF8E24AA),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 2,
                          height: 24,
                          color: Colors.grey.shade400,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Flexible(
                                child: FractionallySizedBox(
                                  widthFactor: complaintRatio,
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2196F3),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                "$complaints",
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF2196F3)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 16),
          const Center(
            child: Text(
              "San Nicolas: stationary sweeping area (not serviced by truck, no visits counted)",
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "A verified visit = one trip with at least 2 accurate GPS fixes inside the area, at least 1 minute apart, while "
            "ACTIVE, counted once per trip and area. Paused, full and completed travel is excluded. It does not prove every "
            "household was serviced. Complaints = resident complaints filed in the period.",
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600, height: 1.4),
          ),
          if (_visitSummary != null && _visitSummary!.tripsWithoutEvidence > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              "${_visitSummary!.tripsWithoutEvidence} of ${_visitSummary!.tripsConsidered} trip(s) in this period had no usable GPS points, so their visits cannot be verified.",
              style: const TextStyle(fontSize: 10.5, color: Color(0xFFB45309), fontWeight: FontWeight.w600, height: 1.4),
            ),
          ],
          if (_geofencesFromDefaults) ...<Widget>[
            const SizedBox(height: 6),
            const Text(
              "Configured service areas could not be read; the documented default area boundaries were used.",
              style: TextStyle(fontSize: 10.5, color: Color(0xFFB45309), fontWeight: FontWeight.w600, height: 1.4),
            ),
          ],
          const SizedBox(height: 24),
          Center(
            child: TextButton(
              onPressed: () => _showFullDetailsModal(context),
              style: TextButton.styleFrom(
                overlayColor: Colors.transparent,
                splashFactory: NoSplash.splashFactory,
              ),
              child: const Text("VIEW FULL DETAILS", style: TextStyle(color: Color(0xFF2196F3), fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
            ),
          ),
        ],
      ),
    );
  }

  void _showAllEtasModal(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    if (width < 600) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (context, scrollController) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: _EtaPerformanceModal(
              scrollController: scrollController,
              initialVisits: _etaVisits,
              initialArea: _selectedArea,
              selectedDateRange: _selectedDateRange,
              purokNames: _purokNames,
            ),
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880, maxHeight: 820),
            child: _EtaPerformanceModal(
              initialVisits: _etaVisits,
              initialArea: _selectedArea,
              selectedDateRange: _selectedDateRange,
              purokNames: _purokNames,
            ),
          ),
        ),
      );
    }
  }

  void _showFullDetailsModal(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    if (width < 600) {
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: "Operational Insights",
        barrierColor: Colors.black54,
        pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
          child: Scaffold(
            backgroundColor: Colors.white,
            body: _OperationalInsightsModal(
              frequencyData: _purokFrequencyData,
              visitData: _purokVisitCounts,
              complaintData: _purokComplaintData,
              completedRoutes: _completedRoutes,
              totalRoutes: _totalRoutes,
              complaintStatusData: _complaintStatusData,
              complaintSourceData: _complaintSourceData,
              selectedArea: _selectedArea,
              selectedDateRange: _selectedDateRange,
              purokNames: _purokNames,
              geminiSummary: _geminiSummary,
              recommendations: _recommendations,
              isAiLoading: _isAiLoading,
              onRefresh: () => _refreshAllStats(manual: true),
            ),
          ),
        ),
      );
    } else if (width < 1000) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800, maxHeight: 750),
            child: _OperationalInsightsModal(
              frequencyData: _purokFrequencyData,
              visitData: _purokVisitCounts,
              complaintData: _purokComplaintData,
              completedRoutes: _completedRoutes,
              totalRoutes: _totalRoutes,
              complaintStatusData: _complaintStatusData,
              complaintSourceData: _complaintSourceData,
              selectedArea: _selectedArea,
              selectedDateRange: _selectedDateRange,
              purokNames: _purokNames,
              geminiSummary: _geminiSummary,
              recommendations: _recommendations,
              isAiLoading: _isAiLoading,
              onRefresh: () => _refreshAllStats(manual: true),
            ),
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          insetPadding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 850),
            child: _OperationalInsightsModal(
              frequencyData: _purokFrequencyData,
              visitData: _purokVisitCounts,
              complaintData: _purokComplaintData,
              completedRoutes: _completedRoutes,
              totalRoutes: _totalRoutes,
              complaintStatusData: _complaintStatusData,
              complaintSourceData: _complaintSourceData,
              selectedArea: _selectedArea,
              selectedDateRange: _selectedDateRange,
              purokNames: _purokNames,
              geminiSummary: _geminiSummary,
              recommendations: _recommendations,
              isAiLoading: _isAiLoading,
              onRefresh: () => _refreshAllStats(manual: true),
            ),
          ),
        ),
      );
    }
  }

  void _showLoadHistoryModal(BuildContext context) {
    showLoadHistoryDialog(
      context,
      date: _selectedDateRange.end,
      onDataUpdated: () => _fetchLoadHistoryData(),
      onOpenRouteHistory: widget.onOpenRouteHistory,
    ).whenComplete(() {
      // Reopening the summary after the dialog keeps both views on the same data.
      if (mounted) _fetchLoadHistoryData();
    });
  }

  /// Scheduled Route Completion (operational) and Assigned-Area Coverage (verified GPS visits),
  /// shown only when real assignments exist for the period. Historical trips without an
  /// assignment are never given an invented schedule.
  Widget _buildScheduledRoutesCard() {
    final AssignmentList? data = _assignments;
    if (data == null || _assignmentFailure != AssignmentFailure.none) {
      // Unavailable (server not configured / not set up / no access): say so briefly, once.
      if (_assignmentFailure == AssignmentFailure.none || _assignmentFailure == AssignmentFailure.notSetUp ||
          _assignmentFailure == AssignmentFailure.notConfigured) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text("Scheduled routes: ${_assignmentMessage ?? 'unavailable'}", style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      );
    }
    final List<RouteAssignment> items =
        data.items.where((RouteAssignment a) => AssignedAreaCoverage.includesArea(a, _selectedArea)).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final AssignmentSummary s = AssignmentSummary.fromItems(items, data.today);

    // Verified visits per trip: the SAME visit summary as Purok Coverage (period + area filter).
    final Map<String, Set<String>> visitedByTrip = <String, Set<String>>{};
    for (final CollectionVisit x in _visitSummary?.visits ?? const <CollectionVisit>[]) {
      (visitedByTrip[x.tripId] ??= <String>{}).add(x.area);
    }
    final AssignedAreaCoverage cov = AssignedAreaCoverage.compute(items, visitedByTrip, areaFilter: _selectedArea);

    Widget metric(String label, String value, String note) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 2),
              Text(note, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
            ]),
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: AppTheme.balancedPulidongShadow),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Row(children: <Widget>[
            Icon(Icons.assignment_turned_in_rounded, color: Color(0xFF3949AB), size: 20),
            SizedBox(width: 8),
            Text("Scheduled Routes", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
          ]),
          const SizedBox(height: 12),
          Row(children: <Widget>[
            metric(
              "Scheduled route completion",
              s.completionRate == null ? "Not available" : "${s.completionRate!.toStringAsFixed(0)}%",
              s.due == 0 ? "No assignments due yet" : "${s.completed} of ${s.due} due assignment(s) completed",
            ),
            const SizedBox(width: 10),
            metric(
              "Assigned-area coverage",
              cov.percent == null ? "Not available" : "${cov.percent!.toStringAsFixed(0)}%",
              cov.assignedAreas == 0 ? "No started assignments" : "${cov.verifiedAreas} of ${cov.assignedAreas} assigned area(s) with a verified visit",
            ),
          ]),
          const SizedBox(height: 10),
          Text(
            "Pending ${s.pending} · In progress ${s.inProgress} · Completed ${s.completed} · Missed ${s.missed} · Cancelled ${s.cancelled}. "
            "Completion is operational (trip COMPLETED); a FULL trip stays in progress. Coverage counts only assigned areas "
            "with a verified GPS visit by the assignment's own trips. Trips without an assignment are not included.",
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600, height: 1.4),
          ),
        ]),
      ),
    );
  }

  Widget _buildInsightsSection(bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildWasteCollectionSummaryCard(isMobile),
        const SizedBox(height: 16),
        _buildRedesignedEtaPerformanceCard(isMobile),
        const SizedBox(height: 16),
        PredictiveModelsCard(
          trips: _allDriverRoutes,
          areas: _geofences,
          range: _selectedDateRange,
          etaVisits: _etaFilteredVisits,
          loads: _loadTrips,
        ),
        const SizedBox(height: 16),
        _buildScheduledRoutesCard(),
        _buildPredictionCard("Recommendations", [
          Text(
            _recommendations,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF6B21A8),
              fontWeight: FontWeight.w600,
              height: 1.6,
            ),
          ),
        ], titleColor: const Color(0xFF6B21A8)),
        const SizedBox(height: 24),
        _buildRedesignedOperationalContext(isMobile, MediaQuery.of(context).size.width),
      ],
    );
  }

  Widget _buildLegendItemDot(String label, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          "$label ($count)",
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
        ),
      ],
    );
  }

  // ---- Waste Collection Summary display state (loading / error / value) ----
  bool get _loadShowsPlaceholder => _loadError != null || (_isLoadingLoadData && !_loadHasLoaded);

  String _summaryTripsText() {
    if (_loadError != null) return "—";
    if (_isLoadingLoadData && !_loadHasLoaded) return "…";
    return "$_loadTripsCount";
  }

  String _summaryTonsText() {
    if (_loadError != null) return "—";
    if (_isLoadingLoadData && !_loadHasLoaded) return "…";
    return LoadTotals(
      trips: _loadTripsCount,
      weightKg: _loadTotalWeightKg,
      measuredCount: _loadMeasuredCount,
      estimatedCount: _loadEstimatedCount,
    ).tonsLabel;
  }

  String _summaryFormulaText() {
    if (_loadShowsPlaceholder) return "Waiting for collection data";
    if (_loadEstimatedCount > 0 && _loadMeasuredCount > 0) {
      return "$_loadEstimatedCount estimated × 5 tons (hypothetical, not measured) + $_loadMeasuredCount measured trips";
    }
    final String legacy = _loadLegacyCount > 0 ? " ($_loadLegacyCount legacy completed without a FULL event)" : "";
    return "$_loadTripsCount FULL trips$legacy × 5 tons each: hypothetical estimate, not measured waste";
  }

  Widget _buildLoadStatusBanner() {
    if (_loadError != null) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_loadError!, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF991B1B))),
            ),
            TextButton(onPressed: _fetchLoadHistoryData, child: const Text("Retry")),
          ],
        ),
      );
    }
    final List<Widget> notes = <Widget>[];
    if (_isLoadingLoadData) {
      notes.add(const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: LinearProgressIndicator(minHeight: 2),
      ));
    }
    if (_loadPartial) {
      notes.add(const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          "Some collection sources could not be reached; totals may be incomplete.",
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFB45309)),
        ),
      ));
    }
    if (_loadUnfinishedCount > 0 && !_loadShowsPlaceholder) {
      final List<String> parts = <String>[];
      if (_loadOngoingCount > 0) parts.add("$_loadOngoingCount ongoing");
      if (_loadStaleCount > 0) parts.add("$_loadStaleCount stale or legacy (no FULL, no recent activity)");
      notes.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          "Not counted until the truck is marked FULL: ${parts.join(', ')}.",
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
        ),
      ));
    }
    if (_loadUnattributedCount > 0 && !_loadShowsPlaceholder) {
      notes.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          "$_loadUnattributedCount trip${_loadUnattributedCount == 1 ? '' : 's'} in this period record no area and "
          "${_loadUnattributedCount == 1 ? 'is' : 'are'} not matched by the $_selectedArea filter.",
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
        ),
      ));
    }
    if (notes.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: notes);
  }

  Widget _buildWasteCollectionSummaryCard(bool isMobile) {
    final List<String> rangeOptions = ["All time", "Last 30 days", "Last 7 days", "This month", "Custom range"];

    return Container(
      padding: EdgeInsets.all(isMobile ? 18 : 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Title & Subtitle
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Waste Collection Summary",
                style: TextStyle(
                  fontSize: isMobile ? 18 : 22,
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF0F172A),
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "Overview of collection activity for the selected period.",
                style: TextStyle(
                  fontSize: isMobile ? 12 : 13,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF64748B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildLoadStatusBanner(),

          // 2 Metric Cards: Trips & Estimated Waste
          if (!isMobile)
            Row(
              children: [
                // Card 1: Trips
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.local_shipping_outlined, size: 22, color: Color(0xFF16A34A)),
                        const SizedBox(height: 12),
                        const Text("Trips", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                        const SizedBox(height: 4),
                        Text(
                          _summaryTripsText(),
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                // Card 2: Estimated waste
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.scale_outlined, size: 22, color: Color(0xFF0F766E)),
                        const SizedBox(height: 12),
                        Text(
                          _loadEstimatedCount == 0 && _loadMeasuredCount > 0 ? "Total waste" : "Estimated waste",
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _summaryTonsText(),
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                        ),
                        if (_loadEstimatedCount > 0 || _loadShowsPlaceholder) ...[
                          const SizedBox(height: 2),
                          Text(
                            _summaryFormulaText(),
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF94A3B8)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.local_shipping_outlined, size: 20, color: Color(0xFF16A34A)),
                        const SizedBox(height: 8),
                        const Text("Trips", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                        const SizedBox(height: 2),
                        Text(_summaryTripsText(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.scale_outlined, size: 20, color: Color(0xFF0F766E)),
                        const SizedBox(height: 8),
                        Text(_loadMeasuredCount > 0 ? "Total waste" : "Estimated waste", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                        const SizedBox(height: 2),
                        Text(_summaryTonsText(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                      ],
                    ),
                  ),
                ),
              ],
            ),

          const SizedBox(height: 16),

          // Calculator Info Banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F9FF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFBAE6FD)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.calculate_outlined, color: Color(0xFF0284C7), size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _summaryFormulaText(),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF0369A1)),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        "This is an estimated total based on 5 tons per trip.",
                        style: TextStyle(fontSize: 12, color: Color(0xFF0284C7), fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Info Banner: Estimation note
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: const [
                Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF64748B)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Calculated at 5 tons (5,000 kg) per finished collection trip.",
                    style: TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Main View Load History Action Button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () => _showLoadHistoryModal(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00796B),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Text("View Load History", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              label: const Icon(Icons.arrow_forward_rounded, size: 18, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComplaintsStatusCard() {
    final int pending = (_complaintStatusData['Pending'] ?? 0).toInt();
    final int inProgress = (_complaintStatusData['In Progress'] ?? 0).toInt();
    final int resolved = (_complaintStatusData['Resolved'] ?? 0).toInt();
    final int total = pending + inProgress + resolved;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Icon + Title & Subtitle
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4EA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.chat_bubble_outline_rounded,
                  color: Color(0xFF0F766E),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      "Complaints",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      "Resident complaints status",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Donut Chart Container
          SizedBox(
            height: 150,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _buildComplaintsDonutChart(),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "$total",
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                    ),
                    const Text("Total", style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Legend Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildLegendItemDot("Pending", pending, const Color(0xFFEF4444)),
              _buildLegendItemDot("In Progress", inProgress, const Color(0xFF3B82F6)),
              _buildLegendItemDot("Resolved", resolved, const Color(0xFF22C55E)),
            ],
          ),

          const SizedBox(height: 20),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          const SizedBox(height: 14),

          // Footer Row
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: () => widget.onNavigate?.call(3),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text("View Complaints", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0F766E))),
                  SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 16, color: Color(0xFF0F766E)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOperationalSummaryCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Icon + Title & Subtitle
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4EA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.assignment_outlined,
                  color: Color(0xFF0F766E),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      "Operational Summary",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      "Key operational items",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // List Row 1: Orange Alert
          InkWell(
            onTap: () => _showFullDetailsModal(context),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFF7ED),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.error_outline_rounded, color: Color(0xFFEA580C), size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "1 cycle needs a weight record",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF94A3B8)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // List Row 2: Green Check
          InkWell(
            onTap: () => widget.onNavigate?.call(3),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF0FDF4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF16A34A), size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "1 resolved complaint",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF94A3B8)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showEditCapacityDialog(BuildContext context) {
    final TextEditingController capCtrl = TextEditingController(text: _totalFleetCapacity.toInt().toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Edit Rated Capacity", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Enter truck rated capacity in kilograms (kg):", style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: capCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: "Rated Capacity (kg)",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () {
              final newCap = double.tryParse(capCtrl.text.trim());
              if (newCap != null && newCap > 0) {
                setState(() => _totalFleetCapacity = newCap);
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00897B),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text("Save", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _listenToFirebaseEtaNotifications() {
    _etaNotifSubscription?.cancel();
    _etaNotifSubscription = _database.ref('notifications').onValue.listen((event) {
      _etaRawNotifications = event.snapshot.exists ? event.snapshot.value : null;
      final List<EtaVisit> visits = _buildEtaVisits(_etaRawNotifications);
      if (mounted) {
        setState(() {
          _etaVisits = visits;
          _etaLoaded = true;
        });
      }
    }, onError: (Object e) {
      debugPrint('ETA notifications listener error: $e');
    });
  }

  /// The visits the card shows: the same filter the details use (area + Asia/Manila date range).
  /// Measured ETA error (first notified ETA vs GPS-confirmed arrival). Replaces a former
  /// formula-derived "MAE" (8% of the average collection time) that was not a measurement.
  String get _etaMaeText {
    final EtaSummary s = EtaEvaluation.summarize(_etaFilteredVisits);
    return s.avgAbsErrorMin == null
        ? 'Not available (no evaluated arrivals yet)'
        : '${s.avgAbsErrorMin!.toStringAsFixed(1)} min over ${s.evaluatedVisits} evaluated visit(s)';
  }

  String get _etaWithin5Text {
    final int? pct = EtaEvaluation.summarize(_etaFilteredVisits).within5Pct;
    return pct == null ? 'Not available' : '$pct% within ±5 min';
  }

  List<EtaVisit> get _etaFilteredVisits => EtaEvaluation.filter(
        _etaVisits,
        area: _selectedArea,
        start: _selectedDateRange.start,
        end: _selectedDateRange.end,
      );

  Map<String, String> _formatEtaErrorValueAndUnit(double minutes) {
    if (minutes >= 1440) {
      return {'value': (minutes / 1440).toStringAsFixed(1), 'unit': 'days'};
    } else if (minutes >= 60) {
      return {'value': (minutes / 60).toStringAsFixed(1), 'unit': 'hrs'};
    } else {
      return {'value': minutes.toStringAsFixed(1), 'unit': 'min'};
    }
  }

  Widget _buildRedesignedEtaPerformanceCard(bool isMobile) {
    final EtaSummary etaSummary = EtaEvaluation.summarize(_etaFilteredVisits);
    final Map<String, String> etaFormatted = etaSummary.hasEvaluated
        ? _formatEtaErrorValueAndUnit(etaSummary.avgAbsErrorMin!)
        : <String, String>{'value': _etaLoaded ? '\u2014' : '...', 'unit': ''};
    final String etaWithinText = etaSummary.within5Pct == null ? '\u2014' : '${etaSummary.within5Pct}%';
    final String etaFooterText = etaSummary.hasEvaluated
        ? 'First notified ETA vs GPS-confirmed arrival. ${etaSummary.awaitingVisits} awaiting arrival.'
        : (_etaLoaded
            ? 'No GPS-confirmed arrivals to evaluate yet (${etaSummary.awaitingVisits} awaiting arrival).'
            : 'Loading ETA records...');

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          )
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Icon + Title & Subtitle
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4EA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.access_time_filled_rounded,
                  color: Color(0xFF0F766E),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      "ETA Performance",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      "Notification timing accuracy",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Metrics Section
          if (!isMobile)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            etaFormatted['value']!,
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            etaFormatted['unit']!,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "Average arrival error",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),

                Container(
                  width: 1,
                  height: 48,
                  color: const Color(0xFFE2E8F0),
                ),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          etaWithinText,
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0F172A),
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "within ±5 min",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                Container(
                  width: 1,
                  height: 48,
                  color: const Color(0xFFE2E8F0),
                ),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${etaSummary.evaluatedVisits}",
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0F172A),
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "evaluated visits",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      etaFormatted['value']!,
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      etaFormatted['unit']!,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  "Average arrival error",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF64748B),
                  ),
                ),

                const SizedBox(height: 16),
                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                const SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            etaWithinText,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            "within ±5 min",
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),

                    Container(
                      width: 1,
                      height: 40,
                      color: const Color(0xFFE2E8F0),
                    ),

                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "${etaSummary.evaluatedVisits}",
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0F172A),
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "evaluated visits",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),

          const SizedBox(height: 20),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          const SizedBox(height: 16),

          // Footer Row
          if (!isMobile)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  etaFooterText,
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                InkWell(
                  onTap: () => _showAllEtasModal(context),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Text(
                          "View ETA Details",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF00897B),
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: Color(0xFF00897B),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  etaFooterText,
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    onTap: () => _showAllEtasModal(context),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Text(
                            "View ETA Details",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF00897B),
                            ),
                          ),
                          SizedBox(width: 4),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: Color(0xFF00897B),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRedesignedOperationalContext(bool isMobile, double maxWidth) {
    final int pendingComplaints = (_complaintStatusData['Pending'] ?? 0).toInt();
    final int resolvedComplaints = (_complaintStatusData['Resolved'] ?? 0).toInt();
    final int inProgressComplaints = (_complaintStatusData['In Progress'] ?? 0).toInt();
    final bool hasLimitedActivity = _loadTripsCount == 0;

    final String dateStr = "${DateFormat('MMM dd').format(_selectedDateRange.start)} - ${DateFormat('MMM dd, yyyy').format(_selectedDateRange.end)}";

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: const Color(0xFF00897B).withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00897B).withAlpha(15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.insights_rounded, color: Color(0xFF00897B), size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Operational Context",
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: isMobile ? 15 : 16, color: const Color(0xFF1A1A1A)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Collection performance, community issues & fleet context",
                      style: TextStyle(fontSize: isMobile ? 11 : 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _refreshAllStats(manual: true),
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00897B), size: 20),
                tooltip: "Refresh Operational Context",
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                const Icon(Icons.filter_list_rounded, size: 14, color: Color(0xFF00897B)),
                const SizedBox(width: 6),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Active Filter: Area: $_selectedArea | Period: $dateStr",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade700),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (maxWidth >= 700)
            Row(
              children: [
                Expanded(child: _buildOpMetricCard("Verified visits", "${_visitSummary?.visits.length ?? 0}", "GPS-confirmed, in selected period", Icons.where_to_vote_rounded, const Color(0xFF00897B))),
                const SizedBox(width: 12),
                Expanded(child: _buildOpMetricCard("Pending complaints", "$pendingComplaints", "Open at end of period", Icons.chat_bubble_rounded, const Color(0xFFE53935))),
                const SizedBox(width: 12),
                Expanded(child: _buildOpMetricCard("Resolved complaints", "$resolvedComplaints", "Resolved during period", Icons.check_circle_rounded, const Color(0xFF43A047))),
              ],
            )
          else
            Column(
              children: [
                _buildOpMetricCard("Verified visits", "${_visitSummary?.visits.length ?? 0}", "GPS-confirmed, in selected period", Icons.where_to_vote_rounded, const Color(0xFF00897B)),
                const SizedBox(height: 10),
                _buildOpMetricCard("Pending complaints", "$pendingComplaints", "Open at end of period", Icons.chat_bubble_rounded, const Color(0xFFE53935)),
                const SizedBox(height: 10),
                _buildOpMetricCard("Resolved complaints", "$resolvedComplaints", "Resolved during period", Icons.check_circle_rounded, const Color(0xFF43A047)),
              ],
            ),

          if (hasLimitedActivity) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Limited activity data", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Colors.amber.shade900)),
                        const SizedBox(height: 2),
                        Text("No completed collection trips are recorded for this period. Verify log completeness before assessing performance.",
                            style: TextStyle(fontSize: 11, color: Colors.amber.shade800, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),

          if (maxWidth >= 1000)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: _buildOperationalSummaryBlock()),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: _buildRecommendedChecksBlock()),
              ],
            )
          else
            Column(
              children: [
                _buildOperationalSummaryBlock(),
                const SizedBox(height: 16),
                _buildRecommendedChecksBlock(),
              ],
            ),

          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),

          _buildExpandableSection(
            title: "Coverage & routes",
            subtitle: _visitSummary == null ? "Loading verified visits..." : "$_areasVisitedCount of ${_expectedVisitAreas.length} collection areas had a verified visit",
            isExpanded: _expCoverageRoutes,
            onToggle: () => setState(() => _expCoverageRoutes = !_expCoverageRoutes),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_coverageInsight, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), height: 1.5)),
                const SizedBox(height: 10),
                _detailBullet("Verified visits: ${_visitSummary?.visits.length ?? 0}"),
                _detailBullet("Full loads: $_loadTripsCount"),
                _detailBullet("Distance Covered: ${_distanceCovered.toStringAsFixed(1)} km"),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _buildExpandableSection(
            title: "Community issues",
            subtitle: "$pendingComplaints pending, $inProgressComplaints in progress, $resolvedComplaints resolved",
            isExpanded: _expCommunityIssues,
            onToggle: () => setState(() => _expCommunityIssues = !_expCommunityIssues),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_complaintInsight, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), height: 1.5)),
                const SizedBox(height: 10),
                _detailBullet("Resident complaints: ${_complaintSourceData['Residents']?.toInt() ?? 0}"),
                _detailBullet("Pending: $pendingComplaints  ·  In progress: $inProgressComplaints  ·  Resolved: $resolvedComplaints"),
                _detailBullet("Driver truck issues (not complaints): ${_complaintSourceData['Drivers']?.toInt() ?? 0}"),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _buildExpandableSection(
            title: "Fleet & prediction quality",
            subtitle: "ETA: $_etaWithin5Text | Typical collection time: $_collectionTimeText",
            isExpanded: _expFleetPrediction,
            onToggle: () => setState(() => _expFleetPrediction = !_expFleetPrediction),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fleetInsight, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), height: 1.5)),
                const SizedBox(height: 10),
                _detailBullet("ETA accuracy (measured): $_etaWithin5Text"),
                _detailBullet("ETA Mean Absolute Error (measured): $_etaMaeText"),
                _detailBullet("Typical collection duration (median, start to FULL): $_collectionTimeText"
                    "${_collectionDurationTrips > 0 ? ' over $_collectionDurationTrips trip(s)' : ''}"),
                _detailBullet("Fleet now: ${(_truckStatusData['Active'] ?? 0).toInt()} collecting, ${(_truckStatusData['Full'] ?? 0).toInt()} full, ${(_truckStatusData['Idle'] ?? 0).toInt()} not collecting (paused, offline or completed)"),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _buildExpandableSection(
            title: "Area breakdown",
            subtitle: "${_purokNames.length} service areas (filtered by $_selectedArea)",
            isExpanded: _expAreaBreakdown,
            onToggle: () => setState(() => _expAreaBreakdown = !_expAreaBreakdown),
            content: maxWidth >= 1000 ? _buildAreaTableDesktop() : _buildAreaCardsMobile(),
          ),
          const SizedBox(height: 12),

          _buildExpandableSection(
            title: "Data notes",
            subtitle: "Methodology, stationary sweeping & data snapshot notes",
            isExpanded: _expDataNotes,
            onToggle: () => setState(() => _expDataNotes = !_expDataNotes),
            content: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "• San Nicolas is a stationary sweeping area; it is not assessed using truck-visit expectations.\n"
                  "• Resident complaints and driver incidents are tracked independently and matched to selected date ranges.\n"
                  "• Metrics reflect the active data snapshot and selected analytics filters.",
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF546E7A), height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpMetricCard(String title, String value, String subtitle, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withAlpha(20),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade600)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.grey.shade500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOperationalSummaryBlock() {
    final String dynamicFallback = AnalyticsNarrative.operationalSummary(_narrativeInput());
    final bool showAi = !_isAiLoading && _loadAiIsAi && _loadAiSummary.trim().isNotEmpty;
    final String summaryText = showAi ? "$dynamicFallback\n\nAI summary: ${_loadAiSummary.trim()}" : dynamicFallback;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_rounded, size: 16, color: Color(0xFF00897B)),
              const SizedBox(width: 8),
              const Text("Operational summary", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1A1A1A))),
              const Spacer(),
              if (!_isAiLoading && ((_geminiSummary != null && _geminiSummary!.contains("EXECUTIVE OPERATIONAL CONTEXT REPORT")) || showAi))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(6)),
                  child: const Text("🤖 AI Generated", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF00897B))),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _isAiLoading
              ? _buildShimmer(14, 0.8)
              : Text(
                  _geminiSummary ?? summaryText,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF2C3E50), height: 1.6),
                ),
        ],
      ),
    );
  }

  Widget _buildRecommendedChecksBlock() {
    final List<NarrativeCheck> checks = AnalyticsNarrative.recommendedChecks(_narrativeInput());

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.checklist_rounded, size: 16, color: Color(0xFF00897B)),
              const SizedBox(width: 8),
              Text("Recommended checks", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1A1A1A))),
            ],
          ),
          const SizedBox(height: 14),
          for (int k = 0; k < checks.length; k++) ...<Widget>[
            if (k > 0) const SizedBox(height: 10),
            _checkItem('0${k + 1}', checks[k].title, checks[k].subtitle),
          ],
        ],
      ),
    );
  }

  Widget _checkItem(String num, String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF00897B).withAlpha(15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(num, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Color(0xFF00897B))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExpandableSection({
    required String title,
    required String subtitle,
    required bool isExpanded,
    required VoidCallback onToggle,
    required Widget content,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1A1A1A))),
                        const SizedBox(height: 2),
                        Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  Icon(isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, color: Colors.grey.shade600),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1, color: Color(0xFFEEEEEE)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: content,
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailBullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("• ", style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade700))),
        ],
      ),
    );
  }

  Widget _buildAreaTableDesktop() {
    final List<String> areas = _selectedArea == "All Areas" ? _purokNames : [_selectedArea];
    return Table(
      border: TableBorder.all(color: Colors.grey.shade200, width: 1, borderRadius: BorderRadius.circular(8)),
      columnWidths: const {
        0: FlexColumnWidth(3),
        1: FlexColumnWidth(1.5),
        2: FlexColumnWidth(1.5),
        3: FlexColumnWidth(2),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade50),
          children: const [
            Padding(padding: EdgeInsets.all(12), child: Text("Purok / Area Name", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
            Padding(padding: EdgeInsets.all(12), child: Text("Visits", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
            Padding(padding: EdgeInsets.all(12), child: Text("Complaints", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
            Padding(padding: EdgeInsets.all(12), child: Text("Operational Status", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
          ],
        ),
        ...areas.map((area) {
          int visits = _purokFrequencyData[area] ?? 0;
          int complaints = (_purokComplaintData[area] ?? 0).toInt();
          String status = area == "San Nicolas" ? "Stationary Sweeping Area" : (visits == 0 && complaints == 0 ? "No Activity Recorded" : (complaints > 2 ? "High Priority" : (complaints > 0 ? "Monitoring" : "Stable Operations")));
          Color statusColor = area == "San Nicolas" ? Colors.blueGrey : (visits == 0 && complaints == 0 ? Colors.grey : (complaints > 2 ? Colors.red : (complaints > 0 ? Colors.amber.shade800 : Colors.green)));

          return TableRow(
            children: [
              Padding(padding: const EdgeInsets.all(12), child: Text(area, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
              Padding(padding: const EdgeInsets.all(12), child: Text("$visits", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
              Padding(padding: const EdgeInsets.all(12), child: Text("$complaints", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Expanded(child: Text(status, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: statusColor))),
                  ],
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildAreaCardsMobile() {
    final List<String> areas = _selectedArea == "All Areas" ? _purokNames : [_selectedArea];
    return Column(
      children: areas.map((area) {
        int visits = _purokFrequencyData[area] ?? 0;
        int complaints = (_purokComplaintData[area] ?? 0).toInt();
        String status = area == "San Nicolas" ? "Stationary Sweeping Area" : (visits == 0 && complaints == 0 ? "No Activity Recorded" : (complaints > 2 ? "High Priority" : (complaints > 0 ? "Monitoring" : "Stable Operations")));
        Color statusColor = area == "San Nicolas" ? Colors.blueGrey : (visits == 0 && complaints == 0 ? Colors.grey : (complaints > 2 ? Colors.red : (complaints > 0 ? Colors.amber.shade800 : Colors.green)));

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(area, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A))),
                    const SizedBox(height: 4),
                    Text("Visits: $visits | Complaints: $complaints", style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: statusColor)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPredictionCard(
    String title,
    List<Widget> children, {
    required Color titleColor,
    VoidCallback? onViewDetails,
    String? footerNote,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: titleColor,
                  letterSpacing: -0.2,
                ),
              ),
              if (onViewDetails != null)
                InkWell(
                  onTap: onViewDetails,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "View Details",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: titleColor,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          ...children,
          if (footerNote != null || onViewDetails != null) ...[
            const SizedBox(height: 20),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (footerNote != null)
                  Expanded(
                    child: Text(
                      footerNote,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF94A3B8),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (onViewDetails != null)
                  InkWell(
                    onTap: onViewDetails,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "View Full Details",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: titleColor,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _predictionDetailRow(String label, String value, {required Color themeColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF475569),
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: themeColor,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmer(double height, double widthFactor) {
    return Container(height: height, width: double.infinity, decoration: BoxDecoration(color: Colors.grey.withAlpha(30), borderRadius: BorderRadius.circular(4)));
  }

  Widget _buildEfficiencyCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(16), 
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.grey.shade100)
      ),
      child: Column(children: [
        _insightRow("Typical Collection Time", _collectionTimeText),
        const Divider(height: 16),
        _insightRow("Areas per Trip", _stopsPerRoute > 0 ? "$_stopsPerRoute" : "n/a"),
        const Divider(height: 16),
        _insightRow("Distance Covered", "${_distanceCovered.toStringAsFixed(1)}km"),
        const Divider(height: 16),
        _insightRow("ETA accuracy (measured)", _etaWithin5Text, isSuccess: (EtaEvaluation.summarize(_etaFilteredVisits).within5Pct ?? 0) > 90),
      ]),
    );
  }

  Widget _insightRow(String label, String value, {bool isSuccess = false}) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))), Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: isSuccess ? Colors.green : const Color(0xFF2C3E50)))]));
  }

  Widget _buildTruckDonutChart() {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    final double active = _truckStatusData['Active'] ?? 0;
    final double full = _truckStatusData['Full'] ?? 0;
    final double idle = _truckStatusData['Idle'] ?? 0;
    final double total = active + full + idle;
    if (total == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline_rounded, color: Colors.grey.shade300, size: 40),
            const SizedBox(height: 8),
            const Text("No data matching\nselected filters",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    // When on desktop/web (isMobile is false), we increase the chart size to fill more space inside the card.
    final double radius = isMobile ? 40 : 40;
    final double centerSpaceRadius = isMobile ? 65 : 65;

    return PieChart(PieChartData(sections: [
      if (active > 0) PieChartSectionData(value: active, color: Colors.green, radius: radius, title: '${active.toInt()}', titleStyle: TextStyle(fontSize: isMobile ? 14 : 14, fontWeight: FontWeight.w900, color: Colors.white), titlePositionPercentageOffset: 0.5),
      if (full > 0) PieChartSectionData(value: full, color: Colors.amber, radius: radius, title: '${full.toInt()}', titleStyle: TextStyle(fontSize: isMobile ? 14 : 14, fontWeight: FontWeight.w900, color: Colors.white), titlePositionPercentageOffset: 0.5),
      if (idle > 0) PieChartSectionData(value: idle, color: Colors.grey.shade300, radius: radius, title: '${idle.toInt()}', titleStyle: TextStyle(fontSize: isMobile ? 14 : 14, fontWeight: FontWeight.w900, color: Colors.black54), titlePositionPercentageOffset: 0.5),
    ], centerSpaceRadius: centerSpaceRadius, sectionsSpace: 2));
  }

  Widget _buildComplaintsDonutChart() {
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    final double pending = _complaintStatusData['Pending'] ?? 0;
    final double inProgress = _complaintStatusData['In Progress'] ?? 0;
    final double resolved = _complaintStatusData['Resolved'] ?? 0;

    final double total = pending + inProgress + resolved;
    if (total == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline_rounded, color: Colors.grey.shade300, size: 40),
            const SizedBox(height: 8),
            const Text("No data matching\nselected filters",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    // When on desktop/web (isMobile is false), we increase the chart size to fill more space inside the card.
    final double radius = isMobile ? 40 : 40;
    final double centerSpaceRadius = isMobile ? 65 : 65;

    return PieChart(PieChartData(sections: [
      if (pending > 0)
        PieChartSectionData(
          value: pending, color: Colors.red, radius: radius,
          title: '${pending.toInt()}', titleStyle: TextStyle(fontSize: isMobile ? 14 : 14, fontWeight: FontWeight.w900, color: Colors.white),
          titlePositionPercentageOffset: 0.5,
        ),
      if (inProgress > 0)
        PieChartSectionData(
          value: inProgress, color: Colors.blue, radius: radius,
          title: '${inProgress.toInt()}', titleStyle: TextStyle(fontSize: isMobile ? 14 : 14, fontWeight: FontWeight.w900, color: Colors.white),
          titlePositionPercentageOffset: 0.5,
        ),
      if (resolved > 0)
        PieChartSectionData(
          value: resolved, color: Colors.green, radius: radius,
          title: '${resolved.toInt()}', titleStyle: TextStyle(fontSize: isMobile ? 14 : 14, fontWeight: FontWeight.w900, color: Colors.white),
          titlePositionPercentageOffset: 0.5,
        ),
    ], centerSpaceRadius: centerSpaceRadius, sectionsSpace: 2));
  }

  Widget _buildPurokBarChart() {
    final areas = ["P1", "P.Para", "Riverside", "Kalaw", "Ayala", "Brixton", "ElPueblo", "SNicolas", "Paraiso", "P2", "P3"];
    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceAround, maxY: 100,
      titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, m) => Padding(padding: const EdgeInsets.only(top: 12), child: Text(v.toInt() < areas.length ? areas[v.toInt()] : "", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800))))), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 30, getTitlesWidget: (v, m) => Text("${v.toInt()}%", style: const TextStyle(fontSize: 10))))),
      gridData: const FlGridData(show: true, drawVerticalLine: false), borderData: FlBorderData(show: false),
      barGroups: List.generate(areas.length, (index) {
        final count = index < _purokNames.length ? (_purokFrequencyData[_purokNames[index]] ?? 0) : 0;
        return BarChartGroupData(x: index, barRods: [BarChartRodData(toY: count.toDouble(), color: const Color(0xFF2196F3), width: 14, borderRadius: const BorderRadius.vertical(top: Radius.circular(4)))]);
      }),
    ));
  }

  void _showAreaSelection(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 900;

    Widget content(BuildContext context) => Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: isMobile ? const BorderRadius.vertical(top: Radius.circular(32)) : BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isMobile) Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 24), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)))),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Select Area Filter", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.grey),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text("Select a specific Purok to filter the analytics data.", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
          const Divider(height: 32),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
            child: ListView(
              shrinkWrap: true,
              children: ["All Areas", ..._purokNames].map((area) {
                bool isSelected = area == _selectedArea;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedArea = area);
                      refreshAllData();
                      Navigator.pop(context);
                      
                      // Show success notification
                      CustomNotification.showTopNotification(context, "Filtered by $area", false);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFFE0F2F1) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isSelected ? const Color(0xFF00BFA5) : Colors.grey.shade200, width: 1.5),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(area, style: TextStyle(fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600, color: isSelected ? const Color(0xFF00897B) : const Color(0xFF2C3E50))),
                          if (isSelected) const Icon(Icons.check_circle, color: Color(0xFF00BFA5), size: 20),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList()
            )
          ),
          const SizedBox(height: 8),
        ]
      ),
    );

    if (isMobile) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => content(context),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: SizedBox(width: 400, child: content(context)),
        ),
      );
    }
  }

  void _showExportDialog(BuildContext context) {
    String selectedCategory = "Full System Report";
    String selectedFormat = "PDF Document (.pdf)";

    Widget content(BuildContext context, StateSetter setDialogState) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Export Reports", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.grey),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text("Generate and download comprehensive system performance reports.", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
          const Divider(height: 32),
          _exportDropdown("Report Category", ["Full System Report", "Truck Performance", "Area Coverage"], selectedCategory, (val) {
            if (val != null) setDialogState(() => selectedCategory = val);
          }),
          const SizedBox(height: 16),
          _exportDropdown("File Format", ["PDF Document (.pdf)", "Excel Spreadsheet (.xlsx)"], selectedFormat, (val) {
            if (val != null) setDialogState(() => selectedFormat = val);
          }),
          const SizedBox(height: 16),
          _exportSummary(selectedCategory, selectedFormat),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _exportReport(selectedCategory, selectedFormat);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00897B),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(double.infinity, 50),
            ),
            child: const Text("DOWNLOAD REPORT", style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      );
    }

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: StatefulBuilder(
              builder: (context, setDialogState) => content(context, setDialogState),
            ),
          ),
        ),
      ),
    );
  }

  /// States exactly what will be downloaded, so the category, area and period are never a guess.
  Widget _exportSummary(String category, String format) {
    final bool excel = format.contains('Excel');
    final ReportCategory kind = ReportCategoryLabel.parse(category);
    final String period = '${DateFormat('MMM d, yyyy').format(_selectedDateRange.start)} – ${DateFormat('MMM d, yyyy').format(_selectedDateRange.end)}';
    final String contents = excel
        ? kind.contents
        : 'the complete analytics report, organized by the study objectives: GPS tracking and notifications, analytics, '
            'and predictive models (every section, whichever category is chosen)';
    Widget line(IconData icon, String text, {bool strong = false}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Icon(icon, size: 16, color: const Color(0xFF00796B)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12.5, height: 1.35, color: const Color(0xFF1F2937), fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
            ),
          ]),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE0F2F1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFB2DFDB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text('YOU WILL DOWNLOAD', style: TextStyle(fontSize: 10.5, letterSpacing: 0.8, fontWeight: FontWeight.w900, color: Color(0xFF00695C))),
        line(excel ? Icons.grid_on_rounded : Icons.picture_as_pdf_rounded,
            excel ? '${kind.label} (Excel)' : 'Analytics report (PDF)', strong: true),
        line(Icons.place_rounded, _selectedArea),
        line(Icons.calendar_month_rounded, period),
        line(Icons.list_alt_rounded, 'Contains $contents'),
      ]),
    );
  }

  Widget _exportDropdown(String hint, List<String> items, String currentVal, ValueChanged<String?> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16), 
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(12), 
        border: Border.all(color: Colors.grey.shade200)
      ), 
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          dropdownColor: Colors.white,
          value: currentVal, 
          hint: Text(hint), 
          isExpanded: true, 
          items: items.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontWeight: FontWeight.w600)))).toList(), 
          onChanged: onChanged
        )
      )
    );
  }
}

class _OperationalInsightsModal extends StatefulWidget {
  final Map<String, int> frequencyData;
  final Map<String, int> visitData;
  final Map<String, int> complaintData;
  final int completedRoutes;
  final int totalRoutes;
  final Map<String, double> complaintStatusData;
  final Map<String, double> complaintSourceData;
  final String selectedArea;
  final DateTimeRange selectedDateRange;
  final List<String> purokNames;
  final String? geminiSummary;
  final String? recommendations;
  final bool isAiLoading;
  final Future<void> Function() onRefresh;

  const _OperationalInsightsModal({
    required this.frequencyData,
    required this.visitData,
    required this.complaintData,
    required this.completedRoutes,
    required this.totalRoutes,
    required this.complaintStatusData,
    required this.complaintSourceData,
    required this.selectedArea,
    required this.selectedDateRange,
    required this.purokNames,
    this.geminiSummary,
    this.recommendations,
    required this.isAiLoading,
    required this.onRefresh,
  });

  @override
  State<_OperationalInsightsModal> createState() => _OperationalInsightsModalState();
}

class _OperationalInsightsModalState extends State<_OperationalInsightsModal> with SingleTickerProviderStateMixin {
  int _selectedTab = 0; // 0: Overview, 1: Area details, 2: Actions
  bool _isRefreshing = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final bool isMobileOrNarrow = width < 600;
        final bool isTablet = width >= 600 && width < 1000;
        final bool isDesktop = width >= 1000;

        final double padding = isMobileOrNarrow ? 16.0 : (isTablet ? 24.0 : 32.0);

        final List<String> activeAreas = widget.selectedArea == "All Areas" ? widget.purokNames : [widget.selectedArea];
        int totalVisits = activeAreas.fold(0, (sum, area) => sum + (widget.visitData[area] ?? 0));
        int totalComplaints = activeAreas.fold(0, (sum, area) => sum + (widget.complaintData[area] ?? 0));

        int areasToReview = widget.purokNames.where((area) {
          int c = widget.complaintData[area] ?? 0;
          return c > 2;
        }).length;

        final String dateStr = "${DateFormat('MMM dd').format(widget.selectedDateRange.start)} - ${DateFormat('MMM dd, yyyy').format(widget.selectedDateRange.end)}";

        return Container(
          padding: EdgeInsets.all(padding),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: isMobileOrNarrow ? BorderRadius.zero : BorderRadius.circular(32),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00897B).withAlpha(15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF00897B), size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Operational Insights",
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          "Purok coverage & resident complaints",
                          style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: Text(
                                "📍 ${widget.selectedArea} • $dateStr",
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade700),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0F2F1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                "AI-generated • Review recommended",
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF00897B)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: _isRefreshing ? null : () async {
                          setState(() => _isRefreshing = true);
                          await widget.onRefresh();
                          if (mounted) setState(() => _isRefreshing = false);
                        },
                        icon: _isRefreshing
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00897B)))
                            : const Icon(Icons.refresh_rounded, color: Color(0xFF00897B), size: 20),
                        tooltip: "Refresh",
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, color: Colors.black54, size: 24),
                        tooltip: "Close",
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _metricCard(
                      "Recorded visits",
                      "$totalVisits",
                      Icons.local_shipping_rounded,
                      const Color(0xFF00796B),
                      const Color(0xFFEBF7F6),
                      const Color(0xFFB2DFDB),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _metricCard(
                      "Resident complaints",
                      "$totalComplaints",
                      Icons.chat_bubble_rounded,
                      const Color(0xFFE53935),
                      const Color(0xFFFDF0F0),
                      const Color(0xFFFFCDD2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _metricCard(
                      areasToReview == 1 ? "Areas to review" : "Areas to review",
                      "$areasToReview",
                      Icons.warning_amber_rounded,
                      const Color(0xFFF57C00),
                      const Color(0xFFFFF8E1),
                      const Color(0xFFFFE0B2),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F4F7),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Expanded(child: _tabButton(0, "Overview", Icons.grid_view_rounded)),
                    Expanded(child: _tabButton(1, "Area details", Icons.table_chart_rounded)),
                    Expanded(child: _tabButton(2, "Actions", Icons.fact_check_rounded)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: widget.isAiLoading && widget.geminiSummary == null
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Color(0xFF00897B)),
                            SizedBox(height: 16),
                            Text("Analyzing operational data...", style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: _buildSelectedTabContent(isDesktop),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _metricCard(String title, String value, IconData icon, Color color, Color bgColor, Color borderColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 2,
                    softWrap: true,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2C3E50),
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: color,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(int index, String title, IconData icon) {
    final bool isSelected = _selectedTab == index;
    return InkWell(
      onTap: () => setState(() => _selectedTab = index),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? const Color(0xFF00897B) : Colors.grey.shade600,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  color: isSelected ? const Color(0xFF00897B) : Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedTabContent(bool isDesktop) {
    switch (_selectedTab) {
      case 0:
        return _buildOverviewTab(isDesktop);
      case 1:
        return _buildAreaDetailsTab(isDesktop);
      case 2:
        return _buildActionsTab();
      default:
        return _buildOverviewTab(isDesktop);
    }
  }

  Widget _buildOverviewTab(bool isDesktop) {
    final List<String> activeAreas = widget.selectedArea == "All Areas" ? widget.purokNames : [widget.selectedArea];
    int totalVisits = activeAreas.fold(0, (sum, area) => sum + (widget.visitData[area] ?? 0));
    int totalComplaints = activeAreas.fold(0, (sum, area) => sum + (widget.complaintData[area] ?? 0));

    String needReviewArea = "";
    int needReviewComplaints = 0;
    int needReviewVisits = 0;
    widget.purokNames.forEach((area) {
      int c = widget.complaintData[area] ?? 0;
      if (c > 2) {
        needReviewArea = area;
        needReviewComplaints = c;
        needReviewVisits = widget.visitData[area] ?? 0;
      }
    });

    final int zeroVisitCount = activeAreas.where((a) => (widget.visitData[a] ?? 0) == 0 && a != "San Nicolas").length;
    final String summaryText = (widget.geminiSummary != null && widget.geminiSummary!.isNotEmpty && !widget.geminiSummary!.contains("Unable to generate"))
        ? widget.geminiSummary!
        : AnalyticsNarrative.areaSummary(
            area: widget.selectedArea,
            visits: totalVisits,
            complaints: totalComplaints,
            needsReviewArea: needReviewArea,
            needsReviewComplaints: needReviewComplaints,
            needsReviewVisits: needReviewVisits,
            zeroVisitAreas: zeroVisitCount,
            activeAreas: activeAreas.length,
          );
    final String limitationsText = AnalyticsNarrative.limitationLines(
      area: widget.selectedArea,
      activeAreas: activeAreas.length,
      zeroVisitAreas: zeroVisitCount,
    ).join('\n');

    final leftWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F9FA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.description_rounded, size: 16, color: Color(0xFF00897B)),
                  SizedBox(width: 8),
                  Text("Summary", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1A1A1A))),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                summaryText,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF2C3E50), height: 1.6),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (needReviewArea.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.amber.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("$needReviewArea needs review", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Colors.amber.shade900)),
                      const SizedBox(height: 2),
                      Text("$needReviewVisits visits • $needReviewComplaints complaints", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.amber.shade800)),
                      const SizedBox(height: 4),
                      const Text("The records do not establish the cause of complaints.", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF546E7A))),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () => setState(() => _selectedTab = 1),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text("View supporting reports", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
                            SizedBox(width: 4),
                            Icon(Icons.arrow_forward_rounded, size: 14, color: Color(0xFF00897B)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F9FA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 16, color: Color(0xFF00897B)),
                  SizedBox(width: 8),
                  Text("Recommended next steps", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1A1A1A))),
                ],
              ),
              const SizedBox(height: 14),
              _checkItem("01", "Review unresolved reports", "Confirm locations, categories and reported dates."),
              const SizedBox(height: 12),
              _checkItem("02", "Verify collection records", "Compare recorded trips with assigned service."),
            ],
          ),
        ),
      ],
    );

    final rightWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: AppTheme.balancedPulidongShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Area snapshot", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF1A1A1A))),
                  InkWell(
                    onTap: () => setState(() => _selectedTab = 1),
                    child: const Text("View all 10 areas", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF00897B))),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Table(
                columnWidths: const {
                  0: FlexColumnWidth(3),
                  1: FlexColumnWidth(1),
                  2: FlexColumnWidth(1.2),
                },
                children: [
                  TableRow(
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.shade200))),
                    children: const [
                      Padding(padding: EdgeInsets.only(bottom: 8), child: Text("Area", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: Colors.grey))),
                      Padding(padding: EdgeInsets.only(bottom: 8), child: Text("Visits", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: Colors.grey))),
                      Padding(padding: EdgeInsets.only(bottom: 8), child: Text("Complaints", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: Colors.grey))),
                    ],
                  ),
                  ...widget.purokNames.take(4).map((area) {
                    int visits = widget.visitData[area] ?? 0;
                    int complaints = widget.complaintData[area] ?? 0;
                    return TableRow(
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.shade100))),
                      children: [
                        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(area, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
                        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text("$visits", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
                        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text("$complaints", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
                      ],
                    );
                  }),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _selectedTab = 1),
                  child: const Text("View all 10 areas →", style: TextStyle(color: Color(0xFF00897B), fontWeight: FontWeight.w900, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F9FA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF00897B)),
                  SizedBox(width: 8),
                  Text("Data limitations", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1A1A1A))),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                limitationsText,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF546E7A), height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );

    if (isDesktop) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: leftWidget),
          const SizedBox(width: 20),
          Expanded(flex: 2, child: rightWidget),
        ],
      );
    } else {
      return Column(
        children: [
          leftWidget,
          const SizedBox(height: 16),
          rightWidget,
        ],
      );
    }
  }

  Widget _checkItem(String num, String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF00897B).withAlpha(15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(num, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Color(0xFF00897B))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAreaDetailsTab(bool isDesktop) {
    final List<String> areas = widget.selectedArea == "All Areas" ? widget.purokNames : [widget.selectedArea];
    final bool isNarrow = MediaQuery.of(context).size.width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.table_chart_rounded, size: 18, color: Color(0xFF00897B)),
            const SizedBox(width: 8),
            const Text("Verified Service Areas (10 Areas)", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
          ],
        ),
        const SizedBox(height: 4),
        Text("Subject to selected area filter & evidence-based review status.", style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
        const SizedBox(height: 16),
        if (!isNarrow && isDesktop)
          Table(
            border: TableBorder.all(color: Colors.grey.shade200, width: 1, borderRadius: BorderRadius.circular(12)),
            columnWidths: const {
              0: FlexColumnWidth(3),
              1: FlexColumnWidth(1.2),
              2: FlexColumnWidth(1.2),
              3: FlexColumnWidth(2.2),
            },
            children: [
              TableRow(
                decoration: BoxDecoration(color: Colors.grey.shade50),
                children: const [
                  Padding(padding: EdgeInsets.all(12), child: Text("Area Name", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
                  Padding(padding: EdgeInsets.all(12), child: Text("Visits", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
                  Padding(padding: EdgeInsets.all(12), child: Text("Complaints", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
                  Padding(padding: EdgeInsets.all(12), child: Text("Review Status", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF1A1A1A)))),
                ],
              ),
              ...areas.map((area) {
                int visits = widget.visitData[area] ?? 0;
                int complaints = widget.complaintData[area] ?? 0;
                String visitStr = area == "San Nicolas" ? "-" : "$visits";
                String status = area == "San Nicolas" ? "Stationary Sweeping Area" : (visits == 0 && complaints == 0 ? "Optimal" : (complaints > 2 ? "High Priority" : (complaints > 0 ? "Monitoring" : "Optimal")));
                Color statusColor = area == "San Nicolas" ? Colors.blueGrey : (complaints > 2 ? Colors.red : (complaints > 0 ? Colors.amber.shade800 : Colors.green));

                return TableRow(
                  children: [
                    Padding(padding: const EdgeInsets.all(12), child: Text(area, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
                    Padding(padding: const EdgeInsets.all(12), child: Text(visitStr, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
                    Padding(padding: const EdgeInsets.all(12), child: Text("$complaints", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF2C3E50)))),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          Expanded(child: Text(status, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: statusColor))),
                        ],
                      ),
                    ),
                  ],
                );
              }),
            ],
          )
        else
          Column(
            children: areas.map((area) {
              int visits = widget.visitData[area] ?? 0;
              int complaints = widget.complaintData[area] ?? 0;
              String visitStr = area == "San Nicolas" ? "-" : "$visits";
              String status = area == "San Nicolas" ? "Stationary Sweeping Area" : (complaints > 2 ? "High Priority" : (complaints > 0 ? "Monitoring" : "Optimal"));
              Color statusColor = area == "San Nicolas" ? Colors.blueGrey : (complaints > 2 ? Colors.red : (complaints > 0 ? Colors.amber.shade800 : Colors.green));

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(area, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A))),
                          const SizedBox(height: 4),
                          Text("Visits: $visitStr | Complaints: $complaints", style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withAlpha(20),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: statusColor)),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  List<Map<String, dynamic>> _getDynamicRecommendations() {
    final List<Map<String, dynamic>> recs = [];

    // 1. Check for high complaint areas in widget.complaintData
    String highComplaintArea = "";
    int highComplaints = 0;
    widget.complaintData.forEach((area, complaints) {
      if (complaints > highComplaints) {
        highComplaints = complaints;
        highComplaintArea = area;
      }
    });

    if (highComplaints > 0 && highComplaintArea.isNotEmpty) {
      recs.add({
        "title": "Address service backlog in $highComplaintArea",
        "evidence": "Analytics detected $highComplaints resident feedback reports in $highComplaintArea sector. Review collection logs.",
        "priority": highComplaints > 2 ? "Priority: High" : "Priority: Medium",
        "color": highComplaints > 2 ? Colors.red : Colors.amber.shade800,
      });
    }

    // 2. Check for zero or low visit areas
    List<String> lowVisitAreas = [];
    widget.visitData.forEach((area, visits) {
      if (visits == 0 && area != "San Nicolas") {
        lowVisitAreas.add(area);
      }
    });

    if (lowVisitAreas.isNotEmpty) {
      recs.add({
        "title": "Verify coverage for ${lowVisitAreas.first}",
        "evidence": "Zero recorded collection visits during the selected period. Confirm if service was missed or pending.",
        "priority": "Priority: Medium",
        "color": Colors.amber.shade800,
      });
    }

    // 3. If AI recommendations are provided and not default, parse or append them
    if (widget.recommendations != null &&
        widget.recommendations!.isNotEmpty &&
        !widget.recommendations!.contains("Analyzing fleet")) {
      final lines = widget.recommendations!
          .split(RegExp(r'\n|[*-]|\d+\.\s+'))
          .map((e) => e.trim())
          .where((e) => e.length > 10)
          .toList();

      for (int i = 0; i < lines.length && i < 3; i++) {
        String line = lines[i];
        if (!recs.any((r) => r['title']!.toString().toLowerCase().contains(line.substring(0, math.min(10, line.length)).toLowerCase()))) {
          recs.add({
            "title": line.length > 60 ? "${line.substring(0, 57)}..." : line,
            "evidence": "AI-generated advisory recommendation based on current operational telemetry.",
            "priority": i == 0 ? "Priority: High" : (i == 1 ? "Priority: Medium" : "Priority: Normal"),
            "color": i == 0 ? Colors.red : (i == 1 ? Colors.amber.shade800 : const Color(0xFF00897B)),
          });
        }
      }
    }

    // Ensure we always have at least 3 recommendations
    if (recs.length < 3) {
      recs.add({
        "title": "Optimize morning route intervals",
        "evidence": "Reduce idle wait times during transit between distant puroks across ${widget.selectedArea}.",
        "priority": "Priority: Medium",
        "color": Colors.amber.shade800,
      });
    }
    if (recs.length < 3) {
      recs.add({
        "title": "Conduct weekly driver briefings",
        "evidence": "Reinforce punctuality and complete coverage verification for all assigned units.",
        "priority": "Priority: Normal",
        "color": const Color(0xFF00897B),
      });
    }

    return recs.take(4).toList();
  }

  Widget _buildActionsTab() {
    final recommendationsList = _getDynamicRecommendations();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.checklist_rounded, size: 18, color: Color(0xFF00897B)),
                SizedBox(width: 8),
                Text("Advisory Recommendations", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
              ],
            ),
            if (widget.isAiLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00897B)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text("AI-generated and adaptive telemetry recommendations for ${widget.selectedArea}.", style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
        const SizedBox(height: 16),
        ...recommendationsList.asMap().entries.map((entry) {
          int index = entry.key + 1;
          var rec = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _actionRecommendationCard(
              index.toString().padLeft(2, '0'),
              rec['title'].toString(),
              rec['evidence'].toString(),
              rec['priority'].toString(),
              rec['color'] as Color,
            ),
          );
        }),
      ],
    );
  }

  Widget _actionRecommendationCard(String num, String title, String evidence, String priority, Color priorityColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: AppTheme.balancedPulidongShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF00897B).withAlpha(15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(num, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF00897B))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1A1A1A)))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: priorityColor.withAlpha(20),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(priority, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: priorityColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(evidence, style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w500, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the Load History dialog (the same widget the Waste Collection Summary uses).
/// [date] opens it on that collection day and [highlightTripId] marks one trip, so
/// Route History can land on the exact related load.
Future<void> showLoadHistoryDialog(
  BuildContext context, {
  DateTime? date,
  String? highlightTripId,
  VoidCallback? onDataUpdated,
  OpenRouteHistory? onOpenRouteHistory,
}) {
  final double width = MediaQuery.of(context).size.width;
  final Widget content = LoadHistoryDialogModal(
    isMobile: width < 600,
    onDataUpdated: onDataUpdated,
    initialDate: date,
    highlightTripId: highlightTripId,
    onOpenRouteHistory: onOpenRouteHistory,
  );

  if (width < 600) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Load History",
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, anim1, anim2) => SafeArea(
        child: Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: content,
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.min(width - 40, 720), maxHeight: 720),
        child: content,
      ),
    ),
  );
}

class LoadHistoryDialogModal extends StatefulWidget {
  final ScrollController? scrollController;
  final bool isMobile;
  final VoidCallback? onDataUpdated;

  /// Day to open on (defaults to today) and the trip to highlight, when the dialog is
  /// opened from a specific Route History trip.
  final DateTime? initialDate;
  final String? highlightTripId;

  /// Opens a trip's route in the host shell (instead of a separate full page).
  final OpenRouteHistory? onOpenRouteHistory;

  const LoadHistoryDialogModal({
    Key? key,
    this.scrollController,
    this.isMobile = false,
    this.onDataUpdated,
    this.initialDate,
    this.highlightTripId,
    this.onOpenRouteHistory,
  }) : super(key: key);

  @override
  State<LoadHistoryDialogModal> createState() => _LoadHistoryDialogModalState();
}

class _LoadHistoryDialogModalState extends State<LoadHistoryDialogModal> {
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = true;
  List<DriverTrip> _dayTrips = [];
  final LoadHistoryRepository _repository = LoadHistoryRepository.standard();
  String? _loadError;
  int _unfinishedCount = 0;
  int _ongoingCount = 0;
  bool _partial = false;
  bool _highlightMissing = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialDate != null) _selectedDate = widget.initialDate!;
    _fetchData();
  }

  Future<void> _fetchData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final DateTime day = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      // The SAME repository and the SAME finalized-collection rules as the Waste
      // Collection Summary; only the date filter differs (this dialog shows one day).
      final LoadHistoryResult result = await _repository.load(start: day, end: day);

      if (result.isError) {
        if (mounted) {
          setState(() => _loadError = "Collection data could not be loaded. Check the connection and try again.");
        }
      } else {
        final List<DriverTrip> dayLoads = LoadHistory.inRange(result.loads, day, day);
        // Chronological (earliest FULL = Trip 1).
        dayLoads.sort((a, b) => LoadHistory.eventTime(a).compareTo(LoadHistory.eventTime(b)));
        final unfinishedSplit =
            LoadHistory.splitUnfinished(LoadHistory.inRange(result.unfinished, day, day), DateTime.now());
        final int unfinished = unfinishedSplit.ongoing.length + unfinishedSplit.stale.length;
        final int ongoing = unfinishedSplit.ongoing.length;
        if (mounted) {
          setState(() {
            _dayTrips = dayLoads;
            _highlightMissing = widget.highlightTripId != null &&
                !dayLoads.any((DriverTrip t) => t.tripId == widget.highlightTripId);
            _unfinishedCount = unfinished;
            _ongoingCount = ongoing;
            _partial = result.isPartial;
          });
        }
      }
    } catch (e) {
      debugPrint("[LOAD HISTORY MODAL] Error fetching trips: $e");
      if (mounted) setState(() => _loadError = "Collection data could not be loaded. Please try again.");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int get _totalTripsCount => _dayTrips.length;

  double get _totalCollectedKg {
    return _dayTrips.fold(0.0, (sum, t) => sum + t.weightKg);
  }

  double get _totalCollectedTons => _totalCollectedKg / 1000.0;

  bool get _hasCustomMeasuredWeights {
    return _dayTrips.any((t) => t.isMeasured);
  }

  int get _customMeasuredCount {
    return _dayTrips.where((t) => t.isMeasured).length;
  }

  Future<List<String>> _resolveVisitedAreas(DriverTrip trip) async {
    final List<String> result = [];

    // 1. Check trip.visitedAreas
    if (trip.visitedAreas.isNotEmpty) {
      for (var a in trip.visitedAreas) {
        final canonical = ServiceAreaService.canonicalizeAreaName(a);
        final name = canonical ?? a.trim();
        if (name.isNotEmpty && !result.contains(name) && name != "Collection Route" && name != "Not recorded") {
          result.add(name);
        }
      }
    }

    // 2. If empty, match trip GPS points against saved admin service areas
    if (result.isEmpty && trip.points.isNotEmpty) {
      try {
        final areas = await ServiceAreaService().getAllServiceAreas();
        for (var sa in areas) {
          bool passed = false;
          for (var pt in trip.points) {
            if (pt.latitude == 0.0 && pt.longitude == 0.0) continue;

            final distM = DriverTrip.haversineDistance(
              pt.latitude, pt.longitude,
              sa.latitude, sa.longitude,
            ) * 1000;

            final threshold = math.max(sa.radius, 100.0);
            if (distM <= threshold) {
              passed = true;
              break;
            }

            if (sa.endLat != null && sa.endLng != null) {
              final dEnt = DriverTrip.haversineDistance(pt.latitude, pt.longitude, sa.entranceLat, sa.entranceLng) * 1000;
              final dEnd = DriverTrip.haversineDistance(pt.latitude, pt.longitude, sa.endLat!, sa.endLng!) * 1000;
              if (dEnt <= 100.0 || dEnd <= 100.0) {
                passed = true;
                break;
              }
            }
          }

          if (passed && !result.contains(sa.name)) {
            result.add(sa.name);
          }
        }
      } catch (e) {
        debugPrint("[LOAD HISTORY MODAL] Error resolving GPS areas: $e");
      }
    }

    return result;
  }

  void _showEditWeightDialog(BuildContext context, DriverTrip trip, String tripLabel) {
    final TextEditingController ctrl = TextEditingController(
      text: trip.weightKg.toInt().toString(),
    );
    double liveKg = trip.weightKg;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE6F5F2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.scale_rounded, color: Color(0xFF00796B), size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Edit Trip Weight",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "$tripLabel · ${DateFormat('MMM d, yyyy').format((trip.fullTime ?? trip.startTime).toLocal())}",
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Enter measured scale reading in kilograms:",
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      autofocus: true,
                      onChanged: (val) {
                        final parsed = double.tryParse(val.trim());
                        if (parsed != null && parsed >= 0) {
                          setDialogState(() => liveKg = parsed);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: "Measured Weight",
                        suffixText: "kg",
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF00796B), width: 2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE6F5F2),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFC5E8E2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF00796B)),
                          const SizedBox(width: 8),
                          Text(
                            "Converted: ${(liveKg / 1000.0).toStringAsFixed(2)} tons",
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF00796B)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF64748B),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text("CANCEL", style: TextStyle(fontWeight: FontWeight.w800)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: () async {
                              final newKg = double.tryParse(ctrl.text.trim());
                              if (newKg == null || newKg < 0) {
                                CustomSnackBar.show(context, message: "Please enter a valid non-negative weight.", isError: true);
                                return;
                              }
                              Navigator.pop(dialogContext);

                              // Optimistically update local state immediately for instant re-render
                              if (mounted) {
                                setState(() {
                                  final idx = _dayTrips.indexWhere((t) => t.tripId == trip.tripId);
                                  if (idx != -1) {
                                    _dayTrips[idx] = _dayTrips[idx].copyWith(
                                      weightKg: newKg,
                                      weightType: 'MEASURED',
                                    );
                                  }
                                });
                              }

                              try {
                                await ApiService().updateTripWeight(
                                  tripId: trip.tripId,
                                  weightKg: newKg,
                                );

                                try {
                                  await FirebaseDatabase.instance.ref('load_history/${trip.tripId}').update({
                                    'trip_id': trip.tripId,
                                    'weight_kg': newKg,
                                    'weight_type': 'MEASURED',
                                    'driver_name': trip.driverName,
                                    'truck_id': trip.truckId,
                                    'full_time': trip.fullTimeDisplay,
                                    'created_at': trip.startTime.toIso8601String(),
                                    'visited_areas': trip.visitedAreas,
                                  });
                                  await FirebaseDatabase.instance.ref('driver_routes/${trip.tripId}').update({
                                    'weight_kg': newKg,
                                    'weight_type': 'MEASURED',
                                    'weightKg': newKg,
                                    'weightType': 'MEASURED',
                                  });
                                } catch (_) {}

                                CustomNotification.showTopNotification(
                                  context,
                                  "Trip weight updated to ${newKg.toInt()} kg (${(newKg / 1000.0).toStringAsFixed(1)} tons)",
                                  false,
                                );

                                await _fetchData();
                                widget.onDataUpdated?.call();
                              } catch (e) {
                                CustomSnackBar.show(context, message: "Failed to save trip weight.", isError: true);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00796B),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text("SAVE WEIGHT", style: TextStyle(fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(widget.isMobile ? 16 : 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: widget.isMobile
            ? const BorderRadius.vertical(top: Radius.circular(24))
            : BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      "Load History",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.4,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      "Recorded trips from GIS Route History",
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Color(0xFF0F172A), size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Date Filter Field
          _buildDateFilterField(context),
          const SizedBox(height: 16),

          // Estimated / Measured Waste Summary Box
          _buildEstimatedWasteSummaryCard(widget.isMobile),
          const SizedBox(height: 20),

          // Trips Table Section
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00796B)))
                : SingleChildScrollView(
                    child: _buildTripsTable(widget.isMobile),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateFilterField(BuildContext context) {
    final String dateStr = DateFormat('MMM d, yyyy').format(_selectedDate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Date",
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () async {
            final DateTime? picked = await showAppSingleDatePicker(context, initialDate: _selectedDate);

            if (picked != null && (picked.year != _selectedDate.year || picked.month != _selectedDate.month || picked.day != _selectedDate.day)) {
              setState(() {
                _selectedDate = picked;
              });
              _fetchData();
            }
          },
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD1E5E1), width: 1.2),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_rounded, size: 18, color: Color(0xFF00796B)),
                const SizedBox(width: 10),
                Text(
                  dateStr,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.arrow_drop_down_rounded, size: 22, color: Color(0xFF64748B)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEstimatedWasteSummaryCard(bool isMobile) {
    final String kgFormatted = NumberFormat.decimalPattern().format(_totalCollectedKg.toInt());
    final String tonsStr = (_totalCollectedTons % 1 == 0)
        ? _totalCollectedTons.toInt().toString()
        : _totalCollectedTons.toStringAsFixed(1);

    final bool isMeasuredMode = _hasCustomMeasuredWeights;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isMobile ? 16 : 20),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F5F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC5E8E2), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pill Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isMeasuredMode ? const Color(0xFFD1FAE5) : const Color(0xFFD4F0EB),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isMeasuredMode ? "Measured" : "Estimate",
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: isMeasuredMode ? const Color(0xFF059669) : const Color(0xFF0A6054),
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Headline
          Text(
            isMeasuredMode
                ? "$_totalTripsCount trips = $kgFormatted kg"
                : "$_totalTripsCount trips × 5,000 kg = $kgFormatted kg",
            style: TextStyle(
              fontSize: isMobile ? 21 : 25,
              fontWeight: FontWeight.w900,
              color: const Color(0xFF0B4D43),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),

          // Subheadline
          Text(
            isMeasuredMode
                ? "Collected waste · $tonsStr tons"
                : "Estimated collected waste · $tonsStr tons",
            style: TextStyle(
              fontSize: isMobile ? 13 : 14.5,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF0F4D44),
            ),
          ),
          const SizedBox(height: 8),
          if (_unfinishedCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                "Not counted until the truck is marked FULL: $_ongoingCount ongoing, "
                "${_unfinishedCount - _ongoingCount} stale or legacy (no recent activity).",
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
              ),
            ),
          if (_highlightMissing)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                "No finalized load record was found for trip ${widget.highlightTripId} on this date.",
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB91C1C)),
              ),
            ),
          if (_partial)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                "Some collection sources could not be reached; this list may be incomplete.",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFB45309)),
              ),
            ),

          // Caption
          Text(
            isMeasuredMode
                ? "Includes custom measured scale readings for $_customMeasuredCount trip(s)."
                : "Based on the barangay estimate of 5 tons per finished trip.",
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF527C75),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTripsTable(bool isMobile) {
    if (_loadError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline_rounded, size: 34, color: Color(0xFFDC2626)),
            const SizedBox(height: 10),
            Text(_loadError!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF991B1B))),
            const SizedBox(height: 8),
            TextButton(onPressed: _fetchData, child: const Text("Retry")),
          ],
        ),
      );
    }
    if (_dayTrips.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2ECE9)),
        ),
        child: Column(
          children: const [
            Icon(Icons.inventory_2_outlined, size: 36, color: Color(0xFF94A3B8)),
            SizedBox(height: 10),
            Text(
              "No finalized collection trips for this date.",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2ECE9)),
          ),
          child: Column(
            children: [
              // Header Row
              Container(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 12),
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F7F6),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  border: Border(bottom: BorderSide(color: Color(0xFFE2ECE9))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        isMobile ? "Trip" : "Trip number",
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        "Date",
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        isMobile ? "km" : "Distance",
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        "Duration",
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        "Weight",
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                      ),
                    ),
                    const SizedBox(width: 24),
                  ],
                ),
              ),

              // Table Rows
              ...List.generate(_dayTrips.length, (index) {
                final trip = _dayTrips[index];
                final tripLabel = "Trip ${index + 1}";
                final isTopRow = index == 0;

                final String dateDisplay = isMobile
                    ? DateFormat('MMM d').format((trip.fullTime ?? trip.startTime).toLocal())
                    : DateFormat('MMM d, yyyy').format((trip.fullTime ?? trip.startTime).toLocal());

                final String distanceDisplay = isMobile
                    ? trip.totalDistanceKm.toStringAsFixed(1)
                    : "${trip.totalDistanceKm.toStringAsFixed(1)} km";

                final int durSec = trip.collectionSeconds; // LOGIN -> FULL, never the unloading time
                final int hours = durSec ~/ 3600;
                final int mins = (durSec % 3600) ~/ 60;
                final String durationDisplay = hours > 0
                    ? (isMobile ? "${hours}h ${mins}m" : "$hours hr $mins min")
                    : (isMobile ? "${mins}m" : "$mins min");

                final String weightDisplay = "${NumberFormat.decimalPattern().format(trip.weightKg.toInt())} kg";

                return InkWell(
                  onTap: () => _showTripDetailsModal(context, trip, tripLabel),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: (widget.highlightTripId != null && trip.tripId == widget.highlightTripId)
                          ? const Color(0xFFFFF3C4)
                          : (isTopRow && widget.highlightTripId == null ? const Color(0xFFE6F5F2) : Colors.white),
                      border: index < _dayTrips.length - 1
                          ? const Border(bottom: BorderSide(color: Color(0xFFE2ECE9)))
                          : null,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Text(
                            tripLabel,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF00796B)),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            dateDisplay,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1E293B)),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            distanceDisplay,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1E293B)),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            durationDisplay,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1E293B)),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  weightDisplay,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: trip.isMeasured ? const Color(0xFF00796B) : const Color(0xFF0F172A),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: trip.isMeasured ? const Color(0xFFD1FAE5) : const Color(0xFFE2ECE9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  trip.isMeasured ? "Measured" : "5T",
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: trip.isMeasured ? const Color(0xFF059669) : const Color(0xFF64748B),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: () => _showEditWeightDialog(context, trip, tripLabel),
                                borderRadius: BorderRadius.circular(12),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.edit_outlined, size: 16, color: Color(0xFF00796B)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF00796B)),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Footer Caption
        const Text(
          "Each trip is counted once. Weights default to 5T (5,000 kg) unless edited.",
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
        ),
      ],
    );
  }

  Future<void> _showTripDetailsModal(BuildContext context, DriverTrip trip, String tripLabel) async {
    final dateStr = DateFormat('MMM d, yyyy').format((trip.fullTime ?? trip.startTime).toLocal());
    final distStr = "${trip.totalDistanceKm.toStringAsFixed(1)} km";
    final int durSec = (trip.endTime ?? DateTime.now()).difference(trip.startTime).inSeconds;
    final int hours = durSec ~/ 3600;
    final int mins = (durSec % 3600) ~/ 60;
    final String durStr = hours > 0 ? "$hours hr $mins min" : "$mins min";
    final String weightStr = "${NumberFormat.decimalPattern().format(trip.weightKg.toInt())} kg (${(trip.weightKg / 1000.0).toStringAsFixed(1)} tons)";

    final List<String> visitedAreas = await _resolveVisitedAreas(trip);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title & Close Button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Trip details",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close_rounded, color: Color(0xFF0F172A), size: 22),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Detail rows: Trip number, Date, Distance, Duration, Weight
                  _buildDetailRow("Trip number", tripLabel, isBoldValue: true),
                  const SizedBox(height: 12),
                  _buildDetailRow("Date", dateStr),
                  const SizedBox(height: 12),
                  _buildDetailRow("Distance", distStr),
                  const SizedBox(height: 12),
                  _buildDetailRow("Duration", durStr),
                  const SizedBox(height: 12),

                  // Weight Row with Edit Button
                  Row(
                    children: [
                      const SizedBox(
                        width: 110,
                        child: Text(
                          "Weight",
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          weightStr,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: trip.isMeasured ? const Color(0xFF00796B) : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          Navigator.pop(dialogContext);
                          _showEditWeightDialog(context, trip, tripLabel);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE6F5F2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: const [
                              Icon(Icons.edit_outlined, size: 14, color: Color(0xFF00796B)),
                              SizedBox(width: 4),
                              Text(
                                "Edit",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF00796B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),
                  const Divider(color: Color(0xFFE2ECE9), height: 1),
                  const SizedBox(height: 20),

                  // Areas visited heading
                  const Text(
                    "Areas visited",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // List of areas
                  if (visitedAreas.isNotEmpty) ...[
                    ...visitedAreas.map((areaName) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            areaName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        )),
                    const SizedBox(height: 6),
                    const Text(
                      "Areas the truck passed, based on recorded GPS.",
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else ...[
                    const Text(
                      "Visited areas unavailable.",
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // View Route History button
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () {
                        final TripLink link = TripLinks.toRoute(trip);
                        if (!link.isAvailable) {
                          CustomSnackBar.show(context, message: link.message ?? 'Route unavailable.', isError: true);
                          return;
                        }
                        Navigator.pop(dialogContext);
                        final OpenRouteHistory? open = widget.onOpenRouteHistory;
                        if (open != null) {
                          // Stay inside the host shell: close the Load History dialog and
                          // show the exact trip in the dashboard content area.
                          Navigator.of(context).maybePop();
                          open(tripId: link.tripId, trip: trip);
                          return;
                        }
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => RouteHistoryScreen(
                              initialTripId: link.tripId,
                              initialTrip: trip,
                            ),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00796B),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        "View Collection Route",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Center(
                    child: Text(
                      "Opens this exact trip.",
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isBoldValue = false}) {
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFF64748B),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBoldValue ? FontWeight.w800 : FontWeight.w700,
              color: const Color(0xFF0F172A),
            ),
          ),
        ),
      ],
    );
  }
}

class _EtaPerformanceModal extends StatefulWidget {
  final ScrollController? scrollController;
  final List<EtaVisit>? initialVisits;
  final String? initialArea;
  final DateTimeRange? selectedDateRange;
  final List<String>? purokNames;

  const _EtaPerformanceModal({
    Key? key,
    this.scrollController,
    this.initialVisits,
    this.initialArea,
    this.selectedDateRange,
    this.purokNames,
  }) : super(key: key);

  @override
  State<_EtaPerformanceModal> createState() => _EtaPerformanceModalState();
}

class _EtaPerformanceModalState extends State<_EtaPerformanceModal> {
  late String _selectedArea;
  late DateTimeRange _selectedDateRange;
  String _selectedSource = "All sources";
  bool _isHowItWorksExpanded = false;
  bool _isRefreshing = false;

  List<EtaVisit> _visits = [];
  int _page = 1; // 1-based; reset to 1 whenever a filter changes

  StreamSubscription? _modalEtaNotifSubscription;

  @override
  void initState() {
    super.initState();
    _selectedArea = (widget.initialArea != null && widget.initialArea != "All Areas")
        ? widget.initialArea!
        : "All areas";
    _selectedDateRange = widget.selectedDateRange ?? DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 7)),
      end: DateTime.now(),
    );

    if (widget.initialVisits != null) {
      _visits = List.from(widget.initialVisits!);
    }
    _listenToFirebaseEtaModal();
  }

  @override
  void dispose() {
    _modalEtaNotifSubscription?.cancel();
    super.dispose();
  }

  void _listenToFirebaseEtaModal() {
    _modalEtaNotifSubscription?.cancel();
    _modalEtaNotifSubscription = FirebaseDatabase.instance.ref('notifications').onValue.listen((event) {
      final List<EtaVisit> visits = _buildEtaVisits(event.snapshot.exists ? event.snapshot.value : null);
      if (mounted) {
        setState(() {
          _visits = visits;
          _isRefreshing = false;
        });
      }
    }, onError: (Object e) {
      debugPrint('ETA details listener error: $e');
      if (mounted) setState(() => _isRefreshing = false);
    });
  }

  Future<void> _triggerRefresh() async {
    if (!mounted) return;
    setState(() => _isRefreshing = true);
    try {
      final DataSnapshot snap = await FirebaseDatabase.instance.ref('notifications').get();
      final List<EtaVisit> visits = _buildEtaVisits(snap.exists ? snap.value : null);
      if (mounted) setState(() => _visits = visits);
    } catch (e) {
      debugPrint('ETA details refresh error: $e');
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = screenWidth >= 700;

    // The SAME dataset and filter as the Analytics card (EtaEvaluation.filter/summarize).
    final List<EtaVisit> filtered = EtaEvaluation.filter(
      _visits,
      area: _selectedArea,
      source: _selectedSource,
      start: _selectedDateRange.start,
      end: _selectedDateRange.end,
    );
    final EtaSummary summary = EtaEvaluation.summarize(filtered);
    // Filters first, THEN pagination (newest sent first; 30 primary visit rows per page).
    final EtaPage<EtaVisit> pageData = EtaPage.of(filtered, _page);
    final int evaluatedCount = summary.evaluatedVisits;
    final double avgError = summary.avgAbsErrorMin ?? 0.0;
    final int accuracyPct = summary.within5Pct ?? 0;
    final int awaitingCount = summary.awaitingVisits;
    final int withdrawnCount = summary.withdrawnVisits;
    final int noArrivalCount = summary.noArrivalVisits;
    final int noEstimateCount = summary.noEstimateVisits;

    // Withdrawn note
    final String withdrawnNote = filtered
        .where((v) => v.status == EtaVisitStatus.withdrawn && (v.withdrawnReason ?? '').isNotEmpty)
        .map((v) => v.withdrawnReason!)
        .firstWhere((_) => true, orElse: () => '');

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.all(Radius.circular(28)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 28 : 18,
        vertical: isDesktop ? 24 : 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle for mobile
          if (!isDesktop)
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),

          // Header Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      "ETA Performance",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      "Notified estimates vs GPS-recorded area entry",
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: _triggerRefresh,
                    tooltip: "Refresh Data",
                    icon: _isRefreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00897B)),
                          )
                        : const Icon(Icons.refresh_rounded, color: Color(0xFF64748B), size: 22),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: "Close",
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B), size: 22),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Filters Row
          _buildFilterRow(context, isDesktop),

          const SizedBox(height: 20),

          // Main Scrollable Area
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // KPI Metric Cards Row
                  _buildKpiCards(avgError, accuracyPct, evaluatedCount, isDesktop),

                  const SizedBox(height: 16),

                  // Sub-header stats text
                  Text(
                    "$awaitingCount awaiting GPS-confirmed arrival · $withdrawnCount withdrawn"
                    "${noArrivalCount > 0 ? ' · $noArrivalCount with no arrival recorded' : ''}"
                    "${noEstimateCount > 0 ? ' · $noEstimateCount without an ETA' : ''}",
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Expandable detail records (same list on Android and Web)
                  if (filtered.isEmpty)
                    _buildEmptyRecords()
                  else
                    ...pageData.items.map((v) => _EtaVisitTile(key: ValueKey(v.visitKey), visit: v, isDesktop: isDesktop)),

                  if (filtered.isNotEmpty) _buildPager(pageData),

                  // Note for withdrawn items
                  if (withdrawnNote.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF64748B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            withdrawnNote,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 20),

                  // Performance Summary Card
                  _buildPerformanceSummary(avgError, evaluatedCount, accuracyPct),

                  const SizedBox(height: 16),

                  // How this works accordion
                  _buildHowItWorksCard(),

                  const SizedBox(height: 16),

                  // Footnote
                  Row(
                    children: const [
                      Icon(Icons.info_outline_rounded, size: 15, color: Color(0xFF94A3B8)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Area entry is separate from confirmed collection start.",
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF94A3B8),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(BuildContext context, bool isDesktop) {
    final List<String> availablePuroks = widget.purokNames ?? const [
      'Ayala Highway',
      'Brixton Homes',
      'Central (Purok 1)',
      'Purok 2',
      'Purok 3',
      'Purok 4 / El Pueblo',
      'Purok Paraiso',
      'Riverside',
      'San Nicolas',
      'T.M. Kalaw Street',
    ];
    final areaOptions = ["All areas", ...availablePuroks];
    final sourceOptions = ["All sources", "Auto", "Manual"];

    final isSingleDay = _selectedDateRange.start.year == _selectedDateRange.end.year &&
        _selectedDateRange.start.month == _selectedDateRange.end.month &&
        _selectedDateRange.start.day == _selectedDateRange.end.day;

    final displayDateStr = isSingleDay
        ? DateFormat('MMM d, yyyy').format(_selectedDateRange.start)
        : "${DateFormat('MMM d').format(_selectedDateRange.start)} - ${DateFormat('MMM d, yyyy').format(_selectedDateRange.end)}";

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Area Dropdown
        _buildCustomDropdown<String>(
          value: areaOptions.contains(_selectedArea) ? _selectedArea : "All areas",
          items: areaOptions,
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _selectedArea = val;
                _page = 1;
              });
            }
          },
        ),

        // Date Range Picker Trigger
        InkWell(
          onTap: () async {
            final AppDatePick? pick = await showAppDateRangePicker(context, initialRange: _selectedDateRange, clearable: true);
            if (pick == null) return; // cancelled: keep the current period
            if (pick.range != null) {
              setState(() {
                _selectedDateRange = pick.range!;
                _page = 1;
              });
            } else {
              // Clear -> reset to last 7 days
              setState(() {
                _selectedDateRange = DateTimeRange(
                  start: DateTime.now().subtract(const Duration(days: 7)),
                  end: DateTime.now(),
                );
                _page = 1;
              });
            }
          },
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_today_outlined, size: 15, color: Color(0xFF475569)),
                const SizedBox(width: 8),
                Text(
                  displayDateStr,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Color(0xFF64748B)),
              ],
            ),
          ),
        ),

        // Source Dropdown
        _buildCustomDropdown<String>(
          value: _selectedSource,
          items: sourceOptions,
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _selectedSource = val;
                _page = 1;
              });
            }
          },
        ),

        // (A Spacer here broke the whole dialog on wide screens: a Spacer is only valid inside a Row or Column,
        // not inside a Wrap, so the web version showed a grey box.)
        const Text(
          "Period based on notification sent date.",
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w400),
        ),
      ],
    );
  }

  Widget _buildCustomDropdown<T>({
    required T value,
    required List<T> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Color(0xFF64748B)),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
          onChanged: onChanged,
          items: items.map((T item) {
            return DropdownMenuItem<T>(
              value: item,
              child: Text(item.toString()),
            );
          }).toList(),
        ),
      ),
    );
  }

  String _formatAvgErrorText(double errorInMin) {
    if (errorInMin >= 1440) {
      return "${(errorInMin / 1440).toStringAsFixed(1)} days";
    } else if (errorInMin >= 60) {
      return "${(errorInMin / 60).toStringAsFixed(1)} hrs";
    } else {
      return "${errorInMin.toStringAsFixed(1)} min";
    }
  }

  Widget _buildKpiCards(double avgError, int accuracyPct, int evaluatedCount, bool isDesktop) {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            icon: Icons.access_time_rounded,
            iconBg: const Color(0xFFE0F2FE),
            iconColor: const Color(0xFF0284C7),
            value: evaluatedCount > 0 ? _formatAvgErrorText(avgError) : "—",
            label: isDesktop ? "Average error" : "Avg error",
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            icon: Icons.check_rounded,
            iconBg: const Color(0xFFDCFCE7),
            iconColor: const Color(0xFF16A34A),
            value: evaluatedCount > 0 ? "$accuracyPct%" : "—",
            label: "Within ±5 min",
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            icon: Icons.assignment_outlined,
            iconBg: const Color(0xFFE0E7FF),
            iconColor: const Color(0xFF4F46E5),
            value: "$evaluatedCount",
            label: isDesktop ? "Evaluated visits" : "Evaluated",
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String value,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 12,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconBg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF64748B),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildPager(EtaPage<EtaVisit> p) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 6,
        children: [
          Text(
            'Showing ${p.firstShown}–${p.lastShown} of ${p.total}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Previous page',
                onPressed: p.hasPrevious ? () => setState(() => _page = p.page - 1) : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Text('Page ${p.page} of ${p.pageCount}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A), fontWeight: FontWeight.w700)),
              IconButton(
                tooltip: 'Next page',
                onPressed: p.hasNext ? () => setState(() => _page = p.page + 1) : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyRecords() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Text(
        _visits.isEmpty
            ? 'No ETA notifications are recorded yet.'
            : 'No ETA notifications were sent for this area, source and period.',
        style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildPerformanceSummary(double avgError, int evaluatedCount, int accuracyPct) {
    String formattedAvgError;
    if (avgError >= 1440) {
      formattedAvgError = "${(avgError / 1440).toStringAsFixed(1)} days";
    } else if (avgError >= 60) {
      formattedAvgError = "${(avgError / 60).toStringAsFixed(1)} hours";
    } else {
      formattedAvgError = "${avgError.toStringAsFixed(1)} minutes";
    }

    String displayRangeStr = _selectedDateRange.start.year == _selectedDateRange.end.year &&
            _selectedDateRange.start.month == _selectedDateRange.end.month &&
            _selectedDateRange.start.day == _selectedDateRange.end.day
        ? DateFormat('MMM d, yyyy').format(_selectedDateRange.start)
        : "${DateFormat('MMM d').format(_selectedDateRange.start)} - ${DateFormat('MMM d, yyyy').format(_selectedDateRange.end)}";

    String text;
    if (evaluatedCount == 0) {
      text = "No GPS-confirmed arrivals to evaluate for $_selectedArea during $displayRangeStr. Select another area or date range, or wait for the awaiting visits to arrive.";
    } else if (evaluatedCount == 1) {
      text = "Average error is $formattedAvgError across $evaluatedCount evaluated visit ($accuracyPct% within ±5 min).";
    } else {
      text = "Average error is $formattedAvgError across $evaluatedCount evaluated visits ($accuracyPct% within ±5 min).";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(16),
        border: const Border(
          left: BorderSide(color: Color(0xFF0D9488), width: 4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Performance summary",
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 14,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF334155),
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHowItWorksCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() => _isHowItWorksExpanded = !_isHowItWorksExpanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_outlined, size: 20, color: Color(0xFF0F172A)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "How this works",
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  Icon(
                    _isHowItWorksExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: const Color(0xFF64748B),
                  ),
                ],
              ),
            ),
          ),
          if (_isHowItWorksExpanded) ...[
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                "The first notified ETA of a visit (one truck trip in one area) is compared with the GPS-confirmed arrival recorded for the SAME trip and area. Repeated 15/10/5 minute alerts for one visit count once. Passing through does not confirm collection. Pending and withdrawn visits are excluded from error calculations.",
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF64748B),
                  height: 1.45,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Builds the visits from the raw `notifications` node: the single ETA evaluation entry point
/// shared by the Analytics card and the ETA Performance details.
/// Trips that have ended (FULL / COMPLETED / FINISHED, or archived): their trucks can no longer
/// arrive anywhere, so an alert of theirs without an arrival is not "awaiting".
Set<String> _etaClosedTripIds = <String>{};

Set<String> _closedTripIds(Map trips) {
  final Set<String> out = <String>{};
  trips.forEach((Object? key, Object? v) {
    if (v is! Map) return;
    final String s = (v['route_status'] ?? v['status'] ?? '').toString().toUpperCase();
    if (s == 'FULL' || s == 'COMPLETED' || s == 'FINISHED' || v['collection_finalized'] == true || TripArchive.isArchived(v)) {
      out.add(key.toString());
    }
  });
  return out;
}

/// Trips and areas the ETA arrivals are verified against (kept in sync by the Analytics screen).
Map _etaRoutes = {};
List<AreaGeofence> _etaAreas = const <AreaGeofence>[];

/// The notifications with their arrivals replaced by the VERIFIED (green) visits: an arrival
/// is the first fix of a stay of at least 2 accurate GPS fixes, at least 1 minute apart,
/// inside the area while ACTIVE (VisitPolicy) - the same rule that turns an area green on
/// Collection Route Optimization. Driver-app arrival alerts no longer count on their own.
Object? _withVerifiedArrivals(Object? rawNotifications) {
  if (rawNotifications is! Map) return rawNotifications;
  final Map<String, Object?> out = <String, Object?>{};
  rawNotifications.forEach((Object? k, Object? v) {
    if (v is Map && (v['type'] ?? '').toString() == 'auto_arrival') return;
    out[k.toString()] = v;
  });
  if (_etaRoutes.isEmpty || _etaAreas.isEmpty) return out;
  final List<CollectionVisit> visits = CollectionVisits.detect(
    trips: _etaRoutes,
    areas: _etaAreas,
    start: DateTime(2000),
    end: DateTime.now().add(const Duration(days: 1)),
  ).visits;
  for (final CollectionVisit v in visits) {
    if (v.simulated) continue;
    out['verified_${v.tripId}_${v.area}'] = <String, Object?>{
      'type': 'auto_arrival',
      'purok': v.area,
      'trip_id': v.tripId,
      'timestamp': v.firstFixMs,
    };
  }
  return out;
}

List<EtaVisit> _buildEtaVisits(Object? rawNotifications) {
  // Valid ETAs only: an alert counts when the truck really reached that area on that trip
  // (verified, green visit), or while its trip is still running and it can still arrive.
  // Alerts for areas the truck never reached (sent to random areas) are invalid and are
  // left out of every figure and list.
  return EtaEvaluation.build(
    _withVerifiedArrivals(rawNotifications),
    nowMs: DateTime.now().millisecondsSinceEpoch,
    canonicalize: (String raw) => ServiceAreaService.canonicalizeAreaName(raw) ?? raw,
    closedTripIds: _etaClosedTripIds,
  ).where((EtaVisit v) => v.status == EtaVisitStatus.evaluated || v.status == EtaVisitStatus.awaiting).toList();
}

String _etaClock(int? ms) => ms == null ? '\u2014' : DateFormat('MMM d, h:mm:ss a').format(EtaEvaluation.manila(ms));

String _etaMinutesText(double minutes) {
  final double a = minutes.abs();
  if (a >= 1440) return '${(a / 1440).toStringAsFixed(1)} days';
  if (a >= 60) return '${(a / 60).toStringAsFixed(1)} hrs';
  return '${a.toStringAsFixed(1)} min';
}

String _etaSignedText(double minutes) {
  if (minutes == 0) return 'On time';
  return minutes > 0 ? '${_etaMinutesText(minutes)} late' : '${_etaMinutesText(minutes)} early';
}

/// One visit: collapsed headline, expandable detail (sent / predicted / actual / error / status).
class _EtaVisitTile extends StatefulWidget {
  const _EtaVisitTile({Key? key, required this.visit, required this.isDesktop}) : super(key: key);

  final EtaVisit visit;
  final bool isDesktop;

  @override
  State<_EtaVisitTile> createState() => _EtaVisitTileState();
}

class _EtaVisitTileState extends State<_EtaVisitTile> {
  bool _open = false;

  String get _statusLabel {
    switch (widget.visit.status) {
      case EtaVisitStatus.evaluated:
        return 'Evaluated';
      case EtaVisitStatus.awaiting:
        return 'Awaiting GPS-confirmed arrival';
      case EtaVisitStatus.noArrival:
        return 'No GPS-confirmed arrival recorded';
      case EtaVisitStatus.withdrawn:
        return 'Withdrawn';
      case EtaVisitStatus.noEstimate:
        return 'No ETA stated in the notification';
    }
  }

  Widget _badge() {
    final EtaVisit v = widget.visit;
    Color bg = const Color(0xFFF1F5F9);
    Color fg = const Color(0xFF475569);
    String text = _statusLabel;
    if (v.isEvaluated) {
      text = _etaSignedText(v.signedErrorMin!);
      if (v.signedErrorMin! > 0) {
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFFB45309);
      }
    } else if (v.status == EtaVisitStatus.awaiting) {
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFFB45309);
      text = 'Awaiting arrival';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: widget.isDesktop ? 190 : 132,
            child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: const Color(0xFF0F172A),
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final EtaVisit v = widget.visit;
    final EtaPrediction p = v.first;
    final String stage = p.stage.isEmpty ? p.type : '${p.type} (${p.stage})';
    final String predicted = p.predictedMinutes == null ? 'No ETA stated' : '${p.predictedMinutes} min';
    final String actual = v.arrivalMs != null ? _etaClock(v.arrivalMs) : 'Awaiting GPS-confirmed arrival';
    final String subtitle = v.arrivalMs != null
        ? 'Sent ${_etaClock(p.sentMs)} \u2192 arrived ${_etaClock(v.arrivalMs)}'
        : 'Sent ${_etaClock(p.sentMs)} \u00b7 predicted ${_etaClock(p.predictedArrivalMs)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(v.area, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF0F172A))),
                            if (v.truckId.isNotEmpty)
                              Text(v.truckId, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
                            if (v.tripId != null)
                              Text('Trip ${v.tripId}',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF94A3B8))),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: v.source == 'Auto' ? const Color(0xFFDCFCE7) : const Color(0xFFE0F2FE),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                v.source,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: v.source == 'Auto' ? const Color(0xFF166534) : const Color(0xFF075985),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _badge(),
                  const SizedBox(width: 4),
                  Icon(_open ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      size: 20, color: const Color(0xFF94A3B8)),
                ],
              ),
            ),
          ),
          if (_open) ...[
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Area', v.area),
                  _row('Truck', v.truckIds.isEmpty ? 'Not recorded' : v.truckIds.join(', ')),
                  if (v.truckLabelsDiffer)
                    _row('Note', 'Records of this trip use different truck labels; matched by trip and area.'),
                  _row('Trip', v.tripId ?? 'Not recorded (older record)'),
                  _row('Notification', stage),
                  _row('Notification sent', _etaClock(p.sentMs)),
                  _row('ETA when sent', predicted),
                  _row('Predicted arrival', _etaClock(p.predictedArrivalMs)),
                  _row('Actual GPS-confirmed arrival', actual, bold: v.arrivalMs != null),
                  _row('Difference',
                      v.isEvaluated ? _etaSignedText(v.signedErrorMin!) : 'Not available until the truck arrives'),
                  _row('Absolute error', v.isEvaluated ? _etaMinutesText(v.absErrorMin!) : 'Not available'),
                  _row('Status', _statusLabel),
                  if (v.legacyMatch)
                    _row('Match', 'Matched by truck and area (older record without a trip id)'),
                  if (p.minutesFromMessage) _row('ETA source', 'Read from the notification text'),
                  if ((v.withdrawnReason ?? '').isNotEmpty) _row('Reason', v.withdrawnReason!),
                  const SizedBox(height: 8),
                  Text('Notification stages for this visit (${v.predictions.length})',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
                  ...v.predictions.map((q) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${q.stage.isEmpty ? q.type : q.stage} · sent ${_etaClock(q.sentMs)}'
                          ' · ${q.predictedMinutes == null ? 'no ETA' : '${q.predictedMinutes} min'}'
                          ' · predicted ${_etaClock(q.predictedArrivalMs)}'
                          '${q.signedErrorMin == null ? '' : ' · ${_etaSignedText(q.signedErrorMin!)}'}',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w500),
                        ),
                      )),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
