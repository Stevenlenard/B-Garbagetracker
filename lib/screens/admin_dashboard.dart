import '../utils/rtdb_map.dart';
import '../services/server_clock.dart';
import '../widgets/logout_choice_dialog.dart';
import '../utils/relative_time.dart';
import '../services/rtdb_port.dart';
import '../services/notification_inbox.dart';
import '../models/driver_trip.dart';
import '../utils/route_history_navigation.dart';
import '../utils/admin_quick_actions.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show setEquals;
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/notification_center.dart';
import '../chatbot/faq_bot.dart';
import '../widgets/truck_chat_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
import 'package:firebase_database/firebase_database.dart';
import '../utils/collection_visits.dart';
import '../services/service_area_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../utils/custom_notification.dart';
import '../api/api_service.dart';
import '../utils/session_manager.dart';
import '../utils/app_theme.dart';
import '../utils/system_logger.dart';
import '../utils/responsive.dart';
import '../utils/prediction_engine.dart';
import '../utils/fleet_snapshot.dart';
import '../utils/fleet_status.dart';
import '../utils/tracking_telemetry.dart';
import 'analytics_screen.dart';
import 'track_trucks_screen.dart';
import 'complaints_screen.dart';
import 'admin_settings_screen.dart';
import 'data_management_screen.dart';
import 'user_management_screen.dart';
import 'route_history_screen.dart';
import '../widgets/mapbox_view.dart';
import 'route_assignments_screen.dart';
import '../services/admin_settings_service.dart';
import '../services/notification_service.dart';
import '../services/truck_assignment_service.dart';
import '../widgets/header_circle_painter.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';
import '../widgets/data_management_modal.dart';
import '../utils/route_persistence_manager.dart';
import '../utils/app_localizations.dart';
import '../utils/responsive_text.dart';
import '../models/user.dart';
import '../services/truck_locations_feed.dart';
import 'collection_route_optimization_screen.dart';

class AdminDashboard extends StatefulWidget {
  /// Section to open on (AdminDestinations.*). Lets a direct link to Route History land
  /// inside the dashboard shell.
  final int initialIndex;
  const AdminDashboard({super.key, this.initialIndex = 0});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> with TickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  final AdminSettingsService _adminSettingsService = AdminSettingsService();
  final ScrollController _scrollController = ScrollController();
  bool _showHeaderShadow = true;

  int _activeTrucks = 0;
  int _onlineDriversCount = 0;
  final Set<String> _archivedDriverIds = {};
  final Set<String> _archivedDriverNames = {};
  final Set<String> _validDriverIds = {};
  final Set<String> _validDriverNames = {};
  final Set<String> _genuinelyOnlineDriverIds = {};
  final Set<String> _genuinelyOnlineDriverNamesUpper = {};
  StreamSubscription? _usersPresenceSubscription;
  StreamSubscription? _truckLocationsSubscription;
  // Latest raw `truck_locations` snapshot. The fleet is re-derived from it whenever
  // either the truck data or the driver presence data changes.
  Map<dynamic, dynamic> _rawTruckLocations = {};
  VoidCallback? _recomputeFleet;
  Timer? _fleetAgingTimer;
  NotificationInbox? _inbox; // this admin's own read/dismiss/clear state
  InboxState _inboxState = InboxState.empty;
  StreamSubscription<InboxState>? _inboxSub;
  Map<dynamic, dynamic>? _rawNotifications;
  Map<dynamic, dynamic>? _rawUsers; // latest raw `users`, re-evaluated as it ages
  String _fleetSignature = '';
  int _pendingComplaints = 0;
  int _inProgressComplaints = 0;
  int _residentsCount = 0;
  int _unreadNotificationsCount = 0;
  double _coveragePercent = 0.0; // collection areas with a verified visit in the last 7 days
  int _coverageVisited = 0;
  int _coverageAreas = 0;
  List<AreaGeofence>? _coverageGeofences;
  Map _coverageTrips = const <dynamic, dynamic>{};
  late int _selectedIndex = widget.initialIndex;
  String? _routeHistoryTripId; // trip requested by Load History / fleet panels
  DriverTrip? _routeHistoryTrip;
  final RouteHistoryReturn _routeReturn = RouteHistoryReturn(routeHistoryIndex: AdminDestinations.routeHistory); // section Route History returns to
  int _routeHistoryEpoch = 0; // bumped on each open so Route History shows current data
  bool _isSidebarExtended = true;
  bool _isRefreshing = false;
  bool _showRefreshSpinner = false;
  bool _isScanningFleet = true;
  late AnimationController _circleController;
  late AnimationController _refreshRotationController;
  UserData? _user;
  StreamSubscription? _userSubscription;
  String _currentTime = "";
  Timer? _clockTimer;

  final Map<String, String> _truckPlates = {}; // Cache for plate numbers
  StreamSubscription? _trucksMetaSubscription;

  List<Map<dynamic, dynamic>> _fleetStatus = [];
  List<Map<dynamic, dynamic>> _recentLogs = [];

