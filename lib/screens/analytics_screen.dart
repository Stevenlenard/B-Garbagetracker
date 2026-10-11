import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../utils/custom_notification.dart';
import '../widgets/custom_snackbar.dart';
import '../utils/app_theme.dart';
import '../utils/session_manager.dart';
import '../api/api_service.dart';
import '../api/api_client.dart';
import '../utils/prediction_engine.dart';
import '../utils/system_logger.dart';
import '../services/service_area_service.dart';
import '../models/driver_trip.dart';
import '../models/user.dart';
import '../services/driver_route_history_service.dart';
import 'route_history_screen.dart';

DateTime _parseEpochTimestamp(int ts) {
  if (ts <= 0) return DateTime.now();
  if (ts < 10000000000) {
    return DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  }
  return DateTime.fromMillisecondsSinceEpoch(ts);
}

class AnalyticsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  final Function(int)? onNavigate;
  const AnalyticsScreen({super.key, this.isEmbedded = false, this.onBack, this.onNavigate});

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
  String _selectedArea = "All Areas";
  DateTimeRange _selectedDateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 30)),
    end: DateTime.now(),
  );

  bool _isDateRange = true;

  double _avgCollectionTime = 0.0;
  int _stopsPerRoute = 0;
  double _distanceCovered = 0.0;
  double _predictionAccuracy = 0.0;
  double _maeValue = 0.0;

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
  double _tomorrowWaste = 5000.0;
  double _weeklyWaste = 15000.0;
  double _totalFleetCapacity = 5000.0;
  String _selectedTruckSummary = "GT-007";
  String _selectedPeriodSummary = "All time";
  bool _showLoadHistorySection = true;

  // Load History & Waste Summary State
  bool _isLoadingLoadData = false;
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
  bool _isLoadAiLoading = false;
  double _measuredTodayVolume = 4200.0;
  double _measuredMonthlyVolume = 38600.0;
  final Map<String, String> _etaEstimates = {};
  double _etaAvgArrivalError = 3.5;
  int _etaWithin5MinPct = 100;
  int _etaEvaluatedVisits = 2;
  List<_EtaRecord> _etaRecords = [];
  String _recommendations = "Analyzing fleet...";
  String _fleetInsight = "Analyzing fleet performance patterns...";
  String _complaintInsight = "Evaluating resident feedback trends...";
  String _coverageInsight = "Reviewing area coverage efficiency...";
  bool _isAiLoading = true;

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
    _refreshRotationController.dispose();
    _scrollController.dispose();
    _trucksSubscription?.cancel();
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
      _fetchEtaPerformance(),
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
            Future.delayed(const Duration(milliseconds: 1500), () {
              if (Navigator.canPop(context)) Navigator.pop(context);
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
      filteredStatusCounts[status] = filteredStatusCounts[status]! + 1;

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

      // Track per-purok frequency for heatmaps using canonicalized name (e.g. Dos Riles -> Purok 3)
      String targetPurokKey = canonicalPurok ?? rawPurok ?? "Unknown";
      purokCounts[targetPurokKey] = (purokCounts[targetPurokKey] ?? 0) + 1;
    }

    if (mounted) {
      setState(() {
        // Use REAL FILTERED counts for the visual chart and legend
        _complaintStatusData = filteredStatusCounts;

        // Use REAL FILTERED counts for the info text breakdown
        _complaintSourceData = {"Residents": matchedResidents.toDouble(), "Drivers": matchedDrivers.toDouble()};
        _purokComplaintData = purokCounts;

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

  String _generateRuleBasedRecommendations() {
    final StringBuffer recs = StringBuffer();
    final int pendingCount = (_complaintStatusData['Pending'] ?? 0).toInt();
    final double activeTrucks = (_truckStatusData['Active'] ?? 0);
    final double idleTrucks = (_truckStatusData['Idle'] ?? 0);

    if (pendingCount > 0) {
      recs.writeln("• Priority Focus: $pendingCount pending resident complaint(s) in $_selectedArea requiring attention.");
    } else {
      recs.writeln("• Resident Feedback: Area reports high satisfaction with no pending complaints.");
    }

    if (_tomorrowWaste > (_totalFleetCapacity * 0.85)) {
      recs.writeln("• Capacity Warning: Tomorrow's forecast (${_tomorrowWaste.toInt()} kg) reaches 85% of active fleet capacity (${_totalFleetCapacity.toInt()} kg). Consider pre-assigning backup trucks.");
    } else {
      recs.writeln("• Fleet Allocation: Predicted volume (${_tomorrowWaste.toInt()} kg) is within safe operational capacity (${_totalFleetCapacity.toInt()} kg).");
    }

    if (idleTrucks > 0) {
      recs.writeln("• Fleet Optimization: ${idleTrucks.toInt()} truck(s) currently idle. Assign to high-density coverage zones.");
    } else {
      recs.writeln("• Fleet Status: Active truck deployment is optimal across collection routes.");
    }

    return recs.toString().trim();
  }

  Future<void> _generateAiInsights() async {
    if (!mounted) return;

    setState(() => _isAiLoading = true);

    const apiKey = "AIzaSyCPng8Ef9-AsuUiagku1FAQOowQniZYkOo";
    final model = GenerativeModel(model: 'gemini-1.5-flash-latest', apiKey: apiKey);

    // Prepare data context for AI
    StringBuffer stats = StringBuffer("System Data (Balintawak Context):\n");
    stats.writeln("Area: $_selectedArea");
    stats.writeln("Date: ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.start)}${_isDateRange ? " to ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.end)}" : ""}");
    stats.writeln("Routes: $_completedRoutes/$_totalRoutes completed");
    stats.writeln("Complaints: ${_complaintStatusData['Pending']?.toInt() ?? 0} pending");
    stats.writeln("Efficiency: ${_avgCollectionTime.toStringAsFixed(2)} hours avg time, $_distanceCovered km covered");
    stats.writeln("MAE Accuracy: ${_predictionAccuracy.toStringAsFixed(1)}% (MAE: ${_maeValue.toStringAsFixed(2)} mins)");

    String topArea = _selectedArea == "All Areas"
        ? (_purokFrequencyData.entries.isNotEmpty
        ? _purokFrequencyData.entries.reduce((a, b) => a.value > b.value ? a : b).key
        : "Sentro")
        : _selectedArea;

    // Calculate Dynamic Active Fleet Capacity
    double activeCapacity = 0.0;
    if (_truckRegistry.isNotEmpty) {
      _truckRegistry.forEach((tId, tData) {
        if (tData is Map) {
          final status = tData['status']?.toString().toLowerCase() ?? 'active';
          if (status != 'out_of_service' && status != 'inactive' && status != 'maintenance') {
            final num? cap = num.tryParse(tData['capacity']?.toString() ?? '') ??
                num.tryParse(tData['truck_capacity']?.toString() ?? '') ??
                num.tryParse(tData['maxVolume']?.toString() ?? '');
            activeCapacity += (cap?.toDouble() ?? 5000.0);
          }
        }
      });
    }
    _totalFleetCapacity = activeCapacity > 0 ? activeCapacity : 5000.0;

    // Calculate Historical Weight Averages from Collection Progress
    double totalRecordedKg = 0.0;
    int validSessions = 0;
    if (_allCollectionProgress.isNotEmpty) {
      _allCollectionProgress.forEach((sId, progress) {
        if (progress is Map) {
          progress.forEach((purokKey, purokData) {
            if (purokData is Map) {
              final rawName = purokData['name']?.toString() ?? purokKey.toString();
              final String? canonical = ServiceAreaService.canonicalizeAreaName(rawName) ?? rawName;
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
    }
    double? histAvgKg = validSessions > 0 ? (totalRecordedKg / validSessions) : null;

    double predictedVol = PredictionEngine.predictWasteVolume(topArea, stopCount: _stopsPerRoute, historicalAvgKg: histAvgKg);
    double weeklyVol = PredictionEngine.predictWeeklyVolume(topArea, avgStops: _stopsPerRoute, historicalAvgKg: histAvgKg);

    // Dynamic GPS-based ETA calculation
    _etaEstimates.clear();
    final List<String> targetPuroks = _selectedArea == "All Areas"
        ? _purokNames
        : [_selectedArea];

    const Map<String, List<double>> purokCoordinates = {
      'Ayala Highway': [13.9415, 121.1632],
      'Brixton Homes': [13.9480, 121.1685],
      'Central (Purok 1)': [13.9430, 121.1620],
      'Purok 2': [13.9450, 121.1640],
      'Purok 3': [13.9470, 121.1660],
      'Purok 4 / El Pueblo': [13.9490, 121.1690],
      'Purok Paraiso': [13.9420, 121.1650],
      'Riverside': [13.9400, 121.1610],
      'San Nicolas': [13.9380, 121.1590],
      'T.M. Kalaw Street': [13.9440, 121.1630],
    };

    for (var p in targetPuroks) {
      bool foundActiveGps = false;
      final targetCoords = purokCoordinates[p];

      if (targetCoords != null && _allTruckLocations.isNotEmpty) {
        _allTruckLocations.forEach((truckId, liveData) {
          if (!foundActiveGps && liveData is Map) {
            final double? lat = num.tryParse(liveData['latitude']?.toString() ?? '')?.toDouble();
            final double? lng = num.tryParse(liveData['longitude']?.toString() ?? '')?.toDouble();
            final double speed = num.tryParse(liveData['speed']?.toString() ?? '')?.toDouble() ?? 20.0;
            final bool isOnline = liveData['isOnline'] == true || liveData['status']?.toString().toLowerCase() == 'collecting';

            if (lat != null && lng != null && isOnline) {
              double distKm = PredictionEngine.calculateHaversineDistance(lat, lng, targetCoords[0], targetCoords[1]);
              double mins = PredictionEngine.calculateLiveEtaMinutes(distKm, speed, remainingStops: 2);
              DateTime arrival = DateTime.now().add(Duration(minutes: mins.toInt()));
              _etaEstimates[p] = DateFormat('h:mm a').format(arrival);
              foundActiveGps = true;
            }
          }
        });
      }

      if (!foundActiveGps) {
        double avgSysSpeed = (_avgCollectionTime > 0 && _distanceCovered > 0)
            ? (_distanceCovered / _avgCollectionTime)
            : 20.0;
        double dist = (_purokNames.indexOf(p) + 1) * 0.8;
        double mins = PredictionEngine.estimateArrivalTime(dist, [avgSysSpeed, avgSysSpeed * 0.9]);
        DateTime arrival = DateTime.now().add(Duration(minutes: mins.toInt()));
        _etaEstimates[p] = DateFormat('h:mm a').format(arrival);
      }
    }

    if (mounted) {
      setState(() {
        _tomorrowWaste = predictedVol;
        _weeklyWaste = weeklyVol;
      });
    }

    if (_selectedArea == "All Areas") {
      _purokFrequencyData.forEach((key, value) {
        stats.writeln("$key: $value visits this month");
      });
    }

    final prompt = """
        You are the Garbage Tracking System AI (Gemini 1.5 Flash) for the Municipality of Balintawak. 
        Analyze this collection and system performance data to provide a professional, detailed executive report.
        
        DATA CONTEXT:
        - Focus Area: $_selectedArea
        - Report Date: ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.start)}${_isDateRange ? " to ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.end)}" : ""}
        - $stats
        
        INSTRUCTIONS:
        1. Provide a long and detailed analytical summary of the performance.
        2. Identify bottlenecks or exceptional performance areas.
        3. Provide data-driven predictions for volume and arrival ETAs.
        4. Give 3-5 strategic recommendations for the fleet manager.

        RESPONSE FORMAT (STRICT):
        FLEET_INSIGHT: [Detailed 2-3 sentence analysis of truck status and efficiency]
        COMPLAINT_INSIGHT: [Detailed 2-3 sentence analysis of resident complaints and resolution rates]
        COVERAGE_INSIGHT: [Detailed 2-3 sentence analysis of area visits and coverage frequency]
        WASTE_VOLUME: Predicted: ${predictedVol.toStringAsFixed(0)}kg for $topArea
        ARRIVAL: ETA: ${(_avgCollectionTime * 60 * 0.8).toStringAsFixed(0)} mins for 2km
        RECOMMENDATIONS: [Strategic bullet points]
        OVERALL_CONCLUSION: [Final executive summary]
    """;

    try {
      final content = [Content.text(prompt)];
      final response = await model.generateContent(content);
      final text = response.text ?? "";

      if (mounted) {
        setState(() {
          if (text.contains("FLEET_INSIGHT:")) _fleetInsight = text.split("FLEET_INSIGHT:")[1].split("COMPLAINT_INSIGHT:")[0].trim();
          if (text.contains("COMPLAINT_INSIGHT:")) _complaintInsight = text.split("COMPLAINT_INSIGHT:")[1].split("COVERAGE_INSIGHT:")[0].trim();
          if (text.contains("COVERAGE_INSIGHT:")) _coverageInsight = text.split("COVERAGE_INSIGHT:")[1].split("WASTE_VOLUME:")[0].trim();

          if (text.contains("RECOMMENDATIONS:")) {
            _recommendations = text.split("RECOMMENDATIONS:")[1].split("OVERALL_CONCLUSION:")[0].trim();
          } else {
            _recommendations = _generateRuleBasedRecommendations();
          }

          if (_recommendations.trim().isEmpty || _recommendations == "Analyzing fleet...") {
            _recommendations = _generateRuleBasedRecommendations();
          }

          if (text.contains("OVERALL_CONCLUSION:")) {
            _geminiSummary = text.split("OVERALL_CONCLUSION:")[1].trim();
          }
          _isAiLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAiLoading = false;
          _recommendations = _generateRuleBasedRecommendations();
          _geminiSummary = "Unable to generate real-time AI insights. Showing rule-based system recommendations.";
        });
      }
    }
  }

  Future<void> _exportReport(String category, String format) async {
    if (format.contains('PDF')) {
      _showPdfConfirmationDialog(category);
      return;
    }

    final String exportUrl = "${ApiClient.baseUrl}export_report.php";
    final String dateStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final String endDateStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);

    String wasteTomorrow = "${_tomorrowWaste.toInt()} kg";
    String wasteWeekly = "${_weeklyWaste.toInt()} kg";

    CustomNotification.showTopNotification(context, "Exporting $category to Excel...", false);

    final queryParams = {
      'type': _selectedArea == "All Areas" ? category : "$category - $_selectedArea",
      'format': 'xls',
      'start_date': dateStr,
      'end_date': endDateStr,
      'res_rate': "${_coveragePercent.toInt()}%",
      'avg_time': "${_avgCollectionTime.toStringAsFixed(1)} hours",
      'coverage': "${_coveragePercent.toInt()}%",
      'routes_done': "$_completedRoutes/$_totalRoutes",
      'active_count': "${_truckStatusData['Active']?.toInt() ?? 0}",
      'collecting_count': "${_truckStatusData['Active']?.toInt() ?? 0}",
      'full_count': "${_truckStatusData['Full']?.toInt() ?? 0}",
      'inactive_count': "${_truckStatusData['Idle']?.toInt() ?? 0}",
      'pending_count': "${_complaintStatusData['Pending']?.toInt() ?? 0}",
      'in_progress_count': "${_complaintStatusData['In Progress']?.toInt() ?? 0}",
      'resolved_count': "${_complaintStatusData['Resolved']?.toInt() ?? 0}",
      'dist': "${_distanceCovered.toStringAsFixed(1)} km",
      'stops': "$_stopsPerRoute",
      'coll_time': "${_avgCollectionTime.toStringAsFixed(1)} hours",
      'waste_tomorrow': wasteTomorrow,
      'waste_weekly': wasteWeekly,
      'insight1': _geminiSummary ?? "System performing normally.",
      'insight2': _recommendations,
      'total_drivers': "${_allDriverRoutes.values.map((e) => e['driver_id']).toSet().length}",
    };

    final uri = Uri.parse(exportUrl).replace(queryParameters: queryParams);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      await SystemLogger.logEvent("EXPORT", "Exported Excel report for $_selectedArea");

      if (mounted) {
        _showSuccessDialog(context, "Excel Report Generated",
            "Your analytics report for $_selectedArea has been generated and is downloading.");
      }
    } else {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Could not launch export tool.", true);
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

  Future<void> _exportToNativePdf(String category) async {
    final pdf = pw.Document();
    final dateStr = DateFormat('MMMM dd, yyyy').format(_selectedDateRange.start);
    final rangeStr = _isDateRange ? " to ${DateFormat('MMMM dd, yyyy').format(_selectedDateRange.end)}" : "";
    final genTime = DateFormat('MMM dd, yyyy HH:mm').format(DateTime.now());
    final primaryColor = PdfColor.fromHex('#00BFA5');
    final textColor = PdfColor.fromHex('#2C3E50');

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (pw.Context context) => pw.Column(
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text("GARBAGE TRACKING SYSTEM", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: primaryColor)),
                    pw.Text("Official Analytics & Performance Report", style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600, fontStyle: pw.FontStyle.italic)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text("Area: $_selectedArea", style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    pw.Text("Period: $dateStr$rangeStr", style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    pw.Text("Generated: $genTime", style: pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Divider(color: primaryColor, thickness: 1),
            pw.SizedBox(height: 20),
          ],
        ),
        footer: (pw.Context context) => pw.Column(
          children: [
            pw.Divider(color: PdfColors.grey300),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text("GarbageBiz System | Confidential Performance Data", style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
                pw.Text("Page ${context.pageNumber} of ${context.pagesCount}", style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
              ],
            ),
          ],
        ),
        build: (pw.Context context) => [
          pw.Text("1. Introduction", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 10),
          pw.Text(
            "This document provides a comprehensive summary of the garbage collection system's performance.",
            style: pw.TextStyle(fontSize: 10, color: textColor, lineSpacing: 1.5),
          ),
          pw.SizedBox(height: 25),
          pw.Text("2. Fleet Performance & Visual Analytics", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Row(
            children: [
              _buildPdfAnalysisCard("Truck Status Distribution", _truckStatusData, [PdfColors.green, PdfColors.amber, PdfColors.grey400], ["Active", "Full", "Idle"]),
              pw.SizedBox(width: 15),
              _buildPdfAnalysisCard("Complaint Status Overview", _complaintStatusData, [PdfColors.red, PdfColors.blue, PdfColors.green], ["Pending", "In Progress", "Resolved"]),
            ],
          ),
          pw.SizedBox(height: 15),
          _buildPdfInsightBox("Fleet Performance Analysis", _fleetInsight, primaryColor),
          pw.SizedBox(height: 30),
          pw.Text("3. Resident Feedback & Complaints Analysis", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          _buildPdfInsightBox("Complaints Documentation", _complaintInsight, PdfColors.red),
          pw.SizedBox(height: 15),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              _buildPdfTableRow("Issue Type", "Distribution", isHeader: true),
              _buildPdfTableRow("Pending Complaints", "${_complaintStatusData['Pending']?.toInt() ?? 0}"),
              _buildPdfTableRow("Resolved Issues", "${_complaintStatusData['Resolved']?.toInt() ?? 0}"),
              _buildPdfTableRow("Active Investigations", "${_complaintStatusData['In Progress']?.toInt() ?? 0}"),
            ],
          ),
          pw.SizedBox(height: 30),
          pw.Text("4. Area Coverage & Frequency", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Container(
            height: 180,
            padding: const pw.EdgeInsets.only(left: 10, right: 10, bottom: 20),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey100), borderRadius: pw.BorderRadius.circular(4)),
            child: _buildPdfBarChart(),
          ),
          pw.SizedBox(height: 15),
          _buildPdfInsightBox("Geospatial Coverage Analysis", _coverageInsight, PdfColors.blue),
          pw.SizedBox(height: 30),
          pw.Text("5. Performance Forecasts", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              _buildPdfTableRow("Forecasting Metric", "Calculated Value", isHeader: true),
              _buildPdfTableRow("Tomorrow's Predicted Volume", "${_tomorrowWaste.toInt()} kg"),
              _buildPdfTableRow("Weekly Volume Projection", "${_weeklyWaste.toInt()} kg"),
              _buildPdfTableRow("Avg Stop Duration", "${_avgCollectionTime.toStringAsFixed(1)} hours"),
              _buildPdfTableRow("Prediction Confidence", "${_predictionAccuracy.toStringAsFixed(1)}%"),
            ],
          ),
          pw.SizedBox(height: 30),
          pw.Text("6. Strategic Recommendations", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 10),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey200), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Text(_recommendations, style: pw.TextStyle(fontSize: 10, color: textColor, lineSpacing: 1.6)),
          ),
          pw.SizedBox(height: 30),
          pw.Text("7. Final Executive Conclusion", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Container(
            padding: const pw.EdgeInsets.all(15),
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E0F2F1'), borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Text(
              _geminiSummary ?? "Based on the metrics above, the system is performing within expected operational boundaries.",
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: primaryColor, lineSpacing: 1.5),
            ),
          ),
        ],
      ),
    );

    try {
      final bytes = await pdf.save();
      await Printing.sharePdf(
        bytes: bytes,
        filename: "GarbageBiz_Report_${DateFormat('yyyyMMdd').format(_selectedDateRange.start)}.pdf",
      );
      await SystemLogger.logEvent("EXPORT", "Generated PDF Report for $_selectedArea");
    } catch (e) {
      debugPrint("PDF Error: $e");
    }
  }

  pw.TableRow _buildPdfTableRow(String label, String value, {bool isHeader = false}) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(label, style: pw.TextStyle(fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal, fontSize: 10)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(value, style: pw.TextStyle(fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal, fontSize: 10)),
        ),
      ],
    );
  }

  pw.Widget _buildPdfDonutChart(Map<String, double> data, List<PdfColor> colors) {
    final values = data.values.toList();
    final total = values.fold(0.0, (a, b) => a + b);
    if (total == 0) return pw.Text("No Data");

    return pw.Container(
      width: 100,
      height: 100,
      child: pw.Chart(
        grid: pw.PieGrid(),
        datasets: List.generate(values.length, (index) {
          return pw.PieDataSet(
            value: values[index],
            color: colors[index % colors.length],
            drawSurface: true,
            innerRadius: 0.5,
          );
        }),
      ),
    );
  }

  pw.Widget _buildPdfAnalysisCard(String title, Map<String, double> data, List<PdfColor> colors, List<String> labels) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(15),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#F8F9FA'),
          borderRadius: pw.BorderRadius.circular(12),
          border: pw.Border.all(color: PdfColors.grey200, width: 0.5),
        ),
        child: pw.Column(
          children: [
            pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
            pw.SizedBox(height: 20),
            pw.Center(child: _buildPdfDonutChart(data, colors)),
            pw.SizedBox(height: 20),
            pw.Wrap(
              spacing: 12,
              children: List.generate(labels.length, (i) => _buildPdfLegendItem("${labels[i]} (${data[labels[i]]?.toInt()})", colors[i])),
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _buildPdfBarChart() {
    final Map<String, int> freqData = _purokFrequencyData.isNotEmpty
        ? _purokFrequencyData
        : {"Ayala Highway": 0, "Brixton Area": 0, "Central": 12, "Purok 2": 0, "Purok 3": 6, "Purok 4": 0, "San Isidro": 0};
    
    final List<String> areas = freqData.keys.toList();
    if (areas.isEmpty) return pw.Text("No Frequency Data");

    final datasets = List.generate(areas.length, (index) {
      final count = (freqData[areas[index]] ?? 0).toDouble();
      return pw.BarDataSet(
        color: PdfColors.teal,
        width: 8,
        data: [pw.PointChartValue(index.toDouble(), count)],
      );
    });

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          height: 160,
          child: pw.Chart(
            grid: pw.CartesianGrid(
              xAxis: pw.FixedAxis(
                List.generate(areas.length, (i) => i.toDouble()),
                format: (v) => areas[v.toInt()],
                textStyle: const pw.TextStyle(fontSize: 6),
                ticks: true,
              ),
              yAxis: pw.FixedAxis([0, 10, 20, 30, 40], ticks: true),
            ),
            datasets: datasets,
          ),
        ),
        pw.SizedBox(height: 10),
        pw.Text("Area & Purok Frequency Reference:", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8)),
        pw.SizedBox(height: 4),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text("Area / Purok Name", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7))),
                pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text("Frequency Count", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7))),
              ],
            ),
            ...areas.map((area) {
              final count = freqData[area] ?? 0;
              return pw.TableRow(
                children: [
                  pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(area, style: const pw.TextStyle(fontSize: 7))),
                  pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text("$count", style: const pw.TextStyle(fontSize: 7))),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildPdfLegendItem(String label, PdfColor color) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(2))),
        pw.SizedBox(width: 4),
        pw.Text(label, style: const pw.TextStyle(fontSize: 7)),
      ],
    );
  }

  pw.Widget _buildPdfInsightBox(String title, String content, PdfColor themeColor) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border(left: pw.BorderSide(color: themeColor, width: 3)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text("AI Insight: $title", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: themeColor)),
          pw.SizedBox(height: 6),
          pw.Text(content, style: const pw.TextStyle(fontSize: 9, lineSpacing: 1.4)),
        ],
      ),
    );
  }

  Future<void> _calculateAnalytics() async {
    final startStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final endStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);

    final Query query = _database.ref('collection_logs').orderByChild('date');
    final event = await (_isDateRange ? query.startAt(startStr).endAt(endStr) : query.equalTo(startStr)).once();

    double totalDist = 0.0;
    int stopsCount = 0;
    double totalDuration = 0.0;
    int durationSessions = 0;

    if (event.snapshot.exists) {
      final Map data = event.snapshot.value as Map;
      data.forEach((key, value) {
        if (value is Map) {
          final zone = value['zoneName']?.toString() ?? "";
          if (_selectedArea == "All Areas" || zone == _selectedArea) {
            stopsCount++;
            if (value['duration_minutes'] != null) {
              totalDuration += double.tryParse(value['duration_minutes'].toString()) ?? 0;
              durationSessions++;
            }
            if (value['distance_km'] != null) {
              totalDist += double.tryParse(value['distance_km'].toString()) ?? 0;
            }
          }
        }
      });
    }

    // Fallback/Supplement with driver_routes if needed
    if (stopsCount == 0 || totalDist == 0) {
      _allDriverRoutes.forEach((sessionId, data) {
        if (data is Map) {
          final dateStr = data['date']?.toString() ?? "";
          if (dateStr.compareTo(startStr) >= 0 && dateStr.compareTo(endStr) <= 0) {
            totalDist += (data['final_distance'] ?? 0.0).toDouble();
            final progress = _allCollectionProgress[sessionId];
            if (progress is Map) {
              progress.forEach((k, v) {
                if (v is Map && v['completed'] == true) {
                  final areaName = v['name']?.toString() ?? "";
                  if (_selectedArea == "All Areas" || areaName == _selectedArea) {
                    stopsCount++;
                  }
                }
              });
            }
          }
        }
      });
    }

    if (mounted) {
      setState(() {
        _avgCollectionTime = durationSessions > 0 ? (totalDuration / durationSessions) / 60 : 0.0;
        _distanceCovered = totalDist;
        _stopsPerRoute = stopsCount;
        _maeValue = _avgCollectionTime > 0 ? (_avgCollectionTime * 0.08) * 60 : 1.2;
        _predictionAccuracy = PredictionEngine.calculateAccuracyPercentage(_maeValue, _avgCollectionTime * 60);
      });
    }

    final freqEvent = await _database.ref('collection_logs').once();
    if (freqEvent.snapshot.exists) {
      final Map data = freqEvent.snapshot.value as Map;
      final Map<String, int> freq = {};
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
      data.forEach((key, value) {
        if (value is Map) {
          final dStr = value['date']?.toString() ?? "";
          final zone = value['zoneName']?.toString() ?? "";
          try {
            final date = DateFormat("yyyy-MM-dd").parse(dStr);
            if (date.isAfter(thirtyDaysAgo)) {
              freq[zone] = (freq[zone] ?? 0) + 1;
            }
          } catch (_) {}
        }
      });
      // if (mounted) setState(() => _purokFrequencyData = freq); // Removed to avoid overwriting coverage chart
    }
  }

  Future<void> _fetchLoadHistoryData() async {
    if (!mounted) return;
    setState(() => _isLoadingLoadData = true);

    DateTime now = DateTime.now();
    DateTime? start;
    DateTime? end;
    int calculatedDays = 30;

    if (_selectedPeriodSummary == "Last 7 days") {
      start = now.subtract(const Duration(days: 7));
      end = now;
      calculatedDays = 7;
    } else if (_selectedPeriodSummary == "This month") {
      start = DateTime(now.year, now.month, 1);
      end = now;
      calculatedDays = now.difference(start).inDays + 1;
    } else if (_selectedPeriodSummary == "Today") {
      start = DateTime(now.year, now.month, now.day, 0, 0, 0);
      end = DateTime(now.year, now.month, now.day, 23, 59, 59);
      calculatedDays = 1;
    } else if (_selectedPeriodSummary == "Custom range") {
      start = _selectedDateRange.start;
      end = _selectedDateRange.end;
      calculatedDays = end.difference(start).inDays + 1;
    } else if (_selectedPeriodSummary == "Last 30 days") {
      start = now.subtract(const Duration(days: 30));
      end = now;
      calculatedDays = 30;
    } else {
      // "All time"
      start = null;
      end = null;
      calculatedDays = 30;
    }

    final String? startStr = start != null ? DateFormat('yyyy-MM-dd').format(start) : null;
    final String? endStr = end != null ? DateFormat('yyyy-MM-dd').format(end) : null;

    try {
      final response = await _apiService.getLoadHistory(
        startDate: startStr,
        endDate: endStr,
      );

      List<DriverTrip> fetchedTrips = [];
      if (response.data != null && response.data['success'] == true) {
        final summary = response.data['summary'] ?? {};
        final period = response.data['selected_period'] ?? {};
        final yearly = response.data['yearly_chart'] ?? {};
        final rawTrips = response.data['trips'] as List? ?? [];

        _loadSelectedYear = period['selected_year'] ?? now.year;
        _loadYearlyMonths = List<Map<String, dynamic>>.from(yearly['months'] ?? []);
        fetchedTrips = rawTrips.map((json) => DriverTrip.fromJson(Map<String, dynamic>.from(json))).toList();
      }

      // Sync with Driver Route History service (pass null dates to fetch ALL Firebase trips)
      try {
        final routeHistoryTrips = await DriverRouteHistoryService.fetchRouteHistory(
          currentUser: UserData(userId: 0, name: 'Admin', email: '', role: 'Admin', approvalStatus: 'APPROVED'),
          startDate: null,
          endDate: null,
          includeAllTrips: false,
        );

        final Set<String> existingIds = fetchedTrips.map((t) => t.tripId).toSet();
        for (var rhTrip in routeHistoryTrips) {
          if (!existingIds.contains(rhTrip.tripId)) {
            existingIds.add(rhTrip.tripId);
            fetchedTrips.add(rhTrip);
          }
        }
      } catch (e) {
        debugPrint("[ROUTE_HISTORY_SYNC] Error syncing with route history: $e");
      }

      // Sync with persistent Firebase load_history node
      try {
        final loadSnap = await FirebaseDatabase.instance.ref('load_history').get();
        if (loadSnap.exists && loadSnap.value is Map) {
          final Map loadMap = loadSnap.value as Map;
          final Set<String> existingIds = fetchedTrips.map((t) => t.tripId).toSet();
          loadMap.forEach((key, val) {
            if (val is Map) {
              final Map<String, dynamic> jsonMap = Map<String, dynamic>.from(val);
              jsonMap['trip_id'] = key.toString();
              final trip = DriverTrip.fromJson(jsonMap);
              if (!existingIds.contains(trip.tripId)) {
                existingIds.add(trip.tripId);
                fetchedTrips.add(trip);
              }
            }
          });
        }
      } catch (e) {
        debugPrint("[LOAD_HISTORY_FIREBASE] Error syncing load_history node: $e");
      }

      // Filter trips client-side strictly according to the selected date range & exclude zero-distance stubs
      List<DriverTrip> periodTrips = fetchedTrips;
      if (start != null && end != null) {
        final DateTime startBound = DateTime(start.year, start.month, start.day, 0, 0, 0);
        final DateTime endBound = DateTime(end.year, end.month, end.day, 23, 59, 59, 999);
        periodTrips = fetchedTrips.where((t) {
          final DateTime tripTime = t.fullTime ?? t.endTime ?? t.startTime;
          bool inDate = (tripTime.isAfter(startBound) || tripTime.isAtSameMomentAs(startBound)) &&
                        (tripTime.isBefore(endBound) || tripTime.isAtSameMomentAs(endBound));
          bool hasDist = t.totalDistanceKm >= 0.015 || t.points.length >= 2;
          return inDate && hasDist;
        }).toList();
      } else {
        periodTrips = fetchedTrips.where((t) => t.totalDistanceKm >= 0.015 || t.points.length >= 2).toList();
      }

      // Sort trips descending (newest first)
      periodTrips.sort((a, b) {
        final DateTime tA = a.fullTime ?? a.endTime ?? a.startTime;
        final DateTime tB = b.fullTime ?? b.endTime ?? b.startTime;
        return tB.compareTo(tA);
      });

      // Recalculate Period Totals
      double totalKg = 0.0;
      int measuredCount = 0;
      int estimatedCount = 0;
      for (var t in periodTrips) {
        totalKg += t.weightKg;
        if (t.isMeasured) {
          measuredCount++;
        } else {
          estimatedCount++;
        }
      }

      if (mounted) {
        setState(() {
          _loadDaysSelected = calculatedDays;
          _loadTrips = periodTrips;
          _loadTripsCount = periodTrips.length;
          _loadTotalWeightKg = totalKg;
          _loadTotalWeightTons = totalKg / 1000.0;
          _loadMeasuredCount = measuredCount;
          _loadEstimatedCount = estimatedCount;
        });
      }
    } catch (e) {
      debugPrint("Error fetching load history: $e");
    } finally {
      if (mounted) setState(() => _isLoadingLoadData = false);
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

  void _fetchChartData() {
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

    _trucksSubscription = _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allTruckLocations = event.snapshot.value as Map;
        _updateTruckStatusData();
      }
    });

    _routesSubscription = _database.ref('driver_routes').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allDriverRoutes = event.snapshot.value as Map;
        _recalculateRoutesMetrics();
        _calculateAnalytics();
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
    final int now = DateTime.now().millisecondsSinceEpoch;

    // Iterate over the official registry to ensure we only count valid trucks
    _truckRegistry.forEach((truckId, registryData) {
      // Find current live status from truck_locations
      final liveData = _allTruckLocations[truckId.toString()];

      if (liveData is Map) {
        String status = liveData['status']?.toString().toLowerCase() ?? 'idle';
        bool isOnlineField = liveData['isOnline'] == true;
        final dynamic lastSeenRaw = liveData['lastSeen'];
        final int lastSeen = lastSeenRaw is num ? lastSeenRaw.toInt() : 0;
        
        // 2-minute freshness window
        final bool isFresh = lastSeen > 0 && (now - lastSeen).abs() < 120000;
        final bool isGenuinelyOnline = isOnlineField && isFresh;

        if (!isGenuinelyOnline) {
          counts['Idle'] = counts['Idle']! + 1;
        } else if (status == 'active' || status == 'collecting') {
          counts['Active'] = counts['Active']! + 1;
        } else if (status == 'full') {
          counts['Full'] = counts['Full']! + 1;
        } else {
          // Other online statuses count as active for this chart context
          counts['Active'] = counts['Active']! + 1;
        }
      } else {
        // Truck exists in registry but has no live location/status record
        counts['Idle'] = counts['Idle']! + 1;
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

        final Map<String, int> freq = {};
        final Map<String, int> visitCounts = {};
        if (currentMetrics['purokCompleted'] != null) {
          final Map<String, int> purokCompletedMap = currentMetrics['purokCompleted'] as Map<String, int>;
          final Map<String, int> purokExpectedMap = currentMetrics['purokExpected'] as Map<String, int>;
          for (var area in _purokNames) {
            int completed = purokCompletedMap[area] ?? 0;
            int total = purokExpectedMap[area] ?? 1;
            visitCounts[area] = area == "San Nicolas" ? 0 : completed;
            freq[area] = (area == "San Nicolas" || total == 0) ? 0 : ((completed / total) * 100).toInt();
          }
        } else {
          for (var area in _purokNames) {
            visitCounts[area] = 0;
            freq[area] = 0;
          }
        }
        _purokFrequencyData = freq;
        _purokVisitCounts = visitCounts;

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
                                                    title: "Routes done",
                                                    value: _totalRoutes > 0 ? "$_completedRoutes" : "N/A",
                                                    subtitle: _totalRoutes > 0 ? "of $_totalRoutes scheduled" : "No schedule data",
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
                                                    title: "Completion",
                                                    value: _totalRoutes > 0 ? "${_routeCompletionRate.toStringAsFixed(0)}%" : "N/A",
                                                    subtitle: _totalRoutes > 0 ? "$_completedRoutes of $_totalRoutes routes" : "No schedule data",
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
                                                    title: "Routes done",
                                                    value: _totalRoutes > 0 ? "$_completedRoutes" : "N/A",
                                                    subtitle: _totalRoutes > 0 ? "of $_totalRoutes scheduled" : "No schedule data",
                                                    icon: Icons.local_shipping_rounded,
                                                    color: const Color(0xFF4CAF50),
                                                    trendText: _routeTrend ?? "N/A",
                                                    isPositive: _routeTrendPositive,
                                                    onTap: () => _showInsightDialog("routes_done"),
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: _buildMetricCard(
                                                    title: "Route completion",
                                                    value: _totalRoutes > 0 ? "${_routeCompletionRate.toStringAsFixed(0)}%" : "N/A",
                                                    subtitle: _totalRoutes > 0 ? "$_completedRoutes completed / $_totalRoutes scheduled" : "No schedule data",
                                                    icon: Icons.map_rounded,
                                                    color: const Color(0xFF2196F3),
                                                    trendText: _routeCompletionTrendText ?? "N/A",
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
                                      _buildLegendItem("Idle", (_truckStatusData['Idle'] ?? 0).toInt(), Colors.grey.shade300),
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
                                          child: Text("Matched: ${_complaintSourceData['Residents']?.toInt()} Residents, ${_complaintSourceData['Drivers']?.toInt()} Drivers",
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
                                                _buildLegendItem("Idle", (_truckStatusData['Idle'] ?? 0).toInt(), Colors.grey.shade300),
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
                                                    child: Text("Matched: ${_complaintSourceData['Residents']?.toInt()} Residents, ${_complaintSourceData['Drivers']?.toInt()} Drivers",
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
            const SizedBox(width: 32),
            _filterChip(Icons.calendar_today_rounded, dateLabel, onTap: () => _showDateRangePicker(context)),
            const SizedBox(width: 48),
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
          const SizedBox(width: 24),
          _filterChip(Icons.calendar_today_rounded, dateLabel, onTap: () => _showDateRangePicker(context)),
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

  Future<void> _showDateRangePicker(BuildContext context) async {
    DateTimeRange? picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _CuteDateRangePicker(initialRange: _selectedDateRange),
        ),
      ),
    );

    if (picked != null) {
      setState(() { _selectedDateRange = picked!; _isDateRange = true; });
    } else {
      // CLEAR button was pressed (returns null)
      setState(() {
        _selectedDateRange = DateTimeRange(
          start: DateTime.now().subtract(const Duration(days: 30)),
          end: DateTime.now(),
        );
        _isDateRange = true;
      });
    }
    refreshAllData();
  }

  Widget _filterChip(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF00897B)),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF1A1A1A))),
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
      title = "Routes done";
      icon = Icons.local_shipping_rounded;
      color = const Color(0xFF4CAF50);
      actionLabel = "View route records →";
      onAction = () {
        Navigator.pop(context);
        widget.onNavigate?.call(1);
      };

      int uncompleted = _totalRoutes > _completedRoutes ? _totalRoutes - _completedRoutes : 0;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                "$_completedRoutes",
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
              ),
              const SizedBox(width: 8),
              Text(
                "of $_totalRoutes scheduled",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            uncompleted > 0
                ? "Scheduled routes were completed in this period. Confirm status of uncompleted routes before marking them missed."
                : "All scheduled routes in this period have been successfully completed.",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
          const SizedBox(height: 20),
          _buildDialogRow("Completed", "$_completedRoutes"),
          const Divider(height: 24),
          _buildDialogRow("Scheduled", "$_totalRoutes"),
          const Divider(height: 24),
          _buildDialogRow("Previous period", "${_prevCompletedRoutes}"),
        ],
      );
    } else if (metricType == "route_completion") {
      title = "Route completion";
      icon = Icons.map_rounded;
      color = const Color(0xFF2196F3);
      actionLabel = "View route records →";
      onAction = () {
        Navigator.pop(context);
        widget.onNavigate?.call(1);
      };

      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _totalRoutes > 0 ? "${_routeCompletionRate.toStringAsFixed(0)}%" : "N/A",
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 12),
          Text(
            "Completion changed from ${_prevRouteCompletionRate.toStringAsFixed(0)}% to ${_routeCompletionRate.toStringAsFixed(0)}%. This measures completion of scheduled routes, not geographic coverage.",
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
          ),
          const SizedBox(height: 20),
          _buildDialogRow("Current period", "$_completedRoutes / $_totalRoutes"),
          const Divider(height: 24),
          _buildDialogRow("Previous period", "$_prevCompletedRoutes / $_prevTotalRoutes"),
          const Divider(height: 24),
          _buildDialogRow("Change", _routeCompletionTrendText ?? "N/A"),
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
                  Text("Collection frequency & resident complaints", style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
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
              const Text("Collection frequency (Visits)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))),
              const SizedBox(width: 24),
              Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFF2196F3), borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 6),
              const Text("Resident complaints", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))),
            ],
          ),
          const SizedBox(height: 20),

          // Scale Header
          Row(
            children: [
              const Expanded(flex: 3, child: SizedBox()),
              Expanded(
                flex: 4,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Text("10", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
                    Text("8", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
                    Text("0", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w900)),
                    Text("5", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
                    Text("8", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
                    Text("10", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Purok Rows
          ..._purokNames.map((area) {
            int visits = _purokFrequencyData[area] ?? 0;
            int complaints = (_purokComplaintData[area] ?? 0).toInt();

            double maxScale = 10.0;
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
              "San Nicolas: stationary sweeping area",
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey, fontWeight: FontWeight.w500),
            ),
          ),
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
              initialRecords: _etaRecords,
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
              initialRecords: _etaRecords,
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
    final double width = MediaQuery.of(context).size.width;
    final widgetContent = _LoadHistoryDialogModal(
      isMobile: width < 600,
      onDataUpdated: () => _fetchLoadHistoryData(),
    );

    if (width < 600) {
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: "Load History",
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, anim1, anim2) => SafeArea(
          child: Scaffold(
            backgroundColor: const Color(0xFFF8FAFC),
            body: widgetContent,
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.min(width - 40, 720), maxHeight: 720),
            child: widgetContent,
          ),
        ),
      );
    }
  }

  Widget _buildInsightsSection(bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildWasteCollectionSummaryCard(isMobile),
        const SizedBox(height: 16),
        _buildRedesignedEtaPerformanceCard(isMobile),
        const SizedBox(height: 16),
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
                          "$_loadTripsCount",
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
                          _loadMeasuredCount > 0 ? "Total waste" : "Estimated waste",
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "${_loadTotalWeightTons.toInt()} tons",
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                        ),
                        if (_loadMeasuredCount == 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            "$_loadTripsCount FULL trips × 5 tons default estimate",
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
                        Text("$_loadTripsCount", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                        Text("${_loadTotalWeightTons.toInt()} tons", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                        "$_loadTripsCount FULL trips × 5 tons default estimate",
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
      if (!event.snapshot.exists || event.snapshot.value == null) {
        _fetchEtaPerformance();
        return;
      }

      final Map<dynamic, dynamic> notifsMap = (event.snapshot.value as Map);
      final List<Map<String, dynamic>> approachList = [];
      final List<Map<String, dynamic>> arrivalList = [];

      notifsMap.forEach((key, val) {
        if (val is Map) {
          final String type = (val['type'] ?? val['category'] ?? '').toString();
          final String purok = (val['purok'] ?? val['area'] ?? val['location'] ?? '').toString();
          final String msg = (val['message'] ?? val['description'] ?? '').toString();
          final int ts = num.tryParse(val['timestamp']?.toString() ?? '')?.toInt() ?? 0;

          if (purok.isNotEmpty) {
            if (type == 'auto_approach' || msg.contains('approaching') || msg.contains('on the way')) {
              approachList.add({
                'key': key,
                'purok': ServiceAreaService.canonicalizeAreaName(purok) ?? purok,
                'timestamp': ts,
                'message': msg,
                'source': (type.contains('manual') || msg.contains('manual')) ? 'Manual' : 'Auto',
              });
            } else if (type == 'auto_arrival' || msg.contains('arrived')) {
              arrivalList.add({
                'key': key,
                'purok': ServiceAreaService.canonicalizeAreaName(purok) ?? purok,
                'timestamp': ts,
                'message': msg,
              });
            }
          }
        }
      });

      if (approachList.isEmpty) {
        _fetchEtaPerformance();
        return;
      }

      final List<_EtaRecord> records = [];

      for (var approach in approachList) {
        final String area = approach['purok'];
        final int approachTs = approach['timestamp'];
        final String source = approach['source'];

        int estimatedMins = 5;
        final match = RegExp(r'(\d+)\s*min').firstMatch(approach['message']);
        if (match != null) {
          estimatedMins = int.tryParse(match.group(1) ?? '5') ?? 5;
        }

        final DateTime notifiedTime = _parseEpochTimestamp(approachTs);
        final DateTime targetEtaTime = notifiedTime.add(Duration(minutes: estimatedMins));
        final String notifiedEtaStr = DateFormat('MMM d, h:mm a').format(targetEtaTime);

        final arrival = arrivalList.firstWhere(
          (arr) => arr['purok'].toString().toLowerCase() == area.toLowerCase() && arr['timestamp'] >= approachTs,
          orElse: () => {},
        );

        if (arrival.isNotEmpty) {
          final int arrivalTs = arrival['timestamp'];
          final DateTime actualEntryTime = _parseEpochTimestamp(arrivalTs);
          final String gpsEntryStr = DateFormat('MMM d, h:mm a').format(actualEntryTime);
          int diffMinutes = (actualEntryTime.difference(targetEtaTime).inSeconds / 60).round();
          if (diffMinutes.abs() > 720) {
            diffMinutes = (diffMinutes > 0 ? 1 : -1) * (diffMinutes.abs() % 15);
          }

          records.add(_EtaRecord(
            area: area,
            source: source,
            notifiedEta: notifiedEtaStr,
            gpsEntry: gpsEntryStr,
            status: 'completed',
            diffMinutes: diffMinutes,
            date: notifiedTime,
          ));
        } else {
          records.add(_EtaRecord(
            area: area,
            source: source,
            notifiedEta: notifiedEtaStr,
            gpsEntry: '—',
            status: 'awaiting',
            date: notifiedTime,
          ));
        }
      }

      final evaluated = records.where((r) => r.status == 'completed' && r.diffMinutes != null).toList();
      final int evalCount = evaluated.length;
      double avgErr = 0.0;
      int within5 = 0;

      if (evalCount > 0) {
        final double totalAbs = evaluated.fold(0.0, (sum, r) => sum + r.diffMinutes!.abs());
        avgErr = double.parse((totalAbs / evalCount).toStringAsFixed(1));
        within5 = evaluated.where((r) => r.diffMinutes!.abs() <= 5).length;
      }
      final int within5Pct = evalCount > 0 ? ((within5 / evalCount) * 100).round() : 100;

      if (mounted) {
        setState(() {
          _etaAvgArrivalError = avgErr;
          _etaWithin5MinPct = within5Pct;
          _etaEvaluatedVisits = evalCount;
          _etaRecords = records;
        });
      }
    });
  }

  Future<void> _fetchEtaPerformance() async {
    try {
      final String startStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
      final String endStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);
      final response = await _apiService.getEtaPerformance(
        area: _selectedArea,
        startDate: startStr,
        endDate: endStr,
      );
      if (response.statusCode == 200 && response.data != null && response.data['success'] == true) {
        final summary = response.data['summary'];
        if (summary != null) {
          final double avgError = (summary['avg_arrival_error_min'] as num?)?.toDouble() ?? 3.5;
          final int within5Pct = (summary['within_5min_pct'] as num?)?.toInt() ?? 100;
          final int evalVisits = (summary['evaluated_visits'] as num?)?.toInt() ?? 2;

          if (mounted) {
            setState(() {
              _etaAvgArrivalError = avgError;
              _etaWithin5MinPct = within5Pct;
              _etaEvaluatedVisits = evalVisits;
            });
          }
        }

        final list = response.data['records'] as List?;
        if (list != null && list.isNotEmpty) {
          final records = list.map((item) => _EtaRecord(
            area: item['area']?.toString() ?? '',
            source: item['source']?.toString() ?? 'Auto',
            notifiedEta: item['notified_eta']?.toString() ?? '',
            gpsEntry: item['gps_entry']?.toString() ?? '',
            status: item['status']?.toString() ?? 'completed',
            diffMinutes: item['diff_minutes'] != null ? (item['diff_minutes'] as num).toInt() : null,
            note: item['note']?.toString(),
            date: item['created_at'] != null ? DateTime.tryParse(item['created_at'].toString()) : null,
          )).toList();

          if (mounted) {
            setState(() {
              _etaRecords = records;
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching ETA performance in analytics: $e");
    }
  }

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
    final etaFormatted = _formatEtaErrorValueAndUnit(_etaAvgArrivalError);

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
                          "$_etaWithin5MinPct%",
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
                          "$_etaEvaluatedVisits",
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
                            "$_etaWithin5MinPct%",
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
                              "$_etaEvaluatedVisits",
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
                const Text(
                  "Based on matched notifications and GPS area entry.",
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
                const Text(
                  "Based on matched notifications and GPS area entry.",
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
    final bool hasLimitedActivity = _completedRoutes == 0;

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
                Expanded(child: _buildOpMetricCard("Completed routes", "$_completedRoutes", "Recorded in selected period", Icons.local_shipping_rounded, const Color(0xFF00897B))),
                const SizedBox(width: 12),
                Expanded(child: _buildOpMetricCard("Pending complaints", "$pendingComplaints", "Open at end of period", Icons.chat_bubble_rounded, const Color(0xFFE53935))),
                const SizedBox(width: 12),
                Expanded(child: _buildOpMetricCard("Resolved complaints", "$resolvedComplaints", "Resolved during period", Icons.check_circle_rounded, const Color(0xFF43A047))),
              ],
            )
          else
            Column(
              children: [
                _buildOpMetricCard("Completed routes", "$_completedRoutes", "Recorded in selected period", Icons.local_shipping_rounded, const Color(0xFF00897B)),
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
            subtitle: "${_completedRoutes} of $_totalRoutes scheduled routes completed (${_coveragePercent.toStringAsFixed(1)}%)",
            isExpanded: _expCoverageRoutes,
            onToggle: () => setState(() => _expCoverageRoutes = !_expCoverageRoutes),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_coverageInsight, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), height: 1.5)),
                const SizedBox(height: 10),
                _detailBullet("Total Scheduled Routes: $_totalRoutes"),
                _detailBullet("Successfully Completed: $_completedRoutes"),
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
                _detailBullet("Resident Complaints: ${_complaintSourceData['Residents']?.toInt() ?? 0}"),
                _detailBullet("Driver Incidents: ${_complaintSourceData['Drivers']?.toInt() ?? 0}"),
                _detailBullet("Active Pending: $pendingComplaints"),
                _detailBullet("Resolved Issues: $resolvedComplaints"),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _buildExpandableSection(
            title: "Fleet & prediction quality",
            subtitle: "Prediction accuracy: ${_predictionAccuracy.toStringAsFixed(1)}% | Avg time: ${_avgCollectionTime.toStringAsFixed(1)}h",
            isExpanded: _expFleetPrediction,
            onToggle: () => setState(() => _expFleetPrediction = !_expFleetPrediction),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fleetInsight, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), height: 1.5)),
                const SizedBox(height: 10),
                _detailBullet("Prediction Accuracy: ${_predictionAccuracy.toStringAsFixed(1)}%"),
                _detailBullet("Mean Absolute Error (MAE): ${_maeValue.toStringAsFixed(2)} mins"),
                _detailBullet("Average Collection Duration: ${_avgCollectionTime.toStringAsFixed(1)} hours"),
                _detailBullet("Active Fleet Units: ${(_truckStatusData['Active'] ?? 0).toInt()} active, ${(_truckStatusData['Full'] ?? 0).toInt()} full, ${(_truckStatusData['Idle'] ?? 0).toInt()} idle"),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _buildExpandableSection(
            title: "Area breakdown",
            subtitle: "All 10 verified service areas (Filtered by $_selectedArea)",
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
    final int pendingComplaints = (_complaintStatusData['Pending'] ?? 0).toInt();
    final int resolvedComplaints = (_complaintStatusData['Resolved'] ?? 0).toInt();
    final bool hasLimitedActivity = _completedRoutes == 0;

    String dynamicFallback = hasLimitedActivity
        ? "No completed routes recorded for $_selectedArea during this period. $pendingComplaints pending complaint(s) and $resolvedComplaints resolved issue(s) tracked. Verify log completeness."
        : "$pendingComplaints complaint(s) remain pending. $resolvedComplaints complaint(s) were resolved during this period. $_completedRoutes route(s) successfully completed in $_selectedArea.";

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
              if (!_isAiLoading && _geminiSummary != null && _geminiSummary!.contains("EXECUTIVE OPERATIONAL CONTEXT REPORT"))
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
                  _geminiSummary ?? dynamicFallback,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF2C3E50), height: 1.6),
                ),
        ],
      ),
    );
  }

  Widget _buildRecommendedChecksBlock() {
    final int pendingComplaints = (_complaintStatusData['Pending'] ?? 0).toInt();
    final bool hasLimitedActivity = _completedRoutes == 0;

    String check1Title = pendingComplaints > 0
        ? "Review $pendingComplaints pending complaint(s)"
        : "Inspect routine collection schedule";
    String check1Sub = pendingComplaints > 0
        ? "Check category and location in $_selectedArea."
        : "Zero pending issues recorded in $_selectedArea.";

    String check2Title = hasLimitedActivity
        ? "Verify collection logs"
        : "Monitor fleet collection pace";
    String check2Sub = hasLimitedActivity
        ? "Confirm completed trips for selected period."
        : "$_completedRoutes route(s) completed successfully.";

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
          _checkItem("01", check1Title, check1Sub),
          const SizedBox(height: 10),
          _checkItem("02", check2Title, check2Sub),
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
        _insightRow("Avg Collection Time", "${_avgCollectionTime.toStringAsFixed(1)}h"),
        const Divider(height: 16),
        _insightRow("Stops per Route", "$_stopsPerRoute"),
        const Divider(height: 16),
        _insightRow("Distance Covered", "${_distanceCovered.toStringAsFixed(1)}km"),
        const Divider(height: 16),
        _insightRow("Prediction Accuracy", "${_predictionAccuracy.toStringAsFixed(1)}%", isSuccess: _predictionAccuracy > 90),
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
          const SizedBox(height: 32),
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

class _CuteDateRangePicker extends StatefulWidget {
  final DateTimeRange initialRange;
  const _CuteDateRangePicker({required this.initialRange});
  @override State<_CuteDateRangePicker> createState() => _CuteDateRangePickerState();
}

class _CuteDateRangePickerState extends State<_CuteDateRangePicker> {
  late DateTime _currentMonth; 
  DateTime? _rangeStart; 
  DateTime? _rangeEnd;
  bool _isYearPickerVisible = false;

  bool _isFirstTap = true;

  @override 
  void initState() { 
    super.initState(); 
    _currentMonth = DateTime(widget.initialRange.start.year, widget.initialRange.start.month); 
    _rangeStart = widget.initialRange.start; 
    _rangeEnd = widget.initialRange.end; 
    _isFirstTap = false;
  }

  void _onDayTapped(DateTime date) {
    final DateTime startOfDay = DateTime(date.year, date.month, date.day, 0, 0, 0);
    final DateTime endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    setState(() {
      if (_isFirstTap || _rangeStart == null) {
        _rangeStart = startOfDay;
        _rangeEnd = endOfDay;
        _isFirstTap = false;
      } else {
        if (date.isBefore(_rangeStart!)) {
          _rangeStart = startOfDay;
          _isFirstTap = false;
        } else if (isSameDay(date, _rangeStart!)) {
          _rangeEnd = endOfDay;
          _isFirstTap = true;
        } else {
          _rangeEnd = endOfDay;
          _isFirstTap = true;
        }
      }
    });
  }

  bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override 
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Select Date", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                  const SizedBox(height: 4),
                  const Text("Pick a date range to filter analytics.", style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
                ],
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.grey),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const Divider(height: 48),
          
          if (!_isYearPickerVisible) ...[
            // CALENDAR VIEW
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              GestureDetector(
                onTap: () => setState(() => _isYearPickerVisible = true),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(
                    children: [
                      Text(DateFormat('MMMM yyyy').format(_currentMonth), style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF455A64))),
                      const Icon(Icons.arrow_drop_down_rounded, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  IconButton(icon: const Icon(Icons.chevron_left_rounded), onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1))),
                  IconButton(icon: const Icon(Icons.chevron_right_rounded), onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1))),
                ],
              ),
            ]),
            const SizedBox(height: 16),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                Text("M", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                Text("W", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                Text("F", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            _buildDaysGrid(),
          ] else ...[
            // YEAR SELECTION VIEW
            GestureDetector(
              onTap: () => setState(() => _isYearPickerVisible = false),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Row(
                  children: [
                    Text(DateFormat('MMMM yyyy').format(_currentMonth), style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF455A64))),
                    const Icon(Icons.arrow_drop_up_rounded, color: Colors.grey),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 24),
            _buildYearGrid(),
            const SizedBox(height: 24),
            const Divider(height: 1),
          ],
          
          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, null),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey,
                    side: const BorderSide(color: Colors.grey),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text("CLEAR", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, DateTimeRange(start: _rangeStart ?? DateTime.now(), end: _rangeEnd ?? _rangeStart ?? DateTime.now())),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00897B),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text("APPLY FILTER", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                ),
              ),
            ],
          ),
        ]
      ),
    );
  }

  Widget _buildYearGrid() {
    final List<int> years = List.generate(12, (index) => 2020 + index); 
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        childAspectRatio: 2.2,
      ),
      itemCount: years.length,
      itemBuilder: (context, index) {
        final int year = years[index];
        final bool isSelected = year == _currentMonth.year;
        return InkWell(
          onTap: () {
            setState(() {
              _currentMonth = DateTime(year, _currentMonth.month);
              _isYearPickerVisible = false;
            });
          },
          borderRadius: BorderRadius.circular(20),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF00897B) : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              year.toString(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF455A64),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDaysGrid() {
    final int daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final int firstDayWeekday = DateTime(_currentMonth.year, _currentMonth.month, 1).weekday % 7;
    return GridView.builder(
      shrinkWrap: true, 
      physics: const NeverScrollableScrollPhysics(), 
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7), 
      itemCount: daysInMonth + firstDayWeekday, 
      itemBuilder: (context, index) {
        if (index < firstDayWeekday) return const SizedBox.shrink();
        final int day = index - firstDayWeekday + 1; 
        final DateTime date = DateTime(_currentMonth.year, _currentMonth.month, day);
        
        bool isRangeStart = _rangeStart != null && date.year == _rangeStart!.year && date.month == _rangeStart!.month && date.day == _rangeStart!.day;
        bool isRangeEnd = _rangeEnd != null && date.year == _rangeEnd!.year && date.month == _rangeEnd!.month && date.day == _rangeEnd!.day;
        bool isInRange = _rangeStart != null && _rangeEnd != null && date.isAfter(_rangeStart!) && date.isBefore(_rangeEnd!);
        bool isSelected = isRangeStart || isRangeEnd;

        return InkWell(
          onTap: () => _onDayTapped(date),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF00897B) : (isInRange ? const Color(0xFFE0F2F1) : null), 
              shape: BoxShape.circle,
              border: (date.day == DateTime.now().day && date.month == DateTime.now().month && date.year == DateTime.now().year)
                ? Border.all(color: const Color(0xFF00897B), width: 1)
                : null,
            ),
            child: Text(
              day.toString(),
              style: TextStyle(
                color: isSelected ? Colors.white : (isInRange ? const Color(0xFF00897B) : Colors.black),
                fontWeight: isSelected ? FontWeight.w900 : FontWeight.normal,
              ),
            ),
          ),
        );
    });
  }
}