  @override
  void initState() {
    super.initState();
    NotificationService.openHomeRequests.addListener(_openHomeFromNotification);
    _loadUser();
    _startClock();
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();
    _refreshRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _scrollController.addListener(() {
      if (_scrollController.offset <= 0 && !_showHeaderShadow) {
        setState(() => _showHeaderShadow = true);
      } else if (_scrollController.offset > 0 && _showHeaderShadow) {
        setState(() => _showHeaderShadow = false);
      }
    });
    RoutePersistenceManager.saveLastRoute('/admin_dashboard');
    _adminSettingsService.startListening();
    _setupListeners();
    _listenToUsersPresence();
    _refreshAllStats();
    _checkAutoBackupDownload();
    _setupLogsListener();
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _isScanningFleet = false);
    });
  }

  void _loadUser() async {
    _user = await SessionManager.getUser();
    if (_user != null) {
      NotificationService.startListening(_user!);
      _setupUserListener();
      _listenToTruckMeta(); // Added metadata listener
    }
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _allTrucksRegistry = {};

  void _listenToTruckMeta() {
    _trucksMetaSubscription?.cancel();
    _trucksMetaSubscription = _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        _allTrucksRegistry = Map<String, dynamic>.from(data);
        final Map<String, String> newPlates = {};
        data.forEach((key, value) {
          if (value is Map) {
            final String? plate = value['plateNumber']?.toString() ?? value['plate_number']?.toString();
            if (plate != null && plate.isNotEmpty) {
              newPlates[key.toString().toUpperCase()] = plate;
            }
          }
        });
        if (mounted) {
          setState(() => _truckPlates.addAll(newPlates));
        }
      }
    });
  }

  void _setupUserListener() {
    if (_user == null) return;
    _userSubscription?.cancel();
    _userSubscription = _database.ref('users/${_user!.userId}').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        if (mounted) {
          setState(() {
            final Map<String, dynamic> currentData = _user!.toJson();
            data.forEach((k, v) => currentData[k] = v);
            _user = UserData.fromJson(currentData);
          });
        }
      }
    });
  }

  void _startClock() {
    _updateTime();
    _clockTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      _updateTime();
    });
  }

  void _updateTime() {
    final String time = DateFormat('hh:mm:ss a').format(DateTime.now());
    if (mounted && _currentTime != time) {
      setState(() {
        _currentTime = time;
      });
    }
  }

  /// A tapped phone notification shows the dashboard's Home tab.
  void _openHomeFromNotification() {
    if (mounted) setState(() => _selectedIndex = 0);
  }

  @override
  void dispose() {
    NotificationService.openHomeRequests.removeListener(_openHomeFromNotification);
    _circleController.dispose();
    _refreshRotationController.dispose();
    _clockTimer?.cancel();
    _userSubscription?.cancel();
    _usersPresenceSubscription?.cancel();
    _fleetAgingTimer?.cancel();
    _truckLocationsSubscription?.cancel();
    _trucksMetaSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupLogsListener() {
    _database.ref('system_logs').limitToLast(10).onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map? data = event.snapshot.value as Map?;
        if (data == null) return;
        final List<Map<dynamic, dynamic>> logs = [];
        data.forEach((key, value) {
          if (value is Map) logs.add(Map<dynamic, dynamic>.from(value));
        });
        logs.sort((a, b) => (b['timestamp'] ?? 0).toString().compareTo((a['timestamp'] ?? 0).toString()));
        if (mounted) setState(() => _recentLogs = logs);
      }
    });
  }

  Future<void> _checkAutoBackupDownload() async {
    try {
      final user = await SessionManager.getUser();
      if (user == null || user.role != 'admin') return;
      final settingsRes = await _apiService.getUserSettings(user.userId, user.role);
      final settingsData = settingsRes.data;
      if (settingsData is Map && settingsData['success'] == true && settingsData['data'] != null && settingsData['data']['auto_backup'] == true) {
        final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
        final lastDownload = await SessionManager.getLastAutoDownloadDate();
        if (lastDownload != today) {
          final response = await _apiService.triggerAutoBackupChecker();
          final data = response.data;
          if (data is Map && data['success'] == true && data['url'] != null) {
            final uri = Uri.parse(data['url']);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              await SessionManager.setLastAutoDownloadDate(today);
              if (mounted) CustomNotification.showTopNotification(context, "Daily auto-backup downloaded: ${data['filename']}", false);
            }
          }
        }
      }
    } catch (e) { debugPrint("Auto-backup check error: $e"); }
  }

  Future<void> _refreshAllStats({bool manual = false}) async {
    if (_isRefreshing) return;
    
    debugPrint("[REFRESH] Starting refresh. Manual: $manual");
    
    if (mounted) {
      setState(() {
        _isRefreshing = true;
        _showRefreshSpinner = manual;
      });
    }
    _refreshRotationController.repeat();

    try {
      await Future.wait([
        _fetchComplaints(),
        _fetchUserCounts(),
        Future.delayed(const Duration(milliseconds: 1500)),
      ]);
    } catch (e) {
      debugPrint("[REFRESH] Error during data fetch: $e");
    }

    if (manual) {
      debugPrint("[REFRESH] Data loaded, holding for 2 seconds...");
      // Stay displayed and keep spinning for 2 more seconds after data is loaded
      // so the user can clearly see the refresh finished before it retreats.
      await Future.delayed(const Duration(seconds: 2));
    }

    if (mounted) {
      debugPrint("[REFRESH] Retreating spinner...");
      setState(() {
        _isRefreshing = false;
      });
      // Delay setting _showRefreshSpinner to false to allow retreat animation
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) setState(() => _showRefreshSpinner = false);
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
                        "Dashboard metrics synchronized",
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
    debugPrint("[REFRESH] Refresh sequence complete.");
  }

  Future<void> _fetchUserCounts() async {
    try {
      final response = await _apiService.getUsers();
      if (response.data['success'] == true) {
        final List residents = response.data['residents'] ?? [];
        if (mounted) setState(() => _residentsCount = residents.length);
      }
    } catch (e) { debugPrint("Error fetching user counts: $e"); }
  }

  void _listenToUsersPresence() {
    _usersPresenceSubscription?.cancel();
    _usersPresenceSubscription = _database.ref('users').onValue.listen((event) {
      _rawUsers = event.snapshot.exists ? rtdbMap(event.snapshot.value) : null;
      _applyUsersPresence();
    });
    // Presence ages without any event (a crashed driver writes nothing), so it is
    // re-evaluated on a timer using the same freshness rule.
    _fleetAgingTimer?.cancel();
    _fleetAgingTimer = Timer.periodic(const Duration(seconds: 15), (_) => _applyUsersPresence());
  }

  void _applyUsersPresence() {
    {
      if (_rawUsers != null) {
        final Map data = _rawUsers!;

        int onlineCount = 0;
        final int now = ServerClock.instance.nowMs();
        final Set<String> archivedIds = {};
        final Set<String> archivedNames = {};
        final Set<String> validDriverIds = {};
        final Set<String> validDriverNames = {};
        final Set<String> genuinelyOnlineDriverIds = {};
        final Set<String> genuinelyOnlineDriverNamesUpper = {};

        debugPrint("=== ADMIN DASHBOARD ONLINE DRIVERS TRACE ===");
        data.forEach((key, value) {
          if (value != null && value is Map) {
            final String role = (value['role'] ?? '').toString().toLowerCase();
            final String driverUid = key.toString();
            final String driverName = (value['name'] ?? value['username'] ?? 'Driver').toString();
            final String status = (value['account_status'] ?? '').toString().toLowerCase();
            final dynamic isArchivedRaw = value['is_archived'] ?? value['isArchived'];
            final bool isArchived = status == 'archived' ||
                isArchivedRaw == 1 ||
                isArchivedRaw == '1' ||
                isArchivedRaw == true ||
                isArchivedRaw == 'true';

            if (isArchived) {
              archivedIds.add(driverUid);
              if (driverName.isNotEmpty) archivedNames.add(driverName.toUpperCase());
            } else if (role == 'driver') {
              validDriverIds.add(driverUid);
              if (driverName.isNotEmpty) validDriverNames.add(driverName.toUpperCase());

              final bool isOnline = FleetStatus.hasOnlineFlag(value);
              final String userStatus = (value['status'] ?? '').toString().toUpperCase();
              final dynamic lastSeenRaw = value['lastSeen'];
              final int lastSeen = lastSeenRaw is num ? lastSeenRaw.toInt() : 0;
              
              // A COMPLETED driver is still connected until logout/disconnect.
              final bool genuinelyOnline = isOnline &&
                  userStatus != 'OFFLINE' &&
                  FleetStatus.isFresh(lastSeen, now);

              debugPrint("[DRIVER_PRESENCE_CHECK] uid: $driverUid | name: $driverName | isOnline: $isOnline | status: $userStatus | genuinelyOnline: $genuinelyOnline");

              if (genuinelyOnline) {
                onlineCount++;
                genuinelyOnlineDriverIds.add(driverUid);
                if (driverName.isNotEmpty) genuinelyOnlineDriverNamesUpper.add(driverName.toUpperCase());
              }
            }
          }
        });
        debugPrint("[ADMIN_ONLINE_DRIVERS_COUNT] Total online drivers: $onlineCount");
        debugPrint("=============================================");

        final bool presenceUnchanged = setEquals(_archivedDriverIds, archivedIds) &&
            setEquals(_archivedDriverNames, archivedNames) &&
            setEquals(_validDriverIds, validDriverIds) &&
            setEquals(_validDriverNames, validDriverNames) &&
            setEquals(_genuinelyOnlineDriverIds, genuinelyOnlineDriverIds) &&
            setEquals(_genuinelyOnlineDriverNamesUpper, genuinelyOnlineDriverNamesUpper);
        if (mounted && !presenceUnchanged) {
          // The "Online Drivers" card is derived from the Active Fleet list
          // (_recomputeFleet) so both always agree; presence only feeds its inputs.
          setState(() {
            _archivedDriverIds.clear();
            _archivedDriverIds.addAll(archivedIds);
            _archivedDriverNames.clear();
            _archivedDriverNames.addAll(archivedNames);
            _validDriverIds.clear();
            _validDriverIds.addAll(validDriverIds);
            _validDriverNames.clear();
            _validDriverNames.addAll(validDriverNames);
            _genuinelyOnlineDriverIds.clear();
            _genuinelyOnlineDriverIds.addAll(genuinelyOnlineDriverIds);
            _genuinelyOnlineDriverNamesUpper.clear();
            _genuinelyOnlineDriverNamesUpper.addAll(genuinelyOnlineDriverNamesUpper);
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _archivedDriverIds.clear();
            _archivedDriverNames.clear();
            _validDriverIds.clear();
            _validDriverNames.clear();
            _genuinelyOnlineDriverIds.clear();
            _genuinelyOnlineDriverNamesUpper.clear();
          });
        }
      }
      // Presence changed: re-derive the fleet so the cards never lag behind it.
      _recomputeFleet?.call();
    }
  }

  void _setupListeners() {
    _recomputeFleet = () {
      {
        final Map<dynamic, dynamic> data = _rawTruckLocations;

        final int now = ServerClock.instance.nowMs();

        // Shared fleet snapshot (same function as the Resident cards and the live map).
        // Admin adds account validity from `users` (role == driver, not archived) and
        // requires the account itself to be genuinely online.
        final FleetSnapshot fleet = FleetSnapshot.derive(
          data,
          nowMs: now,
          includeCompleted: true, // connected COMPLETED drivers count as online
          exclude: (String nodeKey, Map node) {
            final String? dId = node['driver_id']?.toString() ?? node['driverId']?.toString();
            final String dNameUpper = (node['driver_name'] ?? node['driverName'] ?? 'Driver').toString().trim().toUpperCase();
            final bool hasId = dId != null && dId.isNotEmpty && dId != 'null';
            final bool isDriverIdValid = !hasId || _validDriverIds.isEmpty || _validDriverIds.contains(dId);
            final bool isDriverNameValid = _validDriverNames.isEmpty || _validDriverNames.contains(dNameUpper);
            return !isDriverIdValid ||
                !isDriverNameValid ||
                (hasId && _archivedDriverIds.contains(dId)) ||
                _archivedDriverNames.contains(dNameUpper);
          },
          requirePresence: (String driverKey, Map node) {
            final String? dId = node['driver_id']?.toString() ?? node['driverId']?.toString();
            final String dNameUpper = (node['driver_name'] ?? node['driverName'] ?? 'Driver').toString().trim().toUpperCase();
            return (dId != null && _genuinelyOnlineDriverIds.contains(dId)) ||
                _genuinelyOnlineDriverNamesUpper.contains(dNameUpper);
          },
        );

        final List<Map<dynamic, dynamic>> onlineTrucks = [];
        // Every connected driver is listed (COMPLETED included, with its COMPLETED badge), so
        // Fleet Status matches the Online Drivers count; only collecting trucks feed the speed.
        for (final LiveTruck t in fleet.trucks) {
          final Map<dynamic, dynamic> truckMap = Map<dynamic, dynamic>.from(t.node);
          final resolved = TruckAssignmentService.resolveFleetNode(
            nodeKey: t.nodeKey,
            liveData: truckMap,
            trucksRegistry: _allTrucksRegistry,
          );
          truckMap['internal_id'] = t.nodeKey;
          truckMap['truck_id'] = resolved.truckId;
          truckMap['truckNumber'] = resolved.truckNumber;
          truckMap['plate_number'] = resolved.plateNumber;
          truckMap['driver_name'] = resolved.driverName;
          truckMap['isOnline'] = true;
          if (t.isCompleted) {
            truckMap['status'] = 'COMPLETED';
            truckMap['speed'] = 0; // unloaded/finished: not collecting
          }
          onlineTrucks.add(truckMap);
        }
        // The count includes connected COMPLETED drivers that the fleet list omits, so the
        // snapshot's own signature must be part of the change check.
        final String fleetSignature = '${fleet.signature}#' + (onlineTrucks
                .map((Map<dynamic, dynamic> t) =>
                    '${t['internal_id']}|${t['driver_id']}|${t['status']}|${t['lastSeen']}|${t['latitude']}|${t['longitude']}|${t['speed']}')
                .toList()
              ..sort())
            .join(';');
        if (mounted && fleetSignature != _fleetSignature) {
          _fleetSignature = fleetSignature;
          setState(() {
            _activeTrucks = fleet.activeFleets;
            _onlineDriversCount = fleet.onlineDrivers;
            _fleetStatus = onlineTrucks;
          });
        }
      }
    };
    _truckLocationsSubscription?.cancel();
    _truckLocationsSubscription = TruckLocationsFeed.shared().events.listen((event) {
      final Object? raw = event.snapshot.value;
      // An empty/removed node yields an empty map so the fleet clears instead of going stale.
      _rawTruckLocations = (event.snapshot.exists && raw is Map)
          ? Map<dynamic, dynamic>.from(raw)
          : <dynamic, dynamic>{};
      // Dev-only timing (test mode + GT_TELEMETRY): delivery delay, then S4 = next frame after recompute.
      final Stopwatch? telemetryClock = TrackingTelemetry.enabled ? (Stopwatch()..start()) : null;
      TrackingTelemetry.onTruckLocations(raw, source: 'admin_fleet');
      _recomputeFleet?.call();
      if (telemetryClock != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          TrackingTelemetry.onFleetRendered(source: 'admin_cards', ms: telemetryClock.elapsedMilliseconds);
        });
      }
    });

    // Route Coverage = share of the collection areas with a verified visit in the last 7 days
    // (the same visit rule as Analytics and Purok Coverage).
    _database.ref('driver_routes').onValue.listen((event) {
      _coverageTrips = (event.snapshot.exists && event.snapshot.value is Map) ? event.snapshot.value as Map : const <dynamic, dynamic>{};
      _updateRouteCoverage();
    });

    // Complaint counts come ONLY from the MySQL complaints table (get_complaints.php), the same
    // data the Complaint Management screen shows. The legacy Firebase `complaints` node is not
    // a source: it used to overwrite these counts with stale values.

    _database.ref('notifications').onValue.listen((event) {
      _ensureInbox();
      _rawNotifications = (event.snapshot.exists && event.snapshot.value is Map) ? event.snapshot.value as Map : null;
      _recomputeAdminUnread();

      // A new resident complaint was saved: re-read the counts from MySQL.
      int complaintNotifs = 0;
      _rawNotifications?.forEach((k, v) {
        if (v is Map && (v['type'] ?? '').toString() == 'RESIDENT_COMPLAINT') complaintNotifs++;
      });
      if (_complaintNotifCount >= 0 && complaintNotifs > _complaintNotifCount) {
        _fetchComplaints();
      }
      _complaintNotifCount = complaintNotifs;
    });
  }

  int _complaintNotifCount = -1; // -1 until the first snapshot

  void _ensureInbox() {
    if (_inbox != null || _user == null) return;
    _inbox = NotificationInbox(db: FirebaseRtdbPort(), role: 'admin', userId: _user!.userId);
    _inboxSub = _inbox!.watch().listen((InboxState st) {
      _inboxState = st;
      _recomputeAdminUnread();
    });
  }

  /// Relevant notifications minus what THIS admin dismissed/cleared (shared log untouched).
  List<Map> _adminVisibleNotifications() {
    final Map? data = _rawNotifications;
    final List<Map> relevant = <Map>[];
    data?.forEach((k, v) {
      if (v is Map && _isNotificationForMe(v)) relevant.add(<dynamic, dynamic>{...v, 'id': k, 'key': k});
    });
    return NotificationInbox.visible(relevant, _inboxState);
  }

  void _recomputeAdminUnread() {
    final int unread = NotificationInbox.unreadCount(_adminVisibleNotifications(), _inboxState);
    if (mounted) setState(() => _unreadNotificationsCount = unread);
  }

  bool _isNotificationForMe(Map val) {
    final String type = (val['type'] ?? '').toString();
    final String targetRole = (val['targetRole'] ?? '').toString();
    if (targetRole == 'admin') return true;
    if (['DRIVER_ISSUE', 'RESIDENT_COMPLAINT', 'REGISTRATION', 'NEW_REGISTRATION', 'TRUCK_ISSUE'].contains(type)) {
      return true;
    }
    return false;
  }

  Future<void> _fetchComplaints() async {
    try {
      final response = await _apiService.getComplaints();
      if (response.data['success'] == true) {
        final List complaints = response.data['data'] ?? [];
        String normalize(dynamic s) {
          if (s == null) return 'PENDING';
          String str = s.toString().toLowerCase().trim();
          if (str == 'in_progress' || (str.contains('in') && str.contains('progress'))) return 'IN_PROGRESS';
          if (str == 'resolved' || str == 'completed') return 'RESOLVED';
          return 'PENDING';
        }
        if (mounted) {
          setState(() {
            _pendingComplaints = complaints.where((c) => normalize(c['status']) == 'PENDING').length;
            _inProgressComplaints = complaints.where((c) => normalize(c['status']) == 'IN_PROGRESS').length;
          });
        }
      }
    } catch (e) { debugPrint("Error fetching complaints: $e"); }
  }

  Future<bool> _showExitConfirmationDialog(BuildContext context) async {
    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          backgroundColor: Colors.white,
          title: const Row(
            children: [
              Icon(Icons.exit_to_app_rounded, color: Color(0xFF00796B), size: 28),
              SizedBox(width: 12),
              Text(
                "Exit Application?",
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A)),
              ),
            ],
          ),
          content: const Text(
            "Are you sure you want to exit the application? Your active session will remain saved.",
            style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500, height: 1.4),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00796B),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text(
                "Exit",
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
              ),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  /// Screens the Truck Buddy help bot can open.
  void _handleBotAction(BotAction action) {
    final int? target = switch (action) {
      BotAction.home => AdminDestinations.dashboard,
      BotAction.track => AdminDestinations.liveMap,
      BotAction.analytics => AdminDestinations.analytics,
      BotAction.complaints || BotAction.fileComplaint => AdminDestinations.incidents,
      BotAction.users => AdminDestinations.users,
      BotAction.settings => AdminDestinations.settings,
      BotAction.routeHistory => AdminDestinations.routeHistory,
      BotAction.routeAssignments => AdminDestinations.routeAssignments,
      BotAction.collectionStatus || BotAction.routePlan => AdminDestinations.collectionRouteOptimization,
      BotAction.signIn || BotAction.createAccount || BotAction.downloadApp => null, // public landing page only
    };
    if (target != null) setState(() => _selectedIndex = target);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobile = constraints.maxWidth < 600;
        bool isTablet = constraints.maxWidth >= 600 && constraints.maxWidth < 1024;
        bool isDesktop = constraints.maxWidth >= 1024;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, dynamic result) async {
            if (didPop) return;

            if (_selectedIndex > 0) {
              setState(() {
                _selectedIndex = _selectedIndex == AdminDestinations.routeHistory ? _routeReturn.backTarget : 0;
              });
              return;
            }

            final bool shouldExit = await _showExitConfirmationDialog(context);
            if (shouldExit) {
              SystemNavigator.pop();
            }
          },
          child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: const Color(0xFFF8F9FA),
            extendBody: true,
            drawer: (isMobile || isTablet) ? _buildMobileDrawer() : null,
            body: Row(
              children: [
                if (isDesktop) _buildSidebar(),
                Expanded(
                  child: Stack(children: [
                  Positioned.fill(child: IndexedStack(
                    index: _selectedIndex,
                    children: [
                      _buildMainDashboard(isMobile, isTablet),
                      TrackTrucksScreen(isEmbedded: true, onOpenRouteHistory: _openRouteHistory, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                      AnalyticsScreen(isEmbedded: true, onOpenRouteHistory: _openRouteHistory, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }, onNavigate: (index) => setState(() => _selectedIndex = index)),
                      ComplaintsScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                      UserManagementScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                      DataManagementScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                      AdminSettingsScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                      RouteHistoryScreen(key: ValueKey('route-history-$_routeHistoryEpoch'), isEmbedded: true, initialTripId: _routeHistoryTripId, initialTrip: _routeHistoryTrip, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = _routeReturn.backTarget); }),
                      // Built only when opened, so drivers/areas are not fetched on every dashboard load.
                      _selectedIndex == AdminDestinations.routeAssignments
                          ? RouteAssignmentsScreen(isEmbedded: true, onBack: () { if (mounted) setState(() => _selectedIndex = 0); })
                          : const SizedBox.shrink(),
                      // Built only when opened (its listeners end when the admin leaves it).
                      _selectedIndex == AdminDestinations.collectionRouteOptimization
                          ? CollectionRouteOptimizationScreen(role: 'admin', isEmbedded: true, onBack: () { if (mounted) setState(() => _selectedIndex = 0); })
                          : const SizedBox.shrink(),
                    ],
                  )),
                  // On every admin page; the admin can drag it out of the way.
                  TruckChatLauncher(
                    role: 'admin',
                    onAction: _handleBotAction,
                    right: isDesktop ? 28 : 16,
                    bottom: isDesktop ? 120 : 100 + MediaQuery.paddingOf(context).bottom,
                  ),
                  ]),
                ),
              ],
            ),
            bottomNavigationBar: (isMobile || isTablet) ? _buildBottomNav() : null,
          ),
        );
      },
    );
  }

  /// Shows Route History inside the dashboard content area (sidebar / bottom navigation
  /// stay in place). The section it was opened from is remembered for Back; every other
  /// section keeps its state because the IndexedStack is not rebuilt.
  void _openRouteHistory({String? tripId, DriverTrip? trip}) {
    if (!mounted) return;
    setState(() {
      _routeReturn.enter(_selectedIndex);
      _routeHistoryTripId = tripId;
      _routeHistoryTrip = trip;
      _routeHistoryEpoch++; // re-create the screen with the requested trip + fresh data
      _selectedIndex = AdminDestinations.routeHistory;
    });
  }

  /// Plain navigation to Route History (no trip): remembers where it came from.
  void _prepareRouteHistoryEntry() {
    _routeReturn.enter(_selectedIndex);
    _routeHistoryTripId = null;
    _routeHistoryTrip = null;
    _routeHistoryEpoch++;
  }

  Widget _buildSidebar() {
    return Container(
      width: 310,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(5, 0),
          )
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(decoration: AppDecorations.authBackground),
          ),
          AnimatedBuilder(
            animation: _circleController,
            builder: (context, child) {
              return Stack(
                children: [
                  _buildSidebarCircle(
                    size: 150,
                    color: const Color(0xFF80CBC4).withAlpha(30),
                    offset: Offset(math.sin(_circleController.value * 2 * math.pi) * 10, math.cos(_circleController.value * 2 * math.pi) * 20),
                    top: -40,
                    left: -40,
                    scale: 0.9 + math.sin(_circleController.value * math.pi) * 0.1
                  ),
                  _buildSidebarCircle(
                    size: 200,
                    color: const Color(0xFF4DB6AC).withAlpha(20),
                    offset: Offset(math.cos(_circleController.value * 2 * math.pi) * 15, math.sin(_circleController.value * 2 * math.pi) * 10),
                    bottom: 40,
                    right: -60,
                    scale: 0.95 + math.cos(_circleController.value * math.pi) * 0.05
                  ),
                ],
              );
            },
          ),
          Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(24, 60, 24, 40),
                child: Column(
                  children: [
                    Hero(
                      tag: 'admin_sidebar_logo',
                      child: Container(
                        width: 76, height: 76,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.loginButtonStart, AppColors.loginButtonEnd],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.loginButtonStart.withOpacity(0.3),
                              blurRadius: 15,
                              offset: const Offset(0, 8),
                            )
                          ],
                        ),
                        child: const Icon(Icons.admin_panel_settings_rounded, size: 36, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      AppLocalizations.get('garbage_tracker').toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: Color(0xFF00695C), letterSpacing: -0.5),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00695C).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        "ADMINISTRATOR",
                        style: TextStyle(fontSize: 9, color: Color(0xFF00695C), fontWeight: FontWeight.w900, letterSpacing: 1.2),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(indent: 32, endIndent: 32),
              const SizedBox(height: 24),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      // Daily operations first, then monitoring, administration, and Settings last. Database
                      // Center is reached from System Settings → Data Management, not the sidebar.
                      _buildSidebarItem(Icons.dashboard_rounded, "Dashboard Overview", 0),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.map_rounded, "Fleet GIS Tracking", 1),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.route_rounded, "Driver Route History", 7),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.assignment_ind_rounded, "Route Assignments", AdminDestinations.routeAssignments),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.alt_route_rounded, "Collection Route Optimization", AdminDestinations.collectionRouteOptimization),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.chat_bubble_rounded, "Complaint Management", 3),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.analytics_rounded, "System Analytics", 2),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.people_outline_rounded, "User Management", 4),
                      const SizedBox(height: 8),
                      _buildSidebarItem(Icons.settings_suggest_rounded, "System Settings", 6),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: _HoverZoomCard(
                  onTap: () => _showLogoutDialog(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.redAccent.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))
                      ],
                      border: Border.all(color: Colors.redAccent.withOpacity(0.2)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.power_settings_new_rounded, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 12),
                        Text("LOGOUT", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 1)),
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

  Widget _buildSidebarCircle({required double size, required Color color, required Offset offset, double? top, double? left, double? bottom, double? right, required double scale}) {
    return Positioned(
      top: top, left: left, bottom: bottom, right: right,
      child: Transform.translate(
        offset: offset,
        child: Transform.scale(
          scale: scale,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarItem(IconData icon, String label, int index) {
    final bool isSelected = _selectedIndex == index;
    return _HoverZoomCard(
      onTap: () {
        if (index == 0) _refreshAllStats();
        setState(() {
          if (index == AdminDestinations.routeHistory) _prepareRouteHistoryEntry();
          _selectedIndex = index;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00796B).withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade600,
              size: 20
            ),
            if (_isSidebarExtended) ...[
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade700,
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (isSelected && _isSidebarExtended)
              Container(
                width: 4, height: 16,
                decoration: BoxDecoration(color: const Color(0xFF00796B), borderRadius: BorderRadius.circular(2)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileDrawer() {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double drawerWidth = (screenWidth * 0.8).clamp(280.0, 320.0);

    return Drawer(
      width: drawerWidth,
      backgroundColor: Colors.white,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(decoration: AppDecorations.authBackground),
          ),
          AnimatedBuilder(
            animation: _circleController,
            builder: (context, child) {
              return Stack(
                children: [
                  _buildSidebarCircle(
                    size: 150,
                    color: const Color(0xFF80CBC4).withAlpha(30),
                    offset: Offset(math.sin(_circleController.value * 2 * math.pi) * 10, math.cos(_circleController.value * 2 * math.pi) * 20),
                    top: -30,
                    left: -30,
                    scale: 0.9 + math.sin(_circleController.value * math.pi) * 0.1
                  ),
                  _buildSidebarCircle(
                    size: 180,
                    color: const Color(0xFF4DB6AC).withAlpha(15),
                    offset: Offset(math.cos(_circleController.value * 2 * math.pi) * 15, math.sin(_circleController.value * 2 * math.pi) * 10),
                    bottom: -40,
                    right: -40,
                    scale: 0.95 + math.cos(_circleController.value * math.pi) * 0.05
                  ),
                ],
              );
            },
          ),
          SafeArea(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 30),
                  child: Column(
                    children: [
                      Hero(
                        tag: 'admin_drawer_logo',
                        child: Container(
                          width: 76, height: 76,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [AppColors.loginButtonStart, AppColors.loginButtonEnd],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.loginButtonStart.withOpacity(0.3),
                                blurRadius: 15,
                                offset: const Offset(0, 8),
                              )
                            ],
                          ),
                          child: const Icon(Icons.admin_panel_settings_rounded, size: 36, color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.get('garbage_tracker').toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 19, color: Color(0xFF1A1A1A), letterSpacing: -0.5),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00695C).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          "SYSTEM ADMINISTRATOR",
                          style: TextStyle(fontSize: 9, color: Color(0xFF00695C), fontWeight: FontWeight.w900, letterSpacing: 1.1),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(indent: 32, endIndent: 32, height: 1),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _buildDrawerItem(Icons.route_rounded, "Route History", 7),
                      _buildDrawerItem(Icons.assignment_ind_rounded, "Route Assignments", AdminDestinations.routeAssignments),
                      _buildDrawerItem(Icons.alt_route_rounded, "Collection Route Optimization", AdminDestinations.collectionRouteOptimization),
                      _buildDrawerItem(Icons.chat_bubble_rounded, "Complaint Management", 3),
                      _buildDrawerItem(Icons.people_outline_rounded, "User Accounts", 4),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: _HoverZoomCard(
                    onTap: () {
                      _scaffoldKey.currentState?.closeDrawer();
                      _showLogoutDialog(context);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.red.shade400, Colors.red.shade700],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(color: Colors.red.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6))
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.power_settings_new_rounded, color: Colors.white, size: 20),
                          const SizedBox(width: 12),
                          const Text("LOGOUT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 1)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerItem(IconData icon, String label, int index) {
    bool isSelected = _selectedIndex == index;
    return ListTile(
      onTap: () {
        // Closes only the drawer: a second tap must never pop the dashboard itself
        // (that would leave the admin on the public page).
        _scaffoldKey.currentState?.closeDrawer();
        if (index == 0) _refreshAllStats();
        setState(() {
          if (index == AdminDestinations.routeHistory) _prepareRouteHistoryEntry();
          _selectedIndex = index;
        });
      },
      leading: Icon(icon, color: isSelected ? const Color(0xFF00695C) : Colors.grey.shade600, size: 22),
      title: Text(
        label,
        style: TextStyle(
          color: isSelected ? const Color(0xFF00695C) : Colors.grey.shade700,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      selected: isSelected,
      selectedTileColor: const Color(0xFF00695C).withOpacity(0.08),
    );
  }

  Widget _buildMainDashboard(bool isMobile, bool isTablet) {
    if (isMobile || isTablet) {
      return LayoutBuilder(builder: (context, constraints) {
        return Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          body: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (ScrollNotification scroll) {
                  // Detect user release by checking for ScrollUpdate with no drag details
                  // or the end of the scroll activity.
                  bool isRelease = (scroll is ScrollUpdateNotification && scroll.dragDetails == null) || 
                                  (scroll is ScrollEndNotification);

                  if (isRelease && !_isRefreshing) {
                    if (_scrollController.hasClients && _scrollController.offset < -70) {
                      _refreshAllStats(manual: true);
                    }
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  child: AnimatedBuilder(
                    animation: _scrollController,
                    builder: (context, child) {
                      final double offset = _scrollController.hasClients ? _scrollController.offset : 0;
                      // Counter the pull-down bounce so header/content stay fixed visually during pull
                      // We use offset directly (which is negative during pull) to move content up
                      return Transform.translate(
                        offset: Offset(0, offset < 0 ? offset : 0),
                        child: Column(
                          children: [
                            _buildHeader(constraints.maxWidth),
                            Center(
                              child: Container(
                                constraints: const BoxConstraints(maxWidth: 1200),
                                padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 6),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text("Overview",
                                            style: TextStyle(
                                                fontSize: isMobile ? 22 : 26,
                                                fontWeight: FontWeight.w900,
                                                color: const Color(0xFF1A1A1A),
                                                letterSpacing: -0.5)),
                                        Text("System-wide Activity",
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.grey.shade600)),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    _buildStatGrid(isMobile, isTablet),
                                    const SizedBox(height: 16),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text("Fleet GIS",
                                            style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w900,
                                                color: const Color(0xFF1A1A1A))),
                                        Text("Real-time truck locations and status",
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.grey.shade600)),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    _buildMapWidget(true),
                                    const SizedBox(height: 16),
                                    _buildFleetSection(),
                                    const SizedBox(height: 16),
                                    _buildActivityLogSection(),
                                    const SizedBox(height: 12),
                                    _buildAdminActionsGrid(true),
                                    const SizedBox(height: 120),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Custom Pull-to-Refresh Spinner (Sticky while refreshing)
              AnimatedBuilder(
                animation: Listenable.merge([_scrollController, _refreshRotationController]),
                builder: (context, child) {
                  final double offset = _scrollController.hasClients ? _scrollController.offset : 0;
                  
                  // Logic to show spinner: 
                  // 1. If actively pulling down (offset < 0)
                  // 2. If currently performing a manual refresh or retreating (_showRefreshSpinner)
                  bool shouldShow = (offset < 0) || _showRefreshSpinner;
                  
                  if (!shouldShow) {
                    return const SizedBox.shrink();
                  }

                  final double pullDistance = offset.abs();
                  
                  // If refreshing, stick at 80. 
                  // If just pulling or retreating, follow the pull logic (up to 80 or back to -40).
                  final double targetTop = (_isRefreshing && _showRefreshSpinner)
                      ? 80.0 
                      : (-40 + pullDistance).clamp(-40.0, 80.0);
                  
                  final double opacity = (_isRefreshing && _showRefreshSpinner)
                      ? 1.0 
                      : (pullDistance / 60).clamp(0.0, 1.0);

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
                            // Interactive rotation: rotates as you pull (clockwise) or push back (counter-clockwise)
                            angle: (_isRefreshing && _showRefreshSpinner)
                                ? 0 
                                : (pullDistance / 80) * 2 * math.pi,
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
      });
    }

    return Column(
      children: [
        _buildWebHeader(),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.zero,
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            child: Center(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  _buildWebBanner(),
                  const SizedBox(height: 32),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      const SizedBox(height: 10),
                      _buildStatGrid(isMobile, isTablet),
                      const SizedBox(height: 16),
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                            flex: 2,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("Fleet GIS",
                                      style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF1A1A1A))),
                                  Text("Real-time truck locations and status",
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.grey.shade600)),
                                  const SizedBox(height: 12),
                                  _buildMapWidget(false),
                                  const SizedBox(height: 20),
                                  _buildAdminActionsGrid(false)
                                ])),
                        const SizedBox(width: 20),
                        Expanded(
                            flex: 1,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildActivityLogSection(),
                                  const SizedBox(height: 20),
                                  _buildFleetSection()
                                  ])),
                        ]),
                        const SizedBox(height: 110),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }


  Widget _buildHeader(double width) {
    final double screenHeight = MediaQuery.of(context).size.height;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double topSafeArea = MediaQuery.of(context).padding.top;

    bool isMobile = width < 600;
    bool isTablet = width >= 600 && width < 1024;

    final double buttonSize = isMobile ? 38.0 : (isTablet ? 42.0 : 48.0);
    final double iconSize = isMobile ? 20.0 : (isTablet ? 22.0 : 24.0);
    final double clockFontSize = isMobile ? 11.5 : (isTablet ? 12.5 : 13.5);
    final double clockPaddingH = isMobile ? 10.0 : (isTablet ? 12.0 : 16.0);

    final double welcomeFontSize = isMobile ? 11.0 : (isTablet ? 12.0 : 13.0);
    final double nameFontSize = isMobile ? 15.0 : (isTablet ? 17.0 : 19.0);

    final double avatarSize = isMobile ? 44.0 : (isTablet ? 52.0 : 60.0);
    final double avatarFontSize = isMobile ? 18.0 : (isTablet ? 20.0 : 22.0);

    final double headerPaddingH = isMobile ? 12.0 : (isTablet ? 18.0 : 24.0);
    final double headerPaddingT = isMobile ? 10.0 : (isTablet ? 12.0 : 16.0);

    // Dynamic calculation of the controls' bottom boundary
    final double controlsBottom = topSafeArea + headerPaddingT + buttonSize;

    // Clear, intentional vertical gap between controls and the overlay card
    final double verticalGap = isMobile ? 16.0 : (isTablet ? 20.0 : 24.0);

    // Overlay card top position is dynamically set below the controls with a visible gap
    final double cardTopOffset = controlsBottom + verticalGap;

    // Green background height extends gracefully past the overlay card's top edge
    final double bgHeight = cardTopOffset + (isMobile ? 36.0 : (isTablet ? 42.0 : 50.0));

    final double cardPaddingH = isMobile ? 14.0 : (isTablet ? 18.0 : 20.0);
    final double cardPaddingV = isMobile ? 12.0 : (isTablet ? 16.0 : 18.0);
    final double innerSpacing = isMobile ? 10.0 : (isTablet ? 12.0 : 16.0);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 1. Green "Satin" Background
        Container(
          width: double.infinity,
          height: bgHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF00695C),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(isMobile ? 18 : 24)),
          ),
          child: Stack(
            children: [
              AnimatedBuilder(
                animation: _circleController,
                builder: (context, child) {
                  return CustomPaint(
                    size: Size(double.infinity, bgHeight),
                    painter: HeaderCirclePainter(_circleController.value),
                  );
                },
              ),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(headerPaddingH, headerPaddingT, headerPaddingH, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          _HoverZoomCard(
                            onTap: () => _scaffoldKey.currentState?.openDrawer(),
                            scale: 1.05,
                            child: Container(
                              width: buttonSize,
                              height: buttonSize,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(isMobile ? 10 : 14),
                              ),
                              child: Icon(Icons.menu_rounded, color: Colors.white, size: iconSize),
                            ),
                          ),
                          SizedBox(width: isMobile ? 6 : 8),
                          _HoverZoomCard(
                            scale: 1.05,
                            child: Container(
                              height: buttonSize,
                              padding: EdgeInsets.symmetric(horizontal: clockPaddingH),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(isMobile ? 10 : 14),
                              ),
                              child: Center(
                                child: Text(
                                  _currentTime,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: clockFontSize,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    letterSpacing: isMobile ? 0.8 : 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          _buildHeaderActionIcon(
                            Icons.notifications_outlined,
                            badgeCount: _unreadNotificationsCount > 0 ? _unreadNotificationsCount : null,
                            onTap: () => _showNotificationsModal(context),
                            size: buttonSize,
                            iconSize: iconSize,
                          ),
                          SizedBox(width: isMobile ? 6 : 8),
                          _buildHeaderActionIcon(
                            Icons.logout_rounded,
                            onTap: () => _showLogoutDialog(context),
                            size: buttonSize,
                            iconSize: iconSize,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 2. Overlapping White Card
        Padding(
          padding: EdgeInsets.only(top: cardTopOffset, left: 16, right: 16),
          child: Container(
            padding: EdgeInsets.fromLTRB(cardPaddingH, cardPaddingV, cardPaddingH, cardPaddingV),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(isMobile ? 20 : 28),
              boxShadow: AppTheme.balancedPulidongShadow,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Restored Profile Picture Container
                    GestureDetector(
                      onTap: _viewProfilePicture,
                      child: Hero(
                        tag: 'admin_profile_pic_header',
                        child: Container(
                          width: avatarSize,
                          height: avatarSize,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF00695C), width: 2),
                            image: (_user?.profilePicture != null && _user!.profilePicture!.isNotEmpty)
                                ? DecorationImage(
                                    image: NetworkImage(_user!.profilePicture!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: (_user?.profilePicture == null || _user!.profilePicture!.isEmpty)
                              ? Center(
                                  child: Text(
                                    (_user?.name != null && _user!.name.isNotEmpty) ? _user!.name[0].toUpperCase() : "A",
                                    style: TextStyle(
                                      fontSize: avatarFontSize,
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF00695C),
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    SizedBox(width: isMobile ? 10 : 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text("Administrator", style: TextStyle(color: Colors.grey.shade600, fontSize: welcomeFontSize, fontWeight: FontWeight.w600)),
                          Text(
                            _user?.name ?? "System Admin",
                            style: TextStyle(color: const Color(0xFF1A1A1A), fontSize: nameFontSize, fontWeight: FontWeight.w900, letterSpacing: -0.5),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    // Plain Edit Text Button on the right
                    TextButton(
                      onPressed: () => _showDataManagementModal(context),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: isMobile ? 8 : 12,
                          vertical: isMobile ? 4 : 8,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        overlayColor: Colors.transparent,
                      ),
                      child: Text(
                        "Edit",
                        style: TextStyle(
                          color: const Color(0xFF00695C),
                          fontWeight: FontWeight.w900,
                          fontSize: isMobile ? 12.5 : 14.0,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: innerSpacing),
                HoverActionButton(
                  text: "Track Fleet GIS",
                  height: isMobile ? 42.0 : (isTablet ? 46.0 : 52.0),
                  onTap: () => setState(() => _selectedIndex = 1),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderActionIcon(IconData icon, {int? badgeCount, VoidCallback? onTap, double? size, double? iconSize}) {
    final double boxSize = size ?? 48.0;
    final double icSize = iconSize ?? 24.0;
    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.05,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: boxSize,
            height: boxSize,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(boxSize < 44 ? 10 : 14),
            ),
            child: Icon(icon, color: Colors.white, size: icSize),
          ),
          if (badgeCount != null)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Color(0xFFFF5252),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  "$badgeCount",
                  style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWebHeader() {
    final String? profileUrl = (_user?.profilePicture != null && _user!.profilePicture!.isNotEmpty) ? _user!.profilePicture : null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _viewProfilePicture,
                child: Hero(
                  tag: 'web_profile_pic',
                  child: Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: AppTheme.balancedPulidongShadow,
                      border: Border.all(color: const Color(0xFF00796B), width: 2.5),
                      image: profileUrl != null
                          ? DecorationImage(image: NetworkImage(profileUrl), fit: BoxFit.cover)
                          : null,
                    ),
                    child: profileUrl == null
                        ? Center(child: Text((_user?.name ?? "A")[0].toUpperCase(), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF00796B))))
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Welcome back,", style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        _user?.name ?? "Administrator",
                        style: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -1),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: AppTheme.balancedPulidongShadow,
                  border: Border.all(color: Colors.grey.shade100),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.access_time_filled_rounded, color: Color(0xFF00796B), size: 18),
                    const SizedBox(width: 12),
                    Text(_currentTime, style: const TextStyle(color: Color(0xFF00796B), fontSize: 16, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              _buildWebHeaderActionIcon(Icons.notifications_outlined, badgeCount: _unreadNotificationsCount > 0 ? _unreadNotificationsCount : null, onTap: () => _showNotificationsModal(context)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWebHeaderActionIcon(IconData icon, {int? badgeCount, VoidCallback? onTap}) {
    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.1,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF00796B).withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF00796B).withOpacity(0.1)),
          ),
          child: const Icon(Icons.notifications_outlined, color: Color(0xFF00796B), size: 24),
        ),
        if (badgeCount != null)
          Positioned(
            right: -2, top: -2,
            child: Container(padding: const EdgeInsets.all(5), decoration: const BoxDecoration(color: Color(0xFFFF4081), shape: BoxShape.circle), child: Text("$badgeCount", style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900))),
          ),
      ]),
    );
  }

  Widget _buildWebBanner() {
    return Container(
      width: double.infinity,
      height: 120,
      margin: const EdgeInsets.symmetric(horizontal: 40),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF00695C), Color(0xFF004D40)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTheme.balancedDeepShadow,
      ),
      child: Stack(
        clipBehavior: Clip.antiAlias,
        children: [
          AnimatedBuilder(
            animation: _circleController,
            builder: (context, child) {
              return Stack(
                children: [
                  _buildSidebarCircle(
                    size: 100,
                    color: Colors.white.withOpacity(0.1),
                    offset: Offset(math.sin(_circleController.value * 2 * math.pi) * 20, math.cos(_circleController.value * 2 * math.pi) * 30),
                    top: -20,
                    right: 150,
                    scale: 1.0 + math.sin(_circleController.value * math.pi) * 0.2
                  ),
                  _buildSidebarCircle(
                    size: 140,
                    color: Colors.white.withOpacity(0.05),
                    offset: Offset(math.cos(_circleController.value * 2 * math.pi) * 30, math.sin(_circleController.value * 2 * math.pi) * 20),
                    bottom: -30,
                    left: 200,
                    scale: 1.1 + math.cos(_circleController.value * math.pi) * 0.1
                  ),
                ],
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.dashboard_customize_rounded, color: Colors.white, size: 32),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Administrative Overview & System Impact",
                        style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Monitor real-time fleet activity, manage users, and analyze system-wide collection performance.",
                        style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                _HoverZoomCard(
                  onTap: () => setState(() => _selectedIndex = 1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))
                      ],
                    ),
                    child: const Text(
                      "Open Map", 
                      style: TextStyle(color: Color(0xFF00695C), fontWeight: FontWeight.w900, fontSize: 14)
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDataManagementModal(BuildContext context) {
    if (_user == null) return;
    bool isModalLoading = true;
    _showStyledBottomSheet(
      context: context,
      title: "Edit Account",
      description: "Update your administrative contact details and credentials.",
      maxHeightMultiplier: 0.9,
      children: [
        StatefulBuilder(builder: (ctx, setModalState) {
          if (isModalLoading) {
            Future.delayed(const Duration(milliseconds: 800), () {
              if (mounted) setModalState(() => isModalLoading = false);
            });
            return const Center(child: Padding(padding: EdgeInsets.all(60), child: CircularProgressIndicator(color: AppColors.tealText)));
          }
          return DataManagementModal(user: _user!, onSuccess: _loadUser);
        }),
      ],
    );
  }

  void _showStyledBottomSheet({required BuildContext context, required String title, required List<Widget> children, String? description, double maxHeightMultiplier = 0.6}) {
    final bool isDesktop = Responsive.isDesktop(context);
    final double screenWidth = MediaQuery.of(context).size.width;
    final double screenHeight = MediaQuery.of(context).size.height;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isDesktop ? 550 : (screenWidth * 0.92).clamp(320.0, 520.0),
            maxHeight: (screenHeight * maxHeightMultiplier).clamp(350.0, 700.0),
          ),
          child: Container(
            padding: EdgeInsets.all(isDesktop ? 32 : 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(title, style: TextStyle(fontSize: isDesktop ? 22 : 18, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                  ],
                ),
                if (description != null && description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(description, style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                ],
                const Divider(height: 24),
                Flexible(
                  child: SingleChildScrollView(
                    clipBehavior: Clip.antiAlias,
                    child: Column(mainAxisSize: MainAxisSize.min, children: children),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _viewProfilePicture() {
    if (_user == null) return;
    final String profileUrl = (_user!.profilePicture != null && _user!.profilePicture!.isNotEmpty) ? _user!.profilePicture! : "";
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "ProfilePicture",
      barrierColor: Colors.black.withOpacity(0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                GestureDetector(onTap: () => Navigator.pop(context), child: Container(color: Colors.transparent)),
                Center(
                  child: Hero(
                    tag: 'admin_profile_pic_header',
                    child: Container(
                      width: 300, height: 300,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                        image: profileUrl.isNotEmpty ? DecorationImage(image: NetworkImage(profileUrl), fit: BoxFit.cover) : null,
                      ),
                      child: profileUrl.isEmpty
                          ? Center(child: Text(_user!.name.isNotEmpty ? _user!.name[0].toUpperCase() : "A", style: const TextStyle(fontSize: 80, fontWeight: FontWeight.bold, color: Colors.white)))
                          : null,
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white, size: 32), onPressed: () => Navigator.pop(context)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatGrid(bool isMobile, bool isTablet) {
    final double aspectRatio = isMobile
        ? 1.50
        : (isTablet ? 1.80 : 2.10);
    return GridView.count(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: (isMobile || isTablet) ? 2 : 4,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: aspectRatio,
      children: [
        _buildModernStatCard("Online Drivers", "$_onlineDriversCount",
            Icons.person_pin_circle_rounded, const Color(0xFF43A047)),
        _buildModernStatCard("Pending Issues", "$_pendingComplaints",
            Icons.warning_amber_rounded, const Color(0xFFE53935)),
        _buildModernStatCard("Route Coverage", "${_coveragePercent.round()}%",
            Icons.map_rounded, const Color(0xFFFB8C00),
            badge: _coverageAreas == 0 ? null : "$_coverageVisited/$_coverageAreas areas, 7 days"),
        _buildModernStatCard("Total Residents", "$_residentsCount",
            Icons.people_alt_rounded, const Color(0xFF8E24AA)),
      ],
    );
  }

  Future<void> _updateRouteCoverage() async {
    if (_coverageGeofences == null) {
      final List<AreaGeofence> list = <AreaGeofence>[];
      try {
        final DataSnapshot snap = await _database.ref('puroks').get().timeout(const Duration(seconds: 10));
        if (snap.value is Map) {
          (snap.value as Map).forEach((k, v) {
            if (v is! Map) return;
            try {
              final Map<String, dynamic> m = Map<String, dynamic>.from(v);
              m['id'] ??= k.toString();
              final ServiceArea a = ServiceArea.fromJson(m);
              list.add(AreaGeofence(
                name: ServiceAreaService.canonicalizeAreaName(a.name) ?? a.name,
                lat: a.entranceLat,
                lng: a.entranceLng,
                radiusM: AreaGeofence.areaRadiusM,
                isTruckStop: a.isTruckStop && a.verificationStatus.toUpperCase() == 'VERIFIED',
              ));
            } catch (_) {}
          });
        }
      } catch (e) {
        debugPrint('[DASHBOARD] service areas could not be read: $e');
      }
      _coverageGeofences = list;
    }
    final List<AreaGeofence> areas = _coverageGeofences!;
    final Set<String> stops = areas.where((AreaGeofence g) => g.isTruckStop).map((AreaGeofence g) => g.name).toSet();
    if (stops.isEmpty) return;
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final VisitSummary v = CollectionVisits.detect(
      trips: _coverageTrips,
      areas: areas,
      start: today.subtract(const Duration(days: 6)),
      end: today,
    );
    final Map<String, int> counts = v.countByArea();
    final int visited = stops.where((String a) => (counts[a] ?? 0) > 0).length;
    if (!mounted) return;
    setState(() {
      _coverageVisited = visited;
      _coverageAreas = stops.length;
      _coveragePercent = visited * 100.0 / stops.length;
    });
  }

  Widget _buildModernStatCard(String title, String value, IconData icon,
      Color color, {String? badge}) {
    final bool isDesktop = Responsive.isDesktop(context);
    final Color bgColor = color.withOpacity(0.02);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(isDesktop ? 18 : 14),
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double cardWidth = constraints.maxWidth;
          final double cardHeight = constraints.maxHeight;

          final double cardPadding = (cardHeight * 0.09).clamp(8.0, 14.0);
          final double iconBoxSize = (cardHeight * 0.28).clamp(26.0, 40.0);
          final double iconSize = iconBoxSize * 0.55;
          final double valueFontSize = (cardHeight * 0.22).clamp(15.0, 25.0);
          final double titleFontSize = (cardHeight * 0.11).clamp(10.0, 12.5);

          return Stack(
            children: [
              Positioned(
                top: -cardHeight * 0.15,
                right: -cardWidth * 0.1,
                child: Container(
                  width: cardHeight * 0.6,
                  height: cardHeight * 0.6,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.05),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                bottom: -cardHeight * 0.1,
                right: -cardWidth * 0.05,
                child: Icon(
                  icon,
                  size: cardHeight * 0.5,
                  color: color.withOpacity(0.05),
                ),
              ),
              if (badge != null)
                Positioned(
                  top: cardPadding,
                  right: cardPadding,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: (cardWidth * 0.04).clamp(4.0, 8.0),
                      vertical: (cardHeight * 0.03).clamp(2.0, 4.0),
                    ),
                    decoration: BoxDecoration(
                      color: color.withAlpha(40),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: color.withAlpha(60), width: 1),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: (cardHeight * 0.09).clamp(9.0, 12.0),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.all(cardPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: iconBoxSize,
                      height: iconBoxSize,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(iconBoxSize * 0.3),
                      ),
                      child: Icon(icon, color: color, size: iconSize),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: FittedBox(
                        alignment: Alignment.centerLeft,
                        fit: BoxFit.scaleDown,
                        child: Text(
                          value,
                          style: TextStyle(
                            fontSize: valueFontSize,
                            fontWeight: FontWeight.w900,
                            color: const Color(0xFF1A1A1A),
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: (cardHeight * 0.02).clamp(1.0, 4.0)),
                    SizedBox(
                      width: double.infinity,
                      child: FittedBox(
                        alignment: Alignment.centerLeft,
                        fit: BoxFit.scaleDown,
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMapWidget(bool isMobile) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: AppTheme.balancedPulidongShadow,
          border: Border.all(color: Colors.white, width: 2)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                            color: Color(0xFF00C853), shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: FittedBox(
                        alignment: Alignment.centerLeft,
                        fit: BoxFit.scaleDown,
                        child: Text("Live Fleet Monitoring",
                            style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF1A1A1A),
                                fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _HoverZoomLink(
                onTap: () => setState(() => _selectedIndex = 1),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                      color: const Color(0xFFE0F2F1),
                      borderRadius: BorderRadius.circular(12)),
                  child: const Text("Full Map",
                      style: TextStyle(
                          color: Color(0xFF00796B),
                          fontWeight: FontWeight.w900,
                          fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
        Container(
            height: isMobile ? 220 : 400,
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xFFF8F9FA),
                border: Border.all(color: Colors.grey.shade200)),
            child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: const MapboxView(
                    mode: 'dashboard'))),
      ]),
    );
  }

  Widget _buildActivityLogSection() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    final bool isTablet = MediaQuery.of(context).size.width >= 600 && MediaQuery.of(context).size.width < 1024;
    final EdgeInsets containerPadding = EdgeInsets.symmetric(
      horizontal: isMobile ? 16 : (isTablet ? 18 : 22),
      vertical: isMobile ? 14 : (isTablet ? 16 : 20),
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(isMobile ? 20 : 28), 
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.white, width: 2)
      ),
      padding: containerPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Recent Activity", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
        SizedBox(height: isMobile ? 10 : 16),
        if (_recentLogs.isEmpty) const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text("No recent activity logs", style: TextStyle(color: Colors.grey, fontSize: 13))))
        else ...[
          Column(children: _recentLogs.take(2).map((log) => _buildRecentActivityItem(log)).toList()),
          SizedBox(height: isMobile ? 4 : 8),
          if (_recentLogs.length > 2)
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => _showAllActivityLogs(),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF00796B),
                  overlayColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text("VIEW ALL ACTIVITY", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1, fontSize: 11.5))
              ),
            ),
        ],
      ]),
    );
  }

  void _showAllActivityLogs() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    bool isModalLoading = true;

    Widget modalContent(StateSetter setModalState) {
      if (isModalLoading) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) setModalState(() => isModalLoading = false);
        });
      }

      return Container(
        padding: EdgeInsets.fromLTRB(24, isMobile ? 12 : 24, 24, 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: isMobile ? const BorderRadius.vertical(top: Radius.circular(32)) : BorderRadius.circular(32),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMobile) 
              Center(
                child: Container(
                  width: 40, 
                  height: 4, 
                  margin: const EdgeInsets.only(bottom: 20), 
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))
                )
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("System Activity Log", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                      SizedBox(height: 4),
                      Text("Complete history of system events and actions.", style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 20),
            if (isModalLoading)
              const Padding(
                padding: EdgeInsets.all(60),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.tealText),
                      SizedBox(height: 16),
                      Text(
                        "Loading system logs...",
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 32),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _recentLogs.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final log = _recentLogs[index];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200, width: 1.2),
                        ),
                        child: _buildRecentActivityItemRow(log),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      );
    }

    final bool isDesktop = Responsive.isDesktop(context);

    if (!isDesktop) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) => Container(
            clipBehavior: Clip.antiAlias,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.72,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: modalContent(setModalState),
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 680),
            child: StatefulBuilder(
              builder: (context, setModalState) => modalContent(setModalState),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildRecentActivityItemRow(Map<dynamic, dynamic> log) {
    final String type = (log['type'] ?? 'OTHER').toString().toUpperCase();
    final String message = (log['message'] ?? "System Event").toString();
    final String date = (log['date'] ?? "Just now").toString();
    IconData icon = Icons.info_outline_rounded; Color color = Colors.grey;
    switch (type) {
      case 'LOGIN': icon = Icons.login_rounded; color = const Color(0xFF4CAF50); break;
      case 'LOGOUT': icon = Icons.logout_rounded; color = const Color(0xFFF44336); break;
      case 'EXPORT': icon = Icons.download_rounded; color = const Color(0xFF2196F3); break;
      case 'UPDATE': icon = Icons.settings_rounded; color = const Color(0xFFFF9800); break;
    }
    return Row(children: [
      Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color.withAlpha(20), shape: BoxShape.circle), child: Icon(icon, color: color, size: 14)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(message, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50)), maxLines: 1, overflow: TextOverflow.ellipsis), Text(date, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500))])),
    ]);
  }

  Widget _buildRecentActivityItem(Map<dynamic, dynamic> log) {
    final String type = (log['type'] ?? 'OTHER').toString().toUpperCase();
    final String message = (log['message'] ?? "System Event").toString();
    final String date = (log['date'] ?? "Just now").toString();
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    IconData icon = Icons.info_outline_rounded; Color color = Colors.grey;
    switch (type) {
      case 'LOGIN': icon = Icons.login_rounded; color = const Color(0xFF4CAF50); break;
      case 'LOGOUT': icon = Icons.logout_rounded; color = const Color(0xFFF44336); break;
      case 'EXPORT': icon = Icons.download_rounded; color = const Color(0xFF2196F3); break;
      case 'UPDATE': icon = Icons.settings_rounded; color = const Color(0xFFFF9800); break;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 14, vertical: isMobile ? 8 : 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200, width: 1),
      ),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: color.withAlpha(20), shape: BoxShape.circle), child: Icon(icon, color: color, size: 14)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(message, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50)), maxLines: 1, overflow: TextOverflow.ellipsis), Text(date, style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.w500))])),
      ]),
    );
  }

  Widget _buildFleetSection() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    final bool isTablet = MediaQuery.of(context).size.width >= 600 && MediaQuery.of(context).size.width < 1024;
    final EdgeInsets containerPadding = EdgeInsets.symmetric(
      horizontal: isMobile ? 16 : (isTablet ? 18 : 22),
      vertical: isMobile ? 14 : (isTablet ? 16 : 20),
    );

    final onlineTrucks = _fleetStatus.where((t) => t['isOnline'] == true).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(isMobile ? 20 : 28), 
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.white, width: 2)
      ),
      padding: containerPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Fleet Overview", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
        SizedBox(height: isMobile ? 10 : 16),
        if (_isScanningFleet && onlineTrucks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Color(0xFF00796B),
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Scanning for active unit...",
                    style: TextStyle(color: Colors.grey, fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          )
        else if (onlineTrucks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                "No online active truck",
                style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          )
        else ...[
          Column(children: onlineTrucks.take(2).map((truck) => _buildModernFleetItem(truck)).toList()),
          SizedBox(height: isMobile ? 4 : 8),
          if (onlineTrucks.length > 2)
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => _showAllFleetStatus(),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF00796B),
                  overlayColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text("VIEW ALL FLEET STATUS", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1, fontSize: 11.5))
              ),
            ),
        ],
      ]),
    );
  }

  void _showAllFleetStatus() {
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    bool isModalLoading = true;

    Widget modalContent(StateSetter setModalState) {
      if (isModalLoading) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) setModalState(() => isModalLoading = false);
        });
      }

      final List<Map<dynamic, dynamic>> onlineTrucks = _fleetStatus.where((t) => t['isOnline'] == true).toList();
      
      return Container(
        padding: EdgeInsets.fromLTRB(24, isMobile ? 12 : 24, 24, 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: isMobile ? const BorderRadius.vertical(top: Radius.circular(32)) : BorderRadius.circular(32),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMobile) 
              Center(
                child: Container(
                  width: 40, 
                  height: 4, 
                  margin: const EdgeInsets.only(bottom: 20), 
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))
                )
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Full Fleet Status", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                      SizedBox(height: 4),
                      Text("Real-time detailed telemetry for all online units.", style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 20),
            if (isModalLoading)
              const Padding(
                padding: EdgeInsets.all(60),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.tealText),
                      SizedBox(height: 16),
                      Text(
                        "Loading fleet status...",
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 32),
                  child: onlineTrucks.isEmpty 
                      ? const Padding(padding: EdgeInsets.all(40), child: Center(child: Text("No trucks are currently online.")))
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: onlineTrucks.length,
                          separatorBuilder: (context, i) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final truck = onlineTrucks[index];
                            return _buildModernFleetItem(truck);
                          },
                        ),
                ),
              ),
          ],
        ),
      );
    }

    final bool isDesktop = Responsive.isDesktop(context);

    if (!isDesktop) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) => Container(
            clipBehavior: Clip.antiAlias,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.72,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: modalContent(setModalState),
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 680),
            child: StatefulBuilder(
              builder: (context, setModalState) => modalContent(setModalState),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildModernFleetItem(Map<dynamic, dynamic> truck) {
    return _buildOrganizedTruckCard(truck);
  }
  Color _getFleetStatusColor(String status) {
    switch (status.toUpperCase()) {
      case 'IDLE':
        return const Color(0xFFED6C02);
      case 'ACTIVE':
      case 'COLLECTING':
      case 'MOVING':
      case 'EN_ROUTE':
      case 'IN_PROGRESS':
        return const Color(0xFF00796B);
      case 'FULL':
      case 'TRUCK_FULL':
      case 'CAPACITY_FULL':
        return const Color(0xFF0288D1);
      case 'PAUSED':
      case 'INTERRUPTED':
      case 'ON_HOLD':
      case 'STOPPED':
        return const Color(0xFFD84315);
      case 'COMPLETED':
      case 'FINISHED':
        return const Color(0xFF2E7D32);
      case 'MAINTENANCE':
      case 'ISSUE':
      case 'BREAKDOWN':
        return const Color(0xFFC62828);
      case 'DELAYED':
        return const Color(0xFFF57F17);
      case 'OFFLINE':
      default:
        return const Color(0xFF616161);
    }
  }

  Color _getFleetStatusBgColor(String status) {
    switch (status.toUpperCase()) {
      case 'IDLE':
        return const Color(0xFFFFF3E0);
      case 'ACTIVE':
      case 'COLLECTING':
      case 'MOVING':
      case 'EN_ROUTE':
      case 'IN_PROGRESS':
        return const Color(0xFFE0F2F1);
      case 'FULL':
      case 'TRUCK_FULL':
      case 'CAPACITY_FULL':
        return const Color(0xFFE1F5FE);
      case 'PAUSED':
      case 'INTERRUPTED':
      case 'ON_HOLD':
      case 'STOPPED':
        return const Color(0xFFFBE9E7);
      case 'COMPLETED':
      case 'FINISHED':
        return const Color(0xFFE8F5E9);
      case 'MAINTENANCE':
      case 'ISSUE':
      case 'BREAKDOWN':
        return const Color(0xFFFFEBEE);
      case 'DELAYED':
        return const Color(0xFFFFF8E1);
      case 'OFFLINE':
      default:
        return const Color(0xFFF5F5F5);
    }
  }

  Widget _buildOrganizedTruckCard(Map<dynamic, dynamic> truck) {
    final String tid = (truck['truckNumber'] ?? truck['truck_id'] ?? truck['truckId'] ?? 'GT-007').toString();
    final String license = (truck['plate_number'] ?? truck['plateNumber'] ?? truck['license_number'] ?? '').toString();
    final String driver = (truck['driver_name'] ?? truck['driverName'] ?? 'Driver').toString();
    final String status = (truck['status'] ?? 'IDLE').toString().toUpperCase();
    final bool isActive = status == 'ACTIVE' || status == 'COLLECTING';
    final Color statusColor = _getFleetStatusColor(status);
    final Color statusBgColor = _getFleetStatusBgColor(status);

    final double speed = (truck['speed'] ?? 0.0).toDouble();
    final double dist = (truck['total_distance'] ?? truck['total_distance_km'] ?? truck['distance'] ?? 0.0).toDouble();
    final double fuel = double.tryParse((truck['fuel'] ?? truck['fuel_level'] ?? 0.0).toString()) ?? 0.0;
    final int stops = int.tryParse((truck['detected_stops_count'] ?? truck['stops_count'] ?? truck['total_stops'] ?? 0).toString()) ?? 0;
    final String area = (truck['current_purok'] ?? truck['location'] ?? truck['area'] ?? truck['purok'] ?? "Balintawak").toString();

    final double etaMins = PredictionEngine.estimateArrivalTime(dist > 0 ? dist : 2.5, [speed > 5 ? speed : 15.0]);
    final String eta = isActive ? "${etaMins.toStringAsFixed(0)} mins" : "--";
    String lastUpdate = truck['updatedAt'] != null || truck['lastSeen'] != null ? "just now" : "Offline";

    return _HoverZoomCard(
      onTap: () {
        if (Navigator.canPop(context)) {
          Navigator.pop(context);
        }
        setState(() => _selectedIndex = 1);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 15,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(
              color: Colors.grey.shade200,
              width: 1
            )),
        child: Column(children: [
          // Top Row: Icon, Driver Name, Truck ID / License, Status
          Row(children: [
            Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(16)),
                child: const Icon(
                  Icons.local_shipping_rounded,
                  color: Color(0xFF2196F3),
                  size: 26
                )),
            const SizedBox(width: 14),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(driver,
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
              Text("$tid | $license",
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 11.5, fontWeight: FontWeight.w600))
            ])),
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: statusBgColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: statusColor.withOpacity(0.3))),
                child: Text(status,
                    style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w900))),
          ]),

          const SizedBox(height: 18),

          // Middle Info: Location, Speed, Driver
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildFleetMetricsInfo(Icons.location_on_rounded, Colors.redAccent, "Location", area),
            _buildFleetMetricsInfo(Icons.speed_rounded, Colors.blueAccent, "Speed", "${speed.toStringAsFixed(0)} km/h"),
            _buildFleetMetricsInfo(Icons.person_rounded, Colors.indigoAccent, "Driver", driver),
          ]),

          const SizedBox(height: 16),

          // Metrics Pill Row
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.grey.shade100)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _buildFleetPillMetric(Icons.straighten_rounded, Colors.green, "DISTANCE", "${dist.toStringAsFixed(1)} km"),
              Container(width: 1, height: 18, color: Colors.grey.shade300),
              _buildFleetPillMetric(Icons.local_gas_station_rounded, Colors.orange, "FUEL", "${fuel.toStringAsFixed(1)} L"),
              Container(width: 1, height: 18, color: Colors.grey.shade300),
              _buildFleetPillMetric(Icons.pause_circle_filled_rounded, Colors.red, "STOPS", "$stops"),
            ]),
          ),

          const SizedBox(height: 16),

          // Footer
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildFleetFooterInfo(Icons.access_time_rounded, "Last Update: $lastUpdate"),
            _buildFleetFooterInfo(null, "Start: --:--"),
            _buildFleetFooterInfo(null, "ETA: $eta", isTeal: true),
          ]),
        ])),
    );
  }

  Widget _buildFleetMetricsInfo(IconData icon, Color color, String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5, color: Color(0xFF1A1A1A))),
    ]);
  }

  Widget _buildFleetPillMetric(IconData icon, Color color, String label, String value) {
    return Column(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 8, color: Colors.grey, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ]),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11.5, color: Color(0xFF2196F3))),
    ]);
  }

  Widget _buildFleetFooterInfo(IconData? icon, String text, {bool isTeal = false}) {
    return Row(children: [
      if (icon != null) ...[Icon(icon, size: 12, color: Colors.grey), const SizedBox(width: 4)],
      Text(text, style: TextStyle(
        fontSize: 10,
        color: isTeal ? const Color(0xFF00796B) : Colors.grey,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2
      )),
    ]);
  }

  Widget _buildAdminActionsGrid(bool isMobile) {
    // The list lives in utils/admin_quick_actions.dart so Android, Web and both layouts
    // always show the same actions.
    final List<Widget> cards = kAdminQuickActions
        .map((AdminQuickAction a) => _buildModernActionCard(a.title, a.subtitle, a.icon, a.color,
            onTap: () => setState(() {
              if (a.targetIndex == AdminDestinations.routeHistory) _prepareRouteHistoryEntry();
              _selectedIndex = a.targetIndex;
            })))
        .toList();

    final Widget header = Padding(
      padding: EdgeInsets.only(left: 4, bottom: isMobile ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Quick Actions",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
          Text("Manage system components and data",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
        ],
      ),
    );

    if (isMobile) {
      final List<Widget> column = <Widget>[header];
      for (int i = 0; i < cards.length; i++) {
        if (i > 0) column.add(const SizedBox(height: 12));
        column.add(cards[i]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: column);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 12,
        childAspectRatio: 2.8,
        children: cards,
      ),
    ]);
  }

  Widget _buildModernActionCard(String title, String subtitle, IconData icon,
      Color color, {VoidCallback? onTap}) {
    bool isDesktop = Responsive.isDesktop(context);
    return _HoverZoomCard(
      onTap: onTap,
      child: Container(
        margin: isDesktop ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 2),
        padding: isDesktop ? const EdgeInsets.symmetric(horizontal: 24, vertical: 12) : const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(isDesktop ? 24 : 24),
          boxShadow: AppTheme.pulidongShadow,
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: Color(0xFFE0E0E0), size: 16)
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderIconButton(IconData icon, {int? badgeCount, VoidCallback? onTap, bool isInAppBar = false}) {
    return GestureDetector(onTap: onTap, child: Stack(clipBehavior: Clip.none, children: [
      Container(
        width: 44, height: 44, 
        decoration: BoxDecoration(
          color: isInAppBar ? Colors.white : Colors.white.withAlpha(180), 
          borderRadius: BorderRadius.circular(12), 
          boxShadow: AppTheme.balancedPulidongShadow,
          border: Border.all(color: Colors.grey.shade200)
        ), 
        child: Icon(icon, color: const Color(0xFF1A1A1A), size: 22)
      ),
      if (badgeCount != null) Positioned(right: -4, top: -4, child: Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Color(0xFFFF1744), shape: BoxShape.circle), child: Text("$badgeCount", style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)))),
    ]));
  }

  Widget _buildBottomNav() {
    final double bottomPadding = MediaQuery.of(context).padding.bottom;
    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding > 0 ? bottomPadding : 12),
      height: 68,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(34),
        boxShadow: AppTheme.highIntensityBalancedShadow,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(0, Icons.home_rounded, 'Home'),
          _buildNavItem(1, Icons.location_on_rounded, 'Track'),
          _buildNavItem(2, Icons.analytics_rounded, 'Analytics'),
          _buildNavItem(6, Icons.settings_suggest_rounded, 'Settings'),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    bool isSelected = _selectedIndex == index;
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isSmall = screenWidth < 380;
    
    final double labelFontSize = (screenWidth * 0.035).clamp(11.0, 14.0);
    final double iconSize = (screenWidth * 0.065).clamp(22.0, 26.0);

    return _HoverZoomLink(
      onTap: () {
        if (index == 0) _refreshAllStats();
        setState(() {
          if (index == AdminDestinations.routeHistory) _prepareRouteHistoryEntry();
          _selectedIndex = index;
        });
      },
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          padding: EdgeInsets.symmetric(
            horizontal: isSelected ? (isSmall ? 8 : 16) : 8, 
            vertical: 8
          ),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF00796B).withOpacity(0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade400, size: iconSize),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: const Color(0xFF00796B),
                    fontWeight: FontWeight.w900,
                    fontSize: labelFontSize,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _handleNotificationClick(Map item, {bool closePanel = true}) {
    if (!mounted) return;
    if (closePanel) Navigator.pop(context);

    final String type = (item['type'] ?? '').toString().toUpperCase();
    final String title = (item['title'] ?? '').toString().toUpperCase();
    final String message = (item['message'] ?? '').toString().toUpperCase();

    // 1. New Registration -> User Management Page (Index 4)
    if (type.contains('REGISTRATION') ||
        type.contains('REGISTER') ||
        type.contains('NEW_USER') ||
        title.contains('REGISTRATION') ||
        title.contains('REGISTER') ||
        title.contains('NEW RESIDENT') ||
        title.contains('NEW DRIVER') ||
        message.contains('REGISTRATION') ||
        message.contains('REGISTER')) {
      setState(() => _selectedIndex = 4);
    }
    // 2. Driver / Map-related notification -> GIS Tracking Page (Index 1)
    else if (type.contains('TRUCK') ||
             type.contains('MAP') ||
             type.contains('LOCATION') ||
             type.contains('FLEET') ||
             type.contains('PROXIMITY') ||
             type.contains('GPS') ||
             type.contains('ENTRY') ||
             type.contains('EXIT') ||
             type.contains('ALERT') ||
             type.contains('ARRIVAL') ||
             title.contains('TRUCK') ||
             title.contains('LOCATION') ||
             title.contains('FLEET') ||
             title.contains('MAP') ||
             message.contains('TRUCK') ||
             message.contains('LOCATION') ||
             message.contains('MAP')) {
      setState(() => _selectedIndex = 1);
    }
    // 3 & 4. Complaint or Driver Report -> Complaint Management (Index 3)
    else {
      setState(() => _selectedIndex = 3);
    }
  }

  /// Shared notification center: swipe to remove, Clear all, Mark all read.
  void _showNotificationsModal(BuildContext context) {
    final NotificationInbox? inbox = _inbox;
    if (inbox == null) return;
    showNotificationCenter(
      context,
      source: _database.ref('notifications').onValue.map((DatabaseEvent e) => e.snapshot.value),
      isRelevant: _isNotificationForMe,
      inbox: inbox,
      onOpen: (Map item) => _handleNotificationClick(item, closePanel: false),
    );
  }



  void _showSnackBar(String message) {
    CustomNotification.showTopNotification(context, message, false);
  }

  Future<bool> _showConfirmDialog({required String title, required String message, bool isDestructive = false}) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 14, height: 1.5)),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.grey),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("CANCEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDestructive ? Colors.red : const Color(0xFF00796B),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("CONFIRM", style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ) ?? false;
  }


  Future<void> _showLogoutDialog(BuildContext context) async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    await SystemLogger.logEvent("LOGOUT", "Admin session ended");
    NotificationService.stopListening();
    await SessionManager.logout(forgetLogin: choice == LogoutChoice.forget, keepSignedIn: choice == LogoutChoice.remember || choice == LogoutChoice.switchAccount);
    await RoutePersistenceManager.clearLastRoute();
    if (mounted) {
      CustomNotification.showTopNotification(context, "Logout successful", false);
      Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
    }
  }

}

class _HoverZoomCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  const _HoverZoomCard({required this.child, this.onTap, this.scale = 1.02});
  @override
  State<_HoverZoomCard> createState() => _HoverZoomCardState();
}
class _HoverZoomCardState extends State<_HoverZoomCard> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    bool isEnabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = isEnabled),
      onExit: (_) => setState(() => _isActive = false),
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = isEnabled),
        onTapUp: (_) => setState(() => _isActive = false),
        onTapCancel: () => setState(() => _isActive = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isActive ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}

class _HoverZoomLink extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _HoverZoomLink({required this.child, this.onTap});
  @override
  State<_HoverZoomLink> createState() => _HoverZoomLinkState();
}
class _HoverZoomLinkState extends State<_HoverZoomLink> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    bool isEnabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = isEnabled),
      onExit: (_) => setState(() => _isActive = false),
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = isEnabled),
        onTapUp: (_) => setState(() => _isActive = false),
        onTapCancel: () => setState(() => _isActive = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isActive ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}