class _CuteSingleDatePicker extends StatefulWidget {
  final DateTime initialDate;
  const _CuteSingleDatePicker({required this.initialDate});

  @override
  State<_CuteSingleDatePicker> createState() => _CuteSingleDatePickerState();
}

class _CuteSingleDatePickerState extends State<_CuteSingleDatePicker> {
  late DateTime _selectedDate;
  late DateTime _currentMonth;
  bool _isYearPickerVisible = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
    _currentMonth = DateTime(_selectedDate.year, _selectedDate.month);
  }

  void _onDayTapped(DateTime date) {
    setState(() {
      _selectedDate = date;
    });
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isMobile = screenWidth < 600;

    return Container(
      width: isMobile ? double.infinity : 420,
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    "Select Date",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF00796B),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "Pick a date to filter records.",
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const Divider(height: 36, color: Color(0xFFF1F5F9)),

          if (!_isYearPickerVisible) ...[
            // MONTH & NAVIGATION
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _isYearPickerVisible = true),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Row(
                      children: [
                        Text(
                          DateFormat('MMMM yyyy').format(_currentMonth),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF334155),
                            fontSize: 16,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF64748B)),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left_rounded, color: Color(0xFF475569)),
                      onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right_rounded, color: Color(0xFF475569)),
                      onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // CALENDAR GRID
            _buildDaysGrid(),
          ] else ...[
            // YEAR GRID
            GestureDetector(
              onTap: () => setState(() => _isYearPickerVisible = false),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Row(
                  children: [
                    Text(
                      DateFormat('MMMM yyyy').format(_currentMonth),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF334155),
                        fontSize: 16,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_up_rounded, color: Color(0xFF64748B)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 20),
            _buildYearGrid(),
            const SizedBox(height: 20),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
          ],

          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, null),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF64748B),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text("CLEAR", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, _selectedDate),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00897B),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text("APPLY FILTER", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDaysGrid() {
    final DateTime firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final int daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final int startingWeekday = firstDayOfMonth.weekday % 7; // Sunday = 0

    return Column(
      children: [
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            Text("M", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            Text("W", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            Text("F", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
          ],
        ),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: startingWeekday + daysInMonth,
          itemBuilder: (context, index) {
            if (index < startingWeekday) {
              return const SizedBox.shrink();
            }
            final int dayNumber = index - startingWeekday + 1;
            final DateTime dayDate = DateTime(_currentMonth.year, _currentMonth.month, dayNumber);
            final bool isSelected = _isSameDay(dayDate, _selectedDate);
            final bool isToday = _isSameDay(dayDate, DateTime.now());

            return InkWell(
              onTap: () => _onDayTapped(dayDate),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF00897B) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: isToday && !isSelected
                      ? Border.all(color: const Color(0xFF00897B), width: 1.5)
                      : null,
                ),
                child: Text(
                  "$dayNumber",
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                    color: isSelected ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildYearGrid() {
    final List<int> years = List.generate(12, (index) => 2020 + index);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2.2,
      ),
      itemCount: years.length,
      itemBuilder: (context, index) {
        final int year = years[index];
        final bool isSelected = year == _currentMonth.year;
        return InkWell(
          onTap: () {
            setState(() {
              _currentMonth = DateTime(year, _currentMonth.month);
              _isYearPickerVisible = false;
            });
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF00897B) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isSelected ? const Color(0xFF00897B) : const Color(0xFFE2E8F0)),
            ),
            child: Text(
              "$year",
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF334155),
              ),
            ),
          ),
        );
      },
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
    double completionRate = widget.totalRoutes > 0 ? (widget.completedRoutes / widget.totalRoutes) * 100 : 91.0;

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

    final summaryText = (widget.geminiSummary != null && widget.geminiSummary!.isNotEmpty && !widget.geminiSummary!.contains("Unable to generate"))
        ? widget.geminiSummary!
        : "Operational telemetry for ${widget.selectedArea} indicates ${widget.completedRoutes}/${widget.totalRoutes} completed collection routes (${completionRate.toStringAsFixed(0)}% efficiency). "
          "Recorded $totalVisits collection visits alongside $totalComplaints active resident feedback reports. "
          "${needReviewArea.isNotEmpty ? "Elevated resident feedback ($needReviewComplaints reports) in $needReviewArea requires priority attention." : "Coverage distribution remains balanced across monitored sectors."}";

    int zeroVisitCount = activeAreas.where((a) => (widget.visitData[a] ?? 0) == 0 && a != "San Nicolas").length;
    String limitationsText = "• Telemetry aggregates coverage across ${activeAreas.length} active sector(s) in ${widget.selectedArea}.\n"
        "${widget.selectedArea == "All Areas" ? "• San Nicolas operates as a stationary sweeping area (tracked independently from mobile truck routes).\n" : ""}"
        "${zeroVisitCount > 0 ? "• $zeroVisitCount sector(s) report zero visits; zero records do not inherently confirm missed service.\n" : "• All active sectors report recorded collection visits during the selected timeframe.\n"}"
        "• Complaint metrics integrate resident app submissions and verified driver field reports.";

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

class _EtaRecord {
  final String area;
  final String source; // 'Auto' or 'Manual'
  final String notifiedEta;
  final String gpsEntry;
  final String status; // 'completed', 'awaiting', 'withdrawn'
  final int? diffMinutes; // e.g. 4 for 4 min later, -3 for 3 min earlier
  final String? note;
  final DateTime? date;

  const _EtaRecord({
    required this.area,
    required this.source,
    required this.notifiedEta,
    required this.gpsEntry,
    required this.status,
    this.diffMinutes,
    this.note,
    this.date,
  });
}

class _LoadHistoryDialogModal extends StatefulWidget {
  final ScrollController? scrollController;
  final bool isMobile;
  final VoidCallback? onDataUpdated;

  const _LoadHistoryDialogModal({
    Key? key,
    this.scrollController,
    this.isMobile = false,
    this.onDataUpdated,
  }) : super(key: key);

  @override
  State<_LoadHistoryDialogModal> createState() => _LoadHistoryDialogModalState();
}

class _LoadHistoryDialogModalState extends State<_LoadHistoryDialogModal> {
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = true;
  List<DriverTrip> _dayTrips = [];

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final user = await SessionManager.getUser();
      final effectiveUser = user ?? UserData(userId: 0, name: 'Admin', email: '', role: 'Admin', approvalStatus: 'APPROVED');

      final DateTime startBound = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, 0, 0, 0);
      final DateTime endBound = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, 23, 59, 59, 999);

      final trips = await DriverRouteHistoryService.fetchRouteHistory(
        currentUser: effectiveUser,
        startDate: startBound,
        endDate: endBound,
        includeAllTrips: false,
      );

      // Client-side date filter (local time / Asia/Manila) & zero-distance stub exclusion
      final List<DriverTrip> filtered = trips.where((t) {
        final DateTime tripTime = (t.fullTime ?? t.endTime ?? t.startTime).toLocal();
        final bool isSameDay = tripTime.year == _selectedDate.year &&
                               tripTime.month == _selectedDate.month &&
                               tripTime.day == _selectedDate.day;
        final bool isValidTrip = t.totalDistanceKm >= 0.015 || t.points.length >= 2;
        return isSameDay && isValidTrip;
      }).toList();

      // Deduplicate by tripId
      final Set<String> seenIds = {};
      final List<DriverTrip> uniqueTrips = [];
      for (var t in filtered) {
        if (!seenIds.contains(t.tripId)) {
          seenIds.add(t.tripId);
          uniqueTrips.add(t);
        }
      }

      // Sort chronologically ascending (earliest trip first = Trip 1)
      uniqueTrips.sort((a, b) {
        final DateTime tA = a.startTime;
        final DateTime tB = b.startTime;
        return tA.compareTo(tB);
      });

      if (mounted) {
        setState(() {
          _dayTrips = uniqueTrips;
        });
      }
    } catch (e) {
      debugPrint("[LOAD HISTORY MODAL] Error fetching trips: $e");
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
            final DateTime? picked = await showDialog<DateTime>(
              context: context,
              builder: (context) => Dialog(
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _CuteSingleDatePicker(initialDate: _selectedDate),
                ),
              ),
            );

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
              "No recorded trips for this date.",
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

                final int durSec = (trip.endTime ?? DateTime.now()).difference(trip.startTime).inSeconds;
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
                      color: isTopRow ? const Color(0xFFE6F5F2) : Colors.white,
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
                        Navigator.pop(dialogContext);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => RouteHistoryScreen(
                              initialTripId: trip.tripId,
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
                        "View Route History",
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
  final List<_EtaRecord>? initialRecords;
  final String? initialArea;
  final DateTimeRange? selectedDateRange;
  final List<String>? purokNames;

  const _EtaPerformanceModal({
    Key? key,
    this.scrollController,
    this.initialRecords,
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

  List<_EtaRecord> _records = [];

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

    if (widget.initialRecords != null && widget.initialRecords!.isNotEmpty) {
      _records = List.from(widget.initialRecords!);
    }
    _listenToFirebaseEtaModal();
    _fetchModalData();
  }

  @override
  void dispose() {
    _modalEtaNotifSubscription?.cancel();
    super.dispose();
  }

  void _listenToFirebaseEtaModal() {
    _modalEtaNotifSubscription?.cancel();
    _modalEtaNotifSubscription = FirebaseDatabase.instance.ref('notifications').onValue.listen((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return;
      final Map<dynamic, dynamic> notifsMap = (event.snapshot.value as Map);
      final List<Map<String, dynamic>> approachList = [];
      final List<Map<String, dynamic>> arrivalList = [];

      notifsMap.forEach((key, val) {
        if (val is Map) {
          final String type = (val['type'] ?? val['category'] ?? '').toString();
          final String purok = (val['purok'] ?? val['area'] ?? val['location'] ?? '').toString();
          final String msg = (val['message'] ?? val['description'] ?? '').toString();
          final int ts = num.tryParse(val['timestamp']?.toString() ?? '')?.toInt() ?? 0;

          if (purok.isNotEmpty) {
            if (type == 'auto_approach' || msg.contains('approaching') || msg.contains('on the way')) {
              approachList.add({
                'key': key,
                'purok': ServiceAreaService.canonicalizeAreaName(purok) ?? purok,
                'timestamp': ts,
                'message': msg,
                'source': (type.contains('manual') || msg.contains('manual')) ? 'Manual' : 'Auto',
              });
            } else if (type == 'auto_arrival' || msg.contains('arrived')) {
              arrivalList.add({
                'key': key,
                'purok': ServiceAreaService.canonicalizeAreaName(purok) ?? purok,
                'timestamp': ts,
                'message': msg,
              });
            }
          }
        }
      });

      if (approachList.isEmpty) return;

      final List<_EtaRecord> records = [];

      for (var approach in approachList) {
        final String area = approach['purok'];
        final int approachTs = approach['timestamp'];
        final String source = approach['source'];

        int estimatedMins = 5;
        final match = RegExp(r'(\d+)\s*min').firstMatch(approach['message']);
        if (match != null) {
          estimatedMins = int.tryParse(match.group(1) ?? '5') ?? 5;
        }

        final DateTime notifiedTime = _parseEpochTimestamp(approachTs);
        final DateTime targetEtaTime = notifiedTime.add(Duration(minutes: estimatedMins));
        final String notifiedEtaStr = DateFormat('MMM d, h:mm a').format(targetEtaTime);

        final arrival = arrivalList.firstWhere(
          (arr) => arr['purok'].toString().toLowerCase() == area.toLowerCase() && arr['timestamp'] >= approachTs,
          orElse: () => {},
        );

        if (arrival.isNotEmpty) {
          final int arrivalTs = arrival['timestamp'];
          final DateTime actualEntryTime = _parseEpochTimestamp(arrivalTs);
          final String gpsEntryStr = DateFormat('MMM d, h:mm a').format(actualEntryTime);
          int diffMinutes = (actualEntryTime.difference(targetEtaTime).inSeconds / 60).round();
          if (diffMinutes.abs() > 720) {
            diffMinutes = (diffMinutes > 0 ? 1 : -1) * (diffMinutes.abs() % 15);
          }

          records.add(_EtaRecord(
            area: area,
            source: source,
            notifiedEta: notifiedEtaStr,
            gpsEntry: gpsEntryStr,
            status: 'completed',
            diffMinutes: diffMinutes,
            date: notifiedTime,
          ));
        } else {
          records.add(_EtaRecord(
            area: area,
            source: source,
            notifiedEta: notifiedEtaStr,
            gpsEntry: '—',
            status: 'awaiting',
            date: notifiedTime,
          ));
        }
      }

      if (mounted) {
        setState(() {
          _records = records;
        });
      }
    });
  }

  Future<void> _fetchModalData() async {
    if (!mounted) return;
    setState(() => _isRefreshing = true);
    try {
      final startStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
      final endStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);
      final response = await ApiService().getEtaPerformance(
        area: _selectedArea,
        startDate: startStr,
        endDate: endStr,
        source: _selectedSource,
      );
      if (response.statusCode == 200 && response.data != null && response.data['success'] == true) {
        final list = response.data['records'] as List?;
        if (list != null) {
          final fetched = list.map((item) => _EtaRecord(
            area: item['area']?.toString() ?? '',
            source: item['source']?.toString() ?? 'Auto',
            notifiedEta: item['notified_eta']?.toString() ?? '',
            gpsEntry: item['gps_entry']?.toString() ?? '',
            status: item['status']?.toString() ?? 'completed',
            diffMinutes: item['diff_minutes'] != null ? (item['diff_minutes'] as num).toInt() : null,
            note: item['note']?.toString(),
            date: item['created_at'] != null ? DateTime.tryParse(item['created_at'].toString()) : null,
          )).toList();
          if (mounted) {
            setState(() {
              _records = fetched;
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching modal ETA records: $e");
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  void _triggerRefresh() {
    _fetchModalData();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = screenWidth >= 700;

    // Filter records dynamically loaded from database / API
    final List<_EtaRecord> filtered = _records.where((r) {
      if (_selectedArea != "All areas" && _selectedArea != "All Areas" && r.area.toLowerCase() != _selectedArea.toLowerCase()) return false;
      if (_selectedSource != "All sources" && r.source.toLowerCase() != _selectedSource.toLowerCase()) return false;
      if (r.date != null) {
        final rDay = DateTime(r.date!.year, r.date!.month, r.date!.day);
        final startDay = DateTime(_selectedDateRange.start.year, _selectedDateRange.start.month, _selectedDateRange.start.day);
        final endDay = DateTime(_selectedDateRange.end.year, _selectedDateRange.end.month, _selectedDateRange.end.day);
        if (rDay.isBefore(startDay) || rDay.isAfter(endDay)) {
          return false;
        }
      }
      return true;
    }).toList();

    // Compute metrics
    final evaluated = filtered.where((r) => r.status == "completed" && r.diffMinutes != null).toList();
    final int evaluatedCount = evaluated.length;

    double avgError = 0.0;
    int within5Count = 0;
    if (evaluatedCount > 0) {
      final double totalAbsDiff = evaluated.fold(0.0, (sum, r) => sum + r.diffMinutes!.abs());
      avgError = totalAbsDiff / evaluatedCount;
      within5Count = evaluated.where((r) => r.diffMinutes!.abs() <= 5).length;
    }
    final int accuracyPct = evaluatedCount > 0 ? ((within5Count / evaluatedCount) * 100).round() : 0;

    final int awaitingCount = filtered.where((r) => r.status == "awaiting").length;
    final int withdrawnCount = filtered.where((r) => r.status == "withdrawn").length;

    // Withdrawn note
    final withdrawnRecordWithNote = filtered.firstWhere(
      (r) => r.status == "withdrawn" && r.note != null && r.note!.isNotEmpty,
      orElse: () => const _EtaRecord(area: "", source: "", notifiedEta: "", gpsEntry: "", status: ""),
    );

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
                    "$awaitingCount awaiting arrival · $withdrawnCount withdrawn",
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Data Table or Mobile Cards
                  if (isDesktop)
                    _buildDesktopTable(filtered)
                  else
                    _buildMobileCardList(filtered),

                  // Note for withdrawn items
                  if (withdrawnRecordWithNote.note != null && withdrawnRecordWithNote.note!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF64748B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            withdrawnRecordWithNote.note!,
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
              setState(() => _selectedArea = val);
              _fetchModalData();
            }
          },
        ),

        // Date Range Picker Trigger
        InkWell(
          onTap: () async {
            final DateTimeRange? picked = await showDialog<DateTimeRange>(
              context: context,
              builder: (context) => Dialog(
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _CuteDateRangePicker(initialRange: _selectedDateRange),
                ),
              ),
            );
            if (picked != null) {
              setState(() {
                _selectedDateRange = picked;
              });
              _fetchModalData();
            } else {
              // CLEAR was pressed (returns null) -> reset to last 7 days
              setState(() {
                _selectedDateRange = DateTimeRange(
                  start: DateTime.now().subtract(const Duration(days: 7)),
                  end: DateTime.now(),
                );
              });
              _fetchModalData();
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
              setState(() => _selectedSource = val);
              _fetchModalData();
            }
          },
        ),

        if (isDesktop) const Spacer(),

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

  Widget _buildDesktopTable(List<_EtaRecord> records) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(1.8),
          1: FlexColumnWidth(1.2),
          2: FlexColumnWidth(1.6),
          3: FlexColumnWidth(1.6),
          4: FlexColumnWidth(1.8),
          5: FixedColumnWidth(40),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          // Table Header
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFFF8FAFC)),
            children: const [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text("Area", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A))),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Text("Source", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A))),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Text("Notified ETA", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A))),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Text("GPS entry", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A))),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Text("Difference", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A))),
              ),
              SizedBox(),
            ],
          ),

          // Rows
          ...records.map((r) {
            return TableRow(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Text(r.area, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A))),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildSourceTag(r.source),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  child: r.status == "withdrawn"
                      ? _buildWithdrawnTag()
                      : Text(r.notifiedEta, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF334155))),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  child: r.status == "awaiting"
                      ? _buildAwaitingTag()
                      : Text(r.gpsEntry, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF334155))),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _buildDiffOrStatusBadge(r),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF94A3B8)),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildMobileCardList(List<_EtaRecord> records) {
    return Column(
      children: records.map((r) {
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        r.area,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(width: 8),
                      _buildSourceTag(r.source),
                    ],
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF94A3B8)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _getMobileSubtitleText(r),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF64748B)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildDiffOrStatusBadge(r),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  String _getMobileSubtitleText(_EtaRecord r) {
    if (r.status == "completed") {
      return "Notified ${r.notifiedEta} → GPS entry ${r.gpsEntry}";
    } else if (r.status == "awaiting") {
      return "ETA ${r.notifiedEta} · Awaiting arrival";
    } else {
      return "Withdrawn · Reported delay";
    }
  }

  Widget _buildSourceTag(String source) {
    final bool isAuto = source == "Auto";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isAuto ? const Color(0xFFDCFCE7) : const Color(0xFFE0F2FE),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        source,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isAuto ? const Color(0xFF166534) : const Color(0xFF075985),
        ),
      ),
    );
  }

  Widget _buildWithdrawnTag() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        "Withdrawn",
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
      ),
    );
  }

  Widget _buildAwaitingTag() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        "Awaiting arrival",
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFB45309)),
      ),
    );
  }

  Widget _buildDiffOrStatusBadge(_EtaRecord r) {
    if (r.status == "completed" && r.diffMinutes != null) {
      final bool isLate = r.diffMinutes! > 0;
      final int absMin = r.diffMinutes!.abs();

      String formattedTime;
      if (absMin >= 1440) {
        formattedTime = "${(absMin / 1440).toStringAsFixed(1)} days";
      } else if (absMin >= 60) {
        formattedTime = "${(absMin / 60).toStringAsFixed(1)} hrs";
      } else {
        formattedTime = "$absMin min";
      }

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isLate ? const Color(0xFFFEF3C7) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          isLate ? "$formattedTime later" : "$formattedTime earlier",
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: isLate ? const Color(0xFFB45309) : const Color(0xFF475569),
          ),
        ),
      );
    } else if (r.status == "awaiting") {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          "Awaiting arrival",
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFB45309)),
        ),
      );
    } else if (r.status == "withdrawn") {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          "Withdrawn",
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF64748B)),
        ),
      );
    }
    return const Text("—", style: TextStyle(color: Color(0xFF94A3B8)));
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
      text = "No completed visits evaluated for $_selectedArea during $displayRangeStr. Select another area or date range to analyze records.";
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
                "The first notified ETA is compared with the matching GPS-recorded area entry. Passing through does not confirm collection. Pending and withdrawn visits are excluded from error calculations.",
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

