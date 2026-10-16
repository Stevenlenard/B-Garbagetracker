import '../widgets/logout_choice_dialog.dart';
import '../services/rtdb_port.dart';
import '../services/notification_inbox.dart';
import '../utils/relative_time.dart';
import '../utils/complaint_flow.dart';
import '../utils/eta_policy.dart';
import '../utils/fleet_status.dart';
import 'dart:async';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../widgets/notification_center.dart';
import '../utils/resident_alert_rules.dart';
import '../services/collection_schedule_service.dart';
import '../services/collection_reminder_service.dart';
import '../chatbot/faq_bot.dart';
import '../widgets/truck_chat_widget.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../utils/prediction_engine.dart';
import '../utils/fleet_snapshot.dart';
import '../utils/tracking_telemetry.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../utils/app_theme.dart';
import 'resident_track_truck_screen.dart';
import 'resident_complaints_screen.dart';
import 'resident_settings_screen.dart';
import 'route_history_screen.dart';
import '../utils/responsive.dart';
import '../widgets/mapbox_view.dart';
import '../widgets/fade_slide_entrance.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/header_circle_painter.dart';
import '../widgets/data_management_modal.dart';
import '../widgets/custom_snackbar.dart';
import '../api/api_service.dart';
import 'package:dio/dio.dart';
import '../utils/route_persistence_manager.dart';
import '../utils/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/truck_locations_feed.dart';
import 'collection_route_optimization_screen.dart';
import '../widgets/map_view_switch.dart';

class ResidentDashboard extends StatefulWidget {
  const ResidentDashboard({super.key});

  @override
  State<ResidentDashboard> createState() => _ResidentDashboardState();
}

class _ResidentDashboardState extends State<ResidentDashboard> with TickerProviderStateMixin {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  UserData? _user;
  geo.Position? _currentPosition;
  int _activeTrucks = 0;
  int _totalTrucks = 0;
  int _unreadNotificationsCount = 0;
  int _selectedIndex = 0;
  // Truck Tracking tab: live map or Collection Route Optimization ("Collection status").
  bool _showRoutePlan = false;
  bool _routePlanOpened = false; // built on first use
  int _complaintsRefreshCount = 0;
  String? _targetComplaintId;
  bool _shouldShowDataManagement = false;
  String _etaText = "--";
  String _currentTime = "";
  Timer? _clockTimer;
  Future<Response>? _complaintsFuture;
  final ScrollController _scrollController = ScrollController();
  bool _showHeaderShadow = true;

  bool _isRefreshing = false;
  bool _showRefreshSpinner = false;
  double _manualPullDepth = 0.0;
  late AnimationController _refreshRotationController;

  void _refreshComplaints() {
    if (mounted) {
      setState(() {
        _complaintsFuture = _apiService.getComplaints();
        _complaintsRefreshCount++;
      });
    }
  }

  StreamSubscription? _truckSubscription;
  Timer? _fleetAgingTimer;
  NotificationInbox? _inbox; // this resident's own read/dismiss/clear state
  InboxState _inboxState = InboxState.empty;
  StreamSubscription<InboxState>? _inboxSub;
  Map<dynamic, dynamic>? _rawNotifications;
  Map<dynamic, dynamic>? _rawTruckLocations;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _totalTruckSubscription;
  StreamSubscription? _userRealtimeSubscription;

  final Map<String, DateTime> _sentProximityAlerts = {};
  late AnimationController _circleController;

  @override
  void initState() {
    super.initState();
    NotificationService.openHomeRequests.addListener(_openHomeFromNotification);
    RoutePersistenceManager.saveLastRoute('/resident_dashboard');
    _loadUser();
    _startClock();
    _getCurrentLocation();
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
  }

  /// A tapped phone notification shows the dashboard's Home tab.
  void _openHomeFromNotification() {
    if (mounted) setState(() { _selectedIndex = 0; _showRoutePlan = false; });
  }

  @override
  void dispose() {
    NotificationService.openHomeRequests.removeListener(_openHomeFromNotification);
    _scheduleSub?.cancel();
    _clockTimer?.cancel();
    _truckSubscription?.cancel();
    _fleetAgingTimer?.cancel();
    _notificationSubscription?.cancel();
    _totalTruckSubscription?.cancel();
    _userRealtimeSubscription?.cancel();
    _circleController.dispose();
    _refreshRotationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) return;
    }
    if (permission == geo.LocationPermission.deniedForever) return;
    geo.Geolocator.getPositionStream().listen((pos) {
      if (mounted) setState(() => _currentPosition = pos);
    });
    try {
      geo.Position pos = await geo.Geolocator.getCurrentPosition();
      if (mounted) setState(() => _currentPosition = pos);
    } catch (_) {}
  }

  void _startClock() {
    _updateTime();
    _clockTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) => _updateTime());
  }

  void _updateTime() {
    final String time = DateFormat('hh:mm:ss a').format(DateTime.now());
    if (mounted && _currentTime != time) setState(() => _currentTime = time);
  }

  Future<void> _refreshAllStats({bool manual = false}) async {
    if (_isRefreshing) return;
    
    if (manual && mounted) {
      setState(() {
        _isRefreshing = true;
        _showRefreshSpinner = true;
        _manualPullDepth = 80.0;
      });
    }
    _refreshRotationController.repeat();

    await Future.wait([
      _refreshData(),
      Future.delayed(const Duration(milliseconds: 1500)),
    ]);

    if (manual) {
      await Future.delayed(const Duration(seconds: 1));
    }

    if (mounted) {
      setState(() {
        _isRefreshing = false;
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        setState(() {
          _showRefreshSpinner = false;
          _manualPullDepth = 0.0;
        });

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
                      BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 15,
                          offset: const Offset(0, 5))
                    ],
                  ),
                  child: const Material(
                    color: Colors.transparent,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_rounded, color: Colors.green, size: 20),
                        SizedBox(width: 12),
                        Text("Dashboard updated",
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                color: Color(0xFF1A1A1A))),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        }
      }
      _refreshRotationController.stop();
    }
  }

  Future<void> _refreshData() async {
    _loadUser();
    _refreshComplaints();
    await Future.delayed(const Duration(milliseconds: 800));
  }

  void _loadUser() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sessionUser = await SessionManager.getUser();
      if (sessionUser != null) {
        setState(() {
          _user = sessionUser;
          _complaintsFuture = _apiService.getComplaints();
        });
        NotificationService.startListening(_user!);
        _setupListeners();
        _watchSchedule();
      }
    });
  }

  StreamSubscription<Map<String, CollectionSchedule>>? _scheduleSub;
  CollectionSchedule? _mySchedule;
  bool _scheduleLoaded = false;

  /// The admin-set schedule of this resident's purok: shown on the Schedule card and turned
  /// into weekly reminders on the phone (they arrive even when the app is closed).
  void _watchSchedule() {
    _scheduleSub?.cancel();
    _scheduleSub = CollectionScheduleService.watch().listen((Map<String, CollectionSchedule> all) {
      final CollectionSchedule? mine = CollectionScheduleService.forPurok(all, _user?.purok);
      if (mounted) setState(() {
        _mySchedule = mine;
        _scheduleLoaded = true;
      });
      CollectionReminderService.sync(mine);
    }, onError: (Object _) {
      if (mounted) setState(() => _scheduleLoaded = true);
    });
  }

  void _setupListeners() {
    if (_user == null) return;
    _userRealtimeSubscription?.cancel();
    _userRealtimeSubscription = _database.ref('residents/${_user!.userId}').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        if (mounted) {
          final updatedUser = _user!.copyWith(
            name: data['name']?.toString(),
            purok: data['purok']?.toString(),
            email: data['email']?.toString(),
            phone: data['phone']?.toString(),
            completeAddress: data['complete_address']?.toString(),
            profilePicture: data['profile_picture']?.toString(),
          );
          setState(() {
            _user = updatedUser;
          });
          // Persist to session
          SessionManager.saveUser(updatedUser.toJson());
        }
      }
    });

    _truckSubscription?.cancel();
    _truckSubscription = TruckLocationsFeed.shared().events.listen((event) {
      _rawTruckLocations = (event.snapshot.exists && event.snapshot.value is Map)
          ? Map<dynamic, dynamic>.from(event.snapshot.value as Map)
          : null;
      // Dev-only timing (test mode + GT_TELEMETRY); no-op in production.
      TrackingTelemetry.onTruckLocations(_rawTruckLocations, source: 'resident_cards');
      _recomputeResidentFleet();
    });
    // A driver that stops reporting sends no event, so freshness is re-evaluated
    // on a timer; otherwise the count would never fall.
    _fleetAgingTimer?.cancel();
    _fleetAgingTimer = Timer.periodic(const Duration(seconds: 15), (_) => _recomputeResidentFleet(fromAging: true));

    _fetchTotalDriversFromUserManagement();

    _totalTruckSubscription?.cancel();
    _totalTruckSubscription = _database.ref('users').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        int driverCount = 0;
        data.forEach((key, value) {
          if (value is Map) {
            final String role = (value['role'] ?? '').toString().toLowerCase();
            final String status = (value['account_status'] ?? '').toString().toLowerCase();
            final dynamic isArchivedRaw = value['is_archived'] ?? value['isArchived'];
            final bool isArchived = status == 'archived' ||
                isArchivedRaw == 1 ||
                isArchivedRaw == '1' ||
                isArchivedRaw == true ||
                isArchivedRaw == 'true';

            if (!isArchived && role == 'driver') {
              driverCount++;
            }
          }
        });
        if (mounted && driverCount > 0) {
          setState(() => _totalTrucks = math.max(driverCount, _totalTrucks));
        }
      }
    });

    _ensureInbox();
    _notificationSubscription?.cancel();
    _notificationSubscription = _database.ref('notifications').onValue.listen((event) {
      _rawNotifications = (event.snapshot.exists && event.snapshot.value is Map) ? event.snapshot.value as Map : null;
      _recomputeResidentUnread();
    });
  }

  /// Notifications this resident may see. TRUCK_PROXIMITY is the legacy resident-generated
  /// broadcast (it produced "0 minutes away" duplicates); the driver app's staged
  /// approach/arrival records replace it.
  bool _isResidentRelevant(Map val) => ResidentAlertRules.isFor(val, residentId: _user?.userId, purok: _user?.purok);

  void _ensureInbox() {
    if (_inbox != null || _user == null) return;
    _inbox = NotificationInbox(db: FirebaseRtdbPort(), role: 'resident', userId: _user!.userId);
    _inboxSub = _inbox!.watch().listen((InboxState s) {
      _inboxState = s;
      _recomputeResidentUnread();
    });
  }

  /// Unread = relevant, visible and not read by THIS resident (shared flags are ignored).
  void _recomputeResidentUnread() {
    final Map? data = _rawNotifications;
    if (data == null) {
      if (mounted) setState(() => _unreadNotificationsCount = 0);
      return;
    }
    final List<Map> relevant = <Map>[];
    data.forEach((key, value) {
      if (value is Map && _isResidentRelevant(value)) {
        relevant.add(<dynamic, dynamic>{...value, 'key': key.toString()});
      }
    });
    final List<Map> visible = NotificationInbox.visible(relevant, _inboxState);
    final int unread = NotificationInbox.unreadCount(visible, _inboxState);
    if (mounted) setState(() => _unreadNotificationsCount = unread);
  }

  /// Re-derives the Active Fleets card and ETA from the latest raw snapshot.
  /// [fromAging] re-evaluates freshness only (no proximity notification).
  void _recomputeResidentFleet({bool fromAging = false}) {
    final Map<dynamic, dynamic>? data = _rawTruckLocations;
    if (data != null) {
      final Stopwatch? telemetryClock = TrackingTelemetry.enabled ? (Stopwatch()..start()) : null;
      // Shared fleet snapshot (same function as the Admin cards and the live map).
      // Resident-only exclusion: reserved/test driver names, kept as before.
      final FleetSnapshot fleet = FleetSnapshot.derive(
        data,
        includeCompleted: true,
        exclude: (String nodeKey, Map node) {
          final String dNameUpper = (node['driver_name'] ?? node['driverName'] ?? 'Driver').toString().trim().toUpperCase();
          return dNameUpper.contains("ARIAN JOY") ||
              dNameUpper.contains("JOHN DRIVER") ||
              dNameUpper.contains("SYSTEM ADMIN");
        },
      );
      {
        // ETA/cards use the collection fleet (a COMPLETED truck is not collecting).
        final List<Map<dynamic, dynamic>> onlineTrucks = fleet.fleetTrucks.map((LiveTruck t) => t.node).toList();
        final int activeCount = fleet.activeFleets;
        // ETA only from a truck that is COLLECTING with fresh GPS, from its real speed.
        // Otherwise "ETA unavailable": never "0 min" and never an invented number. Arrival
        // alerts are the driver app's job (once per trip, area and stage); the resident app
        // no longer broadcasts its own.
        EtaResult? best;
        final int nowMs = DateTime.now().millisecondsSinceEpoch;
        int rank(EtaResult r) => r.kind == EtaKind.arrived ? -1 : (r.minutes ?? 1 << 30);
        for (final Map<dynamic, dynamic> val in onlineTrucks) {
          if (_currentPosition == null) break;
          final double? lat = double.tryParse('${val['latitude']}');
          final double? lng = double.tryParse('${val['longitude']}');
          if (lat == null || lng == null || (lat == 0.0 && lng == 0.0)) continue;
          final double distKm = geo.Geolocator.distanceBetween(_currentPosition!.latitude, _currentPosition!.longitude, lat, lng) / 1000.0;
          final EtaResult r = EtaPolicy.evaluate(
            status: FleetStatus.collectionState(val),
            gpsAgeMs: FleetStatus.gpsAgeMs(val, nowMs: nowMs),
            distanceKm: distKm,
            speedKmh: double.tryParse('${val['speed']}'),
            averageSpeedKmh: double.tryParse('${val['avg_speed']}'),
          );
          if (best == null || (r.isAvailable && (!best.isAvailable || rank(r) < rank(best)))) best = r;
        }
        final String etaDisplay = activeCount == 0 ? "--" : (best?.label ?? "ETA unavailable");
        if (mounted) setState(() { _activeTrucks = activeCount; _etaText = etaDisplay; });
        if (telemetryClock != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            TrackingTelemetry.onFleetRendered(source: 'resident_cards', ms: telemetryClock.elapsedMilliseconds);
          });
        }
      }
    } else if (mounted) {
      // No truck data at all: clear the count instead of leaving a stale value.
      setState(() { _activeTrucks = 0; _etaText = "--"; });
    }
  }

  Future<void> _fetchTotalDriversFromUserManagement() async {
    try {
      final response = await ApiService().getUsers();
      if (response.data != null && response.data['success'] == true) {
        final List users = response.data['users'] ?? [];
        final List residents = response.data['residents'] ?? [];
        final allList = [...users, ...residents];

        int driverCount = 0;
        for (var user in allList) {
          if (user is Map) {
            final String role = (user['role'] ?? '').toString().toLowerCase().trim();
            final String status = (user['account_status'] ?? user['status'] ?? '').toString().toLowerCase();
            final dynamic isArchivedRaw = user['is_archived'] ?? user['isArchived'];
            final bool isArchived = status == 'archived' ||
                isArchivedRaw == 1 ||
                isArchivedRaw == '1' ||
                isArchivedRaw == true ||
                isArchivedRaw == 'true';

            if (role == 'driver' && !isArchived) {
              driverCount++;
            }
          }
        }
        if (mounted && driverCount > 0) {
          setState(() {
            _totalTrucks = math.max(driverCount, _totalTrucks);
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching driver count from User Management API: $e");
    }
  }

  Future<void> _handleLogout() async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    NotificationService.stopListening();
    await SessionManager.logout(forgetLogin: choice == LogoutChoice.forget, keepSignedIn: choice == LogoutChoice.remember || choice == LogoutChoice.switchAccount);
    await RoutePersistenceManager.clearLastRoute();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }


  void _viewProfilePicture() {
    if (_user == null) return;
    final String profileUrl = _user?.profilePictureUrl ?? "";
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Profile",
      barrierColor: Colors.black.withOpacity(0.5),
      pageBuilder: (context, _, __) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(color: Colors.transparent),
              ),
              Center(
                child: Hero(
                  tag: 'web_profile_pic',
                  child: Container(
                    width: 320,
                    height: 320,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        )
                      ],
                      image: profileUrl.isNotEmpty
                          ? DecorationImage(image: NetworkImage(profileUrl), fit: BoxFit.cover)
                          : null,
                    ),
                    child: profileUrl.isEmpty
                        ? const Icon(Icons.person, size: 160, color: Colors.white)
                        : null,
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = Responsive.isDesktop(context);
    
    Widget mainLayout;
    if (isDesktop) {
      mainLayout = Row(
        children: [
          _buildSidebar(), 
          Expanded(child: _buildMainContent())
        ]
      );
    } else {
      mainLayout = Stack(
        children: [
          _buildMainContent(), 
          Positioned(left: 0, right: 0, bottom: 0, child: _buildBottomNav())
        ]
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;

        if (_selectedIndex > 0) {
          setState(() {
            _selectedIndex = 0;
          });
          return;
        }

        final bool shouldExit = await _showExitConfirmationDialog(context);
        if (shouldExit) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.dashboardBg,
        extendBody: !isDesktop,
        body: Stack(
          children: [
            mainLayout,
            _buildRefreshSpinner(),
            // Shown on every resident page; the resident can drag it out of the way.
            TruckChatLauncher(
              role: 'resident',
              purok: _user?.purok,
              onAction: _handleBotAction,
              right: isDesktop ? 28 : 16,
              bottom: isDesktop ? 120 : 100 + MediaQuery.paddingOf(context).bottom,
            ),
          ],
        ),
      ),
    );
  }

  /// Screens the Truck Buddy help bot can open.
  void _handleBotAction(BotAction action) {
    setState(() {
      switch (action) {
        case BotAction.home:
          _selectedIndex = 0;
        case BotAction.track:
          _selectedIndex = 1;
          _showRoutePlan = false;
        case BotAction.collectionStatus:
          _selectedIndex = 1;
          _showRoutePlan = true;
          _routePlanOpened = true;
        case BotAction.complaints:
        case BotAction.fileComplaint:
          _selectedIndex = 2;
        case BotAction.settings:
          _selectedIndex = 3;
        case BotAction.routeHistory:
          _selectedIndex = 4;
        default:
          break;
      }
    });
  }

  Widget _buildMainContent() {
    return IndexedStack(index: _selectedIndex, children: [
        FadeSlideEntrance(key: const ValueKey("home"), child: _buildHomeTab()),
        FadeSlideEntrance(key: const ValueKey("track"), child: IndexedStack(index: _showRoutePlan ? 1 : 0, sizing: StackFit.expand, children: [
          ResidentTrackTruckScreen(isEmbedded: true, onBack: () => setState(() => _selectedIndex = 0), viewSwitch: _mapViewSwitch(0)),
          _routePlanOpened
              ? CollectionRouteOptimizationScreen(role: 'resident', isEmbedded: true, headerAccessory: _mapViewSwitch(1))
              : const SizedBox.shrink(),
        ])),
        FadeSlideEntrance(key: ValueKey("complaints_$_complaintsRefreshCount"), child: ResidentComplaintsScreen(isEmbedded: true, targetComplaintId: _targetComplaintId, onDataChanged: _refreshComplaints, onBack: () {
          setState(() {
            _selectedIndex = 0;
            _targetComplaintId = null;
          });
        })),
        FadeSlideEntrance(key: const ValueKey("settings"), child: ResidentSettingsScreen(isEmbedded: true, showDataManagementOnLoad: _shouldShowDataManagement, onBack: () => setState(() { _selectedIndex = 0; _shouldShowDataManagement = false; }), onProfileUpdate: _loadUser)),
        FadeSlideEntrance(key: const ValueKey("history"), child: RouteHistoryScreen(isEmbedded: true, onBack: () => setState(() => _selectedIndex = 0))),
    ]);
  }

  Widget _buildWebHeader() {
    final String? profileUrl = _user?.profilePictureUrl;
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
          // 1. Left Section: Profile + Greeting + Location Info
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
                      boxShadow: AppTheme.pulidongShadow,
                      border: Border.all(color: const Color(0xFF00796B), width: 2.5),
                      image: profileUrl != null
                          ? DecorationImage(image: NetworkImage(profileUrl), fit: BoxFit.cover)
                          : null,
                    ),
                    child: profileUrl == null
                        ? Center(child: Text((_user?.name != null && _user!.name.isNotEmpty) ? _user!.name[0].toUpperCase() : "R", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF00796B))))
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
                        _user?.name ?? "Resident",
                        style: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -1),
                      ),
                      const SizedBox(width: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00796B).withOpacity(0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF00796B).withOpacity(0.1)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.location_on_rounded, color: Color(0xFF00796B), size: 16),
                            const SizedBox(width: 8),
                            Text(
                              _user?.purok ?? "Detecting...", 
                              style: const TextStyle(color: Color(0xFF2C3E50), fontSize: 14, fontWeight: FontWeight.w800)
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          // 2. Right Section: Time and Notifications
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
              _buildHeaderActionIcon(Icons.notifications_outlined, badgeCount: _unreadNotificationsCount > 0 ? _unreadNotificationsCount : null, onTap: () => _showNotificationsModal(context), isDark: true),
            ],
          ),
        ],
      ),
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
          // Animated Background Circles
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
                  child: const Icon(Icons.map_rounded, color: Colors.white, size: 32),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Track Your Local Garbage Collection",
                        style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Real-time updates on truck locations and ETAs in your area.",
                        style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                _HoverZoomCard(
                  onTap: () => setState(() { _selectedIndex = 1; _showRoutePlan = false; }),
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
                      "Track Now", 
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

  Widget _buildHomeTab() {
    return LayoutBuilder(builder: (context, constraints) {
      final bool isDesktop = Responsive.isDesktop(context);
      
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (event) {
          bool atTop = _scrollController.hasClients && _scrollController.offset <= 0;
          if (!_isRefreshing && (atTop || _manualPullDepth > 0)) {
            if (event.delta.dy > 0 || _manualPullDepth > 0) {
              setState(() {
                _manualPullDepth += event.delta.dy * 0.5;
                if (_manualPullDepth < 0) _manualPullDepth = 0;
                if (_manualPullDepth > 120) _manualPullDepth = 120;
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
        child: isDesktop ? _buildDesktopHome() : _buildMobileHome(constraints.maxWidth),
      );
    });
  }

  Widget _buildDesktopHome() {
    return Column(
      children: [
        _buildWebHeader(),
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
            child: SingleChildScrollView(
              controller: _scrollController,
              physics: (_manualPullDepth > 0 || _isRefreshing) 
                  ? const NeverScrollableScrollPhysics() 
                  : const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              child: AnimatedBuilder(
                animation: _scrollController,
                builder: (context, child) {
                  final double offset = _scrollController.hasClients ? _scrollController.offset : 0;
                  return Transform.translate(
                    offset: Offset(0, offset < 0 ? offset : 0),
                    child: Column(
                      children: [
                        const SizedBox(height: 32),
                        _buildWebBanner(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildStatCard(
                                            "Active Trucks",
                                            "$_activeTrucks / $_totalTrucks",
                                            Icons.local_shipping_rounded,
                                            AppColors.statActiveBg,
                                            isLive: true,
                                          ),
                                        ),
                                        const SizedBox(width: 20),
                                        Expanded(
                                          child: _buildStatCard(
                                            "Estimated Time",
                                            _etaText,
                                            Icons.access_time_filled_rounded,
                                            AppColors.statEtaBg,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 24),
                                    _buildMapCard(),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(left: 0, bottom: 16),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text("Reports & Feedback", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                                          Text("File new reports and track your submitted complaints.", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                                        ],
                                      ),
                                    ),
                                    _buildActionCard("File Complaint", "Report collection issues", Icons.feedback_rounded, const Color(0xFFFFF0F2), const Color(0xFFFF1744)),
                                    // Route History and Collection Status are in the sidebar on web.
                                    const SizedBox(height: 24),
                                    _buildTransactionHistoryCard(),
                                    const SizedBox(height: 24),
                                    _buildScheduleCard(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileHome(double maxWidth) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: (_manualPullDepth > 0 || _isRefreshing) 
            ? const NeverScrollableScrollPhysics() 
            : const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        child: AnimatedBuilder(
          animation: _scrollController,
          builder: (context, child) {
            final double offset = _scrollController.hasClients ? _scrollController.offset : 0;
            return Transform.translate(
              offset: Offset(0, offset < 0 ? offset : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(maxWidth),
                  const SizedBox(height: 8),
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(children: [
                        Expanded(child: _buildStatCard("Active Trucks", "$_activeTrucks / $_totalTrucks", Icons.local_shipping_rounded, AppColors.statActiveBg, isLive: true)),
                        const SizedBox(width: 12),
                        Expanded(child: _buildStatCard("Estimated Time", _etaText, Icons.access_time_filled_rounded, AppColors.statEtaBg))
                      ])),
                  const SizedBox(height: 16),
                  _buildMapCard(),
                  _buildSectionHeader("Collection History", "See where garbage trucks have collected in your area."),
                  _buildActionCard("Route History", "View recorded collection routes and truck visits", Icons.route_rounded, const Color(0xFFE0F2F1), const Color(0xFF00796B)),
                  const SizedBox(height: 12),
                  _buildActionCard("Collection Status", "When was each area last collected?", Icons.event_available_rounded, const Color(0xFFE8F5E9), const Color(0xFF2E7D32)),
                  const SizedBox(height: 16),
                  _buildSectionHeader("Reports & Feedback", "File new reports and track your submitted complaints."),
                  _buildActionCard("File Complaint", "Report issues", Icons.feedback_rounded, const Color(0xFFFFF0F2), const Color(0xFFFF1744)),
                  const SizedBox(height: 16),
                  _buildTransactionHistoryCard(),
                  const SizedBox(height: 16),
                  _buildScheduleCard(),
                  const SizedBox(height: 110),
                ],
              ),
            );
          }
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, [String? subtitle]) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A1A),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMapCard() {
    bool isDesktop = Responsive.isDesktop(context);
    return Container(
      margin: isDesktop ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(isDesktop ? 32 : 28),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: AppTheme.balancedPulidongShadow,
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.location_on_rounded, color: Color(0xFF2196F3), size: 24)),
            title: const Text("Live Tracking",
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            subtitle: const Text("Real-time monitoring",
                style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
            trailing: _HoverZoomLink(
              onTap: () => setState(() { _selectedIndex = 1; _showRoutePlan = false; }),
              child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration:
                      BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(12)),
                  child: const Text("Open Map",
                      style: TextStyle(
                          color: Color(0xFF00796B), fontWeight: FontWeight.w900, fontSize: 13))),
            ),
          ),
          Container(
            height: isDesktop ? 450 : 300,
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.grey.shade100),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: const MapboxView(mode: 'dashboard'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleCard() {
    bool isDesktop = Responsive.isDesktop(context);
    return Container(
        margin: isDesktop ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: AppTheme.pulidongShadow),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("Collection Schedule", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 4),
          const Text("Stay updated with your local collection times", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
          const SizedBox(height: 24),
          // Only the schedule the barangay set; nothing is guessed when there is none.
          _buildScheduleRow("Collection Days", !_scheduleLoaded ? "Loading..." : (_mySchedule == null ? "Not set yet" : _mySchedule!.daysLabel), isBadge: true),
          const Divider(height: 32),
          _buildScheduleRow("Usual Time", _mySchedule == null ? "Follow the live alerts" : "Around ${_mySchedule!.timeLabel}", isBold: true),
          const Divider(height: 32),
          _buildScheduleRow("Area", _user?.purok ?? "Area", icon: Icons.location_searching_rounded)
        ]));
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
          // Animated Background Decoration
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
          // Sidebar Content
          Column(
            children: [
              // Sidebar Header
              Container(
                padding: const EdgeInsets.fromLTRB(24, 60, 24, 40),
                child: Column(
                  children: [
                    Hero(
                      tag: 'app_logo',
                      child: Container(
                        width: 72, height: 72,
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
                        child: const Icon(Icons.house_rounded, size: 36, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      AppLocalizations.get('garbage_tracker').toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: AppColors.tealText, letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.tealText.withOpacity(0.1)),
                      ),
                      child: const Text(
                        "RESIDENT PORTAL",
                        style: TextStyle(fontSize: 10, color: AppColors.tealText, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(indent: 32, endIndent: 32),
              const SizedBox(height: 24),
              // Sidebar Items
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _buildSidebarItem(0, Icons.home_rounded, 'Dashboard Home'),
                      const SizedBox(height: 8),
                      _buildSidebarItem(1, Icons.location_on_rounded, 'Truck Tracking',
                          selected: _selectedIndex == 1 && !_showRoutePlan,
                          onTap: () => setState(() { _selectedIndex = 1; _showRoutePlan = false; })),
                      const SizedBox(height: 8),
                      // Web: Collection Status and Route History live in the sidebar (phones: cards).
                      _buildSidebarItem(1, Icons.event_available_rounded, 'Collection Status',
                          selected: _selectedIndex == 1 && _showRoutePlan,
                          onTap: () => setState(() { _selectedIndex = 1; _showRoutePlan = true; _routePlanOpened = true; })),
                      const SizedBox(height: 8),
                      _buildSidebarItem(2, Icons.chat_bubble_outline_rounded, 'Report Complaints'),
                      const SizedBox(height: 8),
                      _buildSidebarItem(4, Icons.route_rounded, 'Route History'),
                      const SizedBox(height: 8),
                      _buildSidebarItem(3, Icons.person_outline_rounded, 'Account Settings'),
                    ],
                  ),
                ),
              ),
              // Sidebar Footer
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: _HoverZoomCard(
                  onTap: _handleLogout,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12), // Reduced height
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
                        SizedBox(width: 12),
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
    return Positioned(top: top, left: left, bottom: bottom, right: right, child: Transform.translate(offset: offset, child: Transform.scale(scale: scale, child: Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle)))));
  }

  Widget _buildSidebarItem(int index, IconData icon, String label, {bool? selected, VoidCallback? onTap}) {
    bool isSelected = selected ?? _selectedIndex == index;
    return _HoverZoomCard(
      onTap: onTap ?? () => setState(() => _selectedIndex = index),
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
              color: isSelected ? const Color(0xFF00796B) : Colors.grey,
              size: 20
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade700,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                ),
              ),
            ),
            if (isSelected)
              Container(
                width: 4, height: 16,
                decoration: BoxDecoration(color: const Color(0xFF00796B), borderRadius: BorderRadius.circular(2)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double width) {
    final double screenHeight = MediaQuery.of(context).size.height;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double topSafeArea = MediaQuery.of(context).padding.top;

    bool isMobile = width < 600;
    bool isTablet = width >= 600 && width < 1024;

    // Responsive element dimensions following the Admin Home Dashboard header logic
    final double buttonSize = isMobile ? 38.0 : (isTablet ? 42.0 : 48.0);
    final double iconSize = isMobile ? 20.0 : (isTablet ? 22.0 : 24.0);
    final double clockFontSize = isMobile ? 11.5 : (isTablet ? 12.5 : 13.5);
    final double clockPaddingH = isMobile ? 10.0 : (isTablet ? 12.0 : 16.0);

    final double welcomeFontSize = isMobile ? 11.0 : (isTablet ? 12.0 : 13.0);
    final double nameFontSize = isMobile ? 15.0 : (isTablet ? 17.0 : 19.0);
    final double locationFontSize = isMobile ? 10.5 : (isTablet ? 11.5 : 12.0);

    final double avatarSize = isMobile ? 44.0 : (isTablet ? 52.0 : 60.0);
    final double avatarFontSize = isMobile ? 18.0 : (isTablet ? 20.0 : 22.0);

    final double headerPaddingH = isMobile ? 12.0 : (isTablet ? 18.0 : 24.0);
    final double headerPaddingT = isMobile ? 10.0 : (isTablet ? 12.0 : 16.0);

    // Dynamic calculation of the top controls' bottom boundary
    final double controlsBottom = topSafeArea + headerPaddingT + buttonSize;

    // Clear, intentional vertical gap between top controls and the overlay card
    final double verticalGap = isMobile ? 14.0 : (isTablet ? 18.0 : 22.0);

    // Overlay card top position is dynamically set below the controls with a visible gap
    final double cardTopOffset = controlsBottom + verticalGap;

    // Green background height extends gracefully past the overlay card's top edge
    final double bgHeight = cardTopOffset + (isMobile ? 36.0 : (isTablet ? 42.0 : 50.0));

    final double cardPaddingH = isMobile ? 14.0 : (isTablet ? 18.0 : 20.0);
    final double cardPaddingV = isMobile ? 12.0 : (isTablet ? 16.0 : 18.0);
    final double cardMarginH = isMobile ? 12.0 : (isTablet ? 18.0 : 24.0);
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
                builder: (context, child) => CustomPaint(
                  size: Size(double.infinity, bgHeight),
                  painter: HeaderCirclePainter(_circleController.value),
                ),
              ),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(headerPaddingH, headerPaddingT, headerPaddingH, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Minimalist Clock
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
                      // Action Icons (Notifications & Logout)
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
                            onTap: _handleLogout,
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

        // 2. Overlapping White Card (Dynamic Positioned below Controls)
        Padding(
          padding: EdgeInsets.only(top: cardTopOffset, left: cardMarginH, right: cardMarginH),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: cardPaddingH, vertical: cardPaddingV),
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
                    GestureDetector(
                      onTap: _viewProfilePicture,
                      child: Hero(
                        tag: 'profile_pic_${_user?.userId ?? 'default'}',
                        child: Container(
                          width: avatarSize,
                          height: avatarSize,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF00695C), width: 2),
                            image: (_user?.profilePictureUrl != null && _user!.profilePictureUrl!.isNotEmpty)
                                ? DecorationImage(
                                    image: NetworkImage(_user!.profilePictureUrl!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: (_user?.profilePictureUrl == null || _user!.profilePictureUrl!.isEmpty)
                              ? Center(
                                  child: Text(
                                    (_user?.name != null && _user!.name.isNotEmpty) ? _user!.name[0].toUpperCase() : "R",
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
                    SizedBox(width: innerSpacing),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Welcome back,",
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: welcomeFontSize,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _user?.name != null && _user!.name.isNotEmpty ? _user!.name : "Loading...",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: const Color(0xFF1A1A1A),
                              fontSize: nameFontSize,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.location_on_rounded, color: const Color(0xFF00796B), size: isMobile ? 12 : 14),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  _user?.purok ?? "Detecting...",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: locationFontSize,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: isMobile ? 6 : 8),
                    _HoverZoomLink(
                      onTap: () => _showDataManagementModal(),
                      child: Text(
                        "Edit",
                        style: TextStyle(
                          color: const Color(0xFF00796B),
                          fontWeight: FontWeight.w800,
                          fontSize: isMobile ? 12.0 : 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: isMobile ? 12.0 : 16.0),
                HoverActionButton(
                  text: "Track Trash Truck",
                  onTap: () => setState(() { _selectedIndex = 1; _showRoutePlan = false; }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderActionIcon(IconData icon, {int? badgeCount, VoidCallback? onTap, bool isDark = false, double? size, double? iconSize}) {
    final double btnSize = size ?? 48.0;
    final double iSize = iconSize ?? (isDark ? 22.0 : 24.0);

    Color baseColor = isDark ? AppColors.tealText : Colors.white;
    Color bgColor = isDark ? AppColors.tealText.withOpacity(0.1) : Colors.white.withOpacity(0.15);

    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.05,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: btnSize,
            height: btnSize,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(btnSize < 42 ? 10 : 14),
              border: isDark ? Border.all(color: AppColors.tealText.withOpacity(0.1)) : null,
            ),
            child: Icon(icon, color: baseColor, size: iSize),
          ),
          if (badgeCount != null && badgeCount > 0)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                padding: EdgeInsets.all(btnSize < 42 ? 3 : 4),
                decoration: const BoxDecoration(
                  color: Color(0xFFFF5252),
                  shape: BoxShape.circle,
                ),
                constraints: BoxConstraints(
                  minWidth: btnSize < 42 ? 14 : 16,
                  minHeight: btnSize < 42 ? 14 : 16,
                ),
                child: Center(
                  child: Text(
                    badgeCount > 99 ? '99+' : '$badgeCount',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: btnSize < 42 ? 8 : 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color bgColor, {bool isLive = false}) {
    final bool isDesktop = Responsive.isDesktop(context);
    final Color primaryColor = isLive ? const Color(0xFF00796B) : const Color(0xFFFBC02D);
    
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(isDesktop ? 32 : 28),
        boxShadow: AppTheme.balancedPulidongShadow,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Stack(
        children: [
          // Background "Glass" Highlight
          Positioned(
            top: -20,
            right: -20,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: bgColor.withOpacity(0.4),
                shape: BoxShape.circle,
              ),
            ),
          ),
          // Large Faded Background Icon
          Positioned(
            bottom: -15,
            right: -10,
            child: Icon(
              icon,
              size: 80,
              color: primaryColor.withOpacity(0.05),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: primaryColor, size: 22),
                    ),
                    if (isLive) 
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0F2F1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF00796B).withOpacity(0.2)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xFF00796B),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              "LIVE", 
                              style: TextStyle(
                                color: Color(0xFF00796B), 
                                fontSize: 10, 
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5
                              )
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  title, 
                  style: TextStyle(
                    fontSize: 13, 
                    color: Colors.grey.shade600, 
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2
                  )
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value, 
                      style: TextStyle(
                        fontSize: 26, 
                        fontWeight: FontWeight.w900, 
                        color: isLive ? const Color(0xFF00796B) : const Color(0xFF1A1A1A),
                        letterSpacing: -1.0
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

  Widget _mapViewSwitch(int selected) => MapViewSwitch(
        options: const <MapViewOption>[
          MapViewOption('Map', Icons.map_rounded),
          MapViewOption('Collection status', Icons.fact_check_rounded, color: Color(0xFF1565C0)),
        ],
        selected: selected,
        onChanged: (int i) => setState(() {
          _showRoutePlan = i == 1;
          if (_showRoutePlan) _routePlanOpened = true;
        }),
      );

  Widget _buildActionCard(String title, String subtitle, IconData icon, Color bgColor, Color iconColor) {
    bool isDesktop = Responsive.isDesktop(context);
    return _HoverZoomCard(
      onTap: () {
        if (title == "Collection Status") {
          // Collection Route Optimization, resident view (status and history only), inside the
          // Truck Tracking tab so the sidebar / bottom bar stay visible.
          setState(() {
            _selectedIndex = 1;
            _showRoutePlan = true;
            _routePlanOpened = true;
          });
        } else if (title.contains("Track")) {
          setState(() { _selectedIndex = 1; _showRoutePlan = false; });
        } else if (title.contains("Route") || title.contains("History") || title.contains("GIS")) {
          setState(() => _selectedIndex = 4);
        } else if (title.contains("Settings")) {
          setState(() => _selectedIndex = 3);
        } else if (title.contains("Complaint")) {
          bool isModalLoading = true;
          if (Responsive.isDesktop(context)) {
            showDialog(
              context: context,
              builder: (context) => StatefulBuilder(
                builder: (context, setModalState) {
                  if (isModalLoading) {
                    Future.delayed(const Duration(milliseconds: 800), () {
                      if (mounted) setModalState(() => isModalLoading = false);
                    });
                  }
                  return Dialog(
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeInOutCubic,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(32),
                      ),
                      constraints: BoxConstraints(
                        maxWidth: 550, 
                        maxHeight: isModalLoading ? 380 : MediaQuery.of(context).size.height * 0.85,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(28, 28, 28, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Expanded(child: Text("New Complaint", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                                  ],
                                ),
                                const Text("Report an issue or concern to the garbage collection service.", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                                const SizedBox(height: 16),
                                const Divider(height: 1),
                              ],
                            ),
                          ),
                          if (isModalLoading)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(color: AppColors.tealText),
                                    SizedBox(height: 16),
                                    Text("Preparing your complaint form...", 
                                        style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                                  ],
                                ),
                              ),
                            )
                          else
                            Flexible(
                              child: AddComplaintModal(
                                showHeader: false,
                                onSuccess: () {
                                  _refreshComplaints();
                                }
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }
              ),
            );
          } else {
            showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => StatefulBuilder(
                  builder: (context, setModalState) {
                    if (isModalLoading) {
                      Future.delayed(const Duration(milliseconds: 800), () {
                        if (mounted) setModalState(() => isModalLoading = false);
                      });
                    }
                    return Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOutCubic,
                        constraints: BoxConstraints(
                          maxHeight: isModalLoading ? 380 : MediaQuery.of(context).size.height * 0.85,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10))),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Expanded(child: Text("New Complaint", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                                    ],
                                  ),
                                  const Text("Report an issue or concern to the garbage collection service.", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                                  const SizedBox(height: 16),
                                  const Divider(height: 1),
                                ],
                              ),
                            ),
                            if (isModalLoading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 60),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      CircularProgressIndicator(color: AppColors.tealText),
                                      SizedBox(height: 16),
                                      Text("Preparing your complaint form...", 
                                          style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                                    ],
                                  ),
                                ),
                              )
                            else
                              Flexible(
                                child: AddComplaintModal(
                                  showHeader: false,
                                  onSuccess: () {
                                    _refreshComplaints();
                                  }
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }
                ));
          }
        } else {
          Navigator.pushNamed(context, '/file_complaint');
        }
      },
      child: Container(
        margin: isDesktop ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 20),
        padding: isDesktop ? const EdgeInsets.all(28) : const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(isDesktop ? 28 : 24),
          boxShadow: AppTheme.pulidongShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)),
                    child: Icon(icon, color: iconColor, size: 26)),
                const SizedBox(width: 20),
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: Color(0xFF1A1A1A))),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500))
                ])),
                const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFFE0E0E0), size: 16)
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleRow(String label, String value, {bool isBadge = false, bool isBold = false, IconData? icon}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 14))
        ),
        const SizedBox(width: 12),
        if (isBadge) 
          Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(20)), child: Text(value, style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w800, fontSize: 12))) 
        else if (icon != null) 
          Row(children: [Icon(icon, size: 14, color: const Color(0xFF3F51B5)), const SizedBox(width: 6), Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF3F51B5)))]) 
        else 
          Text(value, style: TextStyle(fontWeight: isBold ? FontWeight.w900 : FontWeight.w700, fontSize: 14, color: const Color(0xFF1A1A1A)))
      ]
    );
  }

  Widget _buildBottomNav() {
    final double bottomPadding = MediaQuery.of(context).padding.bottom;
    return Container(margin: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding > 0 ? bottomPadding : 12), height: 68, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(34), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 25, offset: const Offset(0, 10), spreadRadius: 2), BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -2), spreadRadius: 1)], border: Border.all(color: Colors.white, width: 1.5)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [_buildNavItem(0, Icons.home_rounded, 'Home'), _buildNavItem(1, Icons.location_on_rounded, 'Track'), _buildNavItem(2, Icons.chat_bubble_rounded, 'Report'), _buildNavItem(3, Icons.settings_suggest_rounded, 'Settings')]));
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    bool isSelected = _selectedIndex == index;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double labelFontSize = (screenWidth * 0.035).clamp(11.0, 14.0);
    final double iconSize = (screenWidth * 0.065).clamp(22.0, 26.0);
    return _HoverZoomLink(onTap: () { setState(() { _selectedIndex = index; if (index != 3) _shouldShowDataManagement = false; }); }, child: Center(child: AnimatedContainer(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut, padding: EdgeInsets.symmetric(horizontal: isSelected ? 16 : 8, vertical: 8), decoration: BoxDecoration(color: isSelected ? const Color(0xFF00796B).withOpacity(0.1) : Colors.transparent, borderRadius: BorderRadius.circular(18)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: isSelected ? const Color(0xFF00796B) : const Color(0xFF9E9E9E), size: iconSize), if (isSelected) ...[const SizedBox(width: 8), Text(label, style: TextStyle(color: const Color(0xFF00796B), fontSize: labelFontSize, fontWeight: FontWeight.w900, letterSpacing: -0.3))]] ))));
  }

  Widget _buildTransactionHistoryCard() {
    bool isDesktop = Responsive.isDesktop(context);
    return Container(
      margin: isDesktop ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: AppTheme.pulidongShadow,
      ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Complaint History", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 24),
          if (_user == null)
            const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: AppColors.tealText, strokeWidth: 3)))
          else
            FutureBuilder<Response>(
              future: _complaintsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: AppColors.tealText, strokeWidth: 3)));
                }
                if (snapshot.hasError || !snapshot.hasData || snapshot.data?.data['success'] != true) {
                  return const Text("No complaints recorded.", style: TextStyle(color: Colors.grey));
                }
                final List all = snapshot.data!.data['data'] ?? [];
                final List filtered = all
                    .where((c) =>
                        (c['user_id'] ?? c['resident_id']).toString() == _user?.userId.toString())
                    .toList();
                if (filtered.isEmpty) {
                  // Centred in the card (the card's column aligns its children to the start).
                  return SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(color: Color(0xFFF8F9FA), shape: BoxShape.circle),
                          child: const Icon(Icons.assignment_turned_in_rounded, size: 40, color: Colors.black12),
                        ),
                        const SizedBox(height: 12),
                        const Text("No complaints filed yet",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Colors.grey)),
                        const SizedBox(height: 20),
                      ],
                    ),
                  );
                }
                return Column(
                  children: filtered.take(2).map((c) {
                    return _HoverZoomCard(
                      onTap: () {
                        setState(() {
                          _targetComplaintId = c['complaint_id'].toString();
                          _selectedIndex = 2;
                          _complaintsRefreshCount++; // Force recreate to trigger auto-scroll
                        });
                      },
                      child: _buildTransactionItem(c),
                    );
                  }).toList(),
                );
              },
            ),
          const SizedBox(height: 16),
          Center(
            child: _HoverZoomLink(
              onTap: () {
                if (_user != null && _complaintsFuture != null) {
                  _showAllComplaintsModal(context);
                }
              },
              child: const Text("View All History",
                  style: TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  void _showAllComplaintsModal(BuildContext context) {
    bool isModalLoading = true;
    
    void _showModal(BuildContext context) {
      showDialog(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) {
            if (isModalLoading) {
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) setModalState(() => isModalLoading = false);
              });
            }

            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                ),
                constraints: BoxConstraints(
                  maxWidth: 600, 
                  maxHeight: isModalLoading 
                      ? 350 
                      : 650,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!Responsive.isDesktop(context))
                      Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12),
                        decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)),
                      ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                          Responsive.isDesktop(context) ? 32 : 24,
                          Responsive.isDesktop(context) ? 32 : 12,
                          Responsive.isDesktop(context) ? 32 : 24,
                          Responsive.isDesktop(context) ? 32 : 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Expanded(
                                child: Text("All Complaint Records",
                                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                              ),
                              IconButton(
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text("Click on a report to view details and status.",
                                  style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Divider(height: 1),
                          ),
                          if (isModalLoading)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.all(40),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(color: AppColors.tealText),
                                    SizedBox(height: 16),
                                    Text("Fetching your complaint records...",
                                        style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                                  ],
                                ),
                              ),
                            )
                          else
                            Flexible(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 400),
                                child: FutureBuilder<Response>(
                                  future: _complaintsFuture,
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState == ConnectionState.waiting) {
                                      return const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(40),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              CircularProgressIndicator(color: AppColors.tealText, strokeWidth: 3),
                                              SizedBox(height: 16),
                                              Text("Loading details...",
                                                  style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                                            ],
                                          )
                                        )
                                      );
                                    }
                                    final List all = snapshot.data?.data['data'] ?? [];
                                    final List filtered = all
                                        .where((c) => (c['user_id'] ?? c['resident_id']).toString() == _user?.userId.toString())
                                        .toList();

                                    if (filtered.isEmpty) {
                                      return const Center(child: Text("No records found.", style: TextStyle(color: Colors.grey)));
                                    }

                                    return Scrollbar(
                                      thumbVisibility: true,
                                      child: ListView.builder(
                                        shrinkWrap: true,
                                        padding: const EdgeInsets.only(right: 12),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          final c = filtered[index];
                                          return _HoverZoomCard(
                                            onTap: () {
                                              Navigator.pop(context);
                                              final String cid = c['complaint_id'].toString();
                                              setState(() {
                                                _selectedIndex = 2;
                                                _targetComplaintId = cid;
                                                _complaintsRefreshCount++; // Force recreate
                                              });
                                            },
                                            child: _buildTransactionItem(c),
                                          );
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    void _showBottomSheet(BuildContext context) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) {
            if (isModalLoading) {
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) setModalState(() => isModalLoading = false);
              });
            }

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                constraints: BoxConstraints(
                  maxHeight: isModalLoading 
                      ? 380 
                      : MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(top: 12),
                      decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Expanded(
                                child: Text("All Complaint Records",
                                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                              ),
                              IconButton(
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text("Click on a report to view details and status.",
                                  style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Divider(height: 1),
                          ),
                          if (isModalLoading)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.all(40),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(color: AppColors.tealText),
                                    SizedBox(height: 16),
                                    Text("Fetching your complaint records...",
                                        style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                                  ],
                                ),
                              ),
                            )
                          else
                            Flexible(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                                child: FutureBuilder<Response>(
                                  future: _complaintsFuture,
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState == ConnectionState.waiting) {
                                      return const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(40),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              CircularProgressIndicator(color: AppColors.tealText, strokeWidth: 3),
                                              SizedBox(height: 16),
                                              Text("Loading details...",
                                                  style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500)),
                                            ],
                                          )
                                        )
                                      );
                                    }
                                    final List all = snapshot.data?.data['data'] ?? [];
                                    final List filtered = all
                                        .where((c) => (c['user_id'] ?? c['resident_id']).toString() == _user?.userId.toString())
                                        .toList();

                                    if (filtered.isEmpty) {
                                      return const Center(child: Text("No records found.", style: TextStyle(color: Colors.grey)));
                                    }

                                    return ListView.builder(
                                      shrinkWrap: true,
                                      padding: const EdgeInsets.only(bottom: 20),
                                      itemCount: filtered.length,
                                      itemBuilder: (context, index) {
                                        final c = filtered[index];
                                        return _HoverZoomCard(
                                          onTap: () {
                                            Navigator.pop(context);
                                            final String cid = c['complaint_id'].toString();
                                            setState(() {
                                              _selectedIndex = 2;
                                              _targetComplaintId = cid;
                                              _complaintsRefreshCount++; // Force recreate
                                            });
                                          },
                                          child: _buildTransactionItem(c),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    if (Responsive.isDesktop(context)) {
      _showModal(context);
    } else {
      _showBottomSheet(context);
    }
  }

  Widget _buildTransactionItem(Map c) {
    bool hasResponse = c['admin_response'] != null && c['admin_response'].toString().isNotEmpty;
    Color statusColor = hasResponse ? const Color(0xFF3F51B5) : Colors.grey;
    Color statusBgColor = hasResponse ? const Color(0xFFE8EAF6) : Colors.grey.shade100;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Row(
        children: [
          Icon(Icons.description_outlined, size: 18, color: statusColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c['category'] ?? "Unknown Complaint",
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1A1A1A)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasResponse)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: statusBgColor, borderRadius: BorderRadius.circular(8)),
              child: Text("Responded", style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.w900)),
            ),
        ],
      ),
    );
  }



  /// Shared notification center: swipe to remove, Clear all, Mark all read.
  void _showNotificationsModal(BuildContext context) {
    final NotificationInbox? inbox = _inbox;
    if (inbox == null) return;
    showNotificationCenter(
      context,
      source: _database.ref('notifications').onValue.map((DatabaseEvent e) => e.snapshot.value),
      isRelevant: _isResidentRelevant,
      inbox: inbox,
      onOpen: (Map item) {
        final String type = (item['type'] ?? '').toString();
        if (ComplaintFlow.residentComplaintTypes.contains(type)) {
          // Open Complaint History on this complaint (its tab, highlighted).
          final String? cid = ComplaintFlow.notificationComplaintId(item);
          setState(() {
            _selectedIndex = 2;
            if (cid != null) {
              _targetComplaintId = cid;
              _complaintsRefreshCount++;
            }
          });
        } else if (ResidentAlertRules.truckAlertTypes.contains(type) || type == 'TRUCK_PROXIMITY') {
          setState(() {
            _selectedIndex = 1;
            _showRoutePlan = false;
          });
        }
      },
    );
  }



  Future<bool> _showConfirmDialog(
      {required String title, required String message, bool isDestructive = false}) async {
    return await showDialog(
            context: context,
            builder: (context) => Dialog(
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 16),
                        Text(message,
                            textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
                        const SizedBox(height: 32),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(context, false),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: Colors.grey.shade300),
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text("CANCEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900)),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: HoverActionButton(
                                  text: "CONFIRM",
                                  color: isDestructive ? null : const Color(0xFF00796B),
                                  isDestructive: isDestructive,
                                  onTap: () => Navigator.pop(context, true)),
                            ),
                          ],
                        ),
                      ])),
                ))) ??
        false;
  }

  Map<String, dynamic> _getNotificationStyle(String type) {
    if (type == 'TRUCK_PROXIMITY' || type == 'auto_approach' || type == 'auto_arrival') {
      return {
        'icon': Icons.local_shipping_rounded,
        'color': const Color(0xFFFF9800),
        'bgColor': const Color(0xFFFFF3E0),
      };
    } else if (type == 'COMPLAINT_RESOLVED') {
      return {
        'icon': Icons.assignment_turned_in_rounded,
        'color': const Color(0xFF3F51B5),
        'bgColor': const Color(0xFFE8EAF6),
      };
    } else if (type == ComplaintFlow.typeInProgress) {
      return {
        'icon': Icons.autorenew_rounded,
        'color': const Color(0xFF0369A1),
        'bgColor': const Color(0xFFE0F2FE),
      };
    } else if (type == 'MAINTENANCE_ALERT') {
      return {
        'icon': Icons.warning_rounded,
        'color': const Color(0xFFF44336),
        'bgColor': const Color(0xFFFFEBEE),
      };
    } else if (type == 'ISSUE_UPDATE') {
      return {
        'icon': Icons.info_rounded,
        'color': const Color(0xFF03A9F4),
        'bgColor': const Color(0xFFE1F5FE),
      };
    } else {
      return {
        'icon': Icons.notifications_rounded,
        'color': const Color(0xFF00796B),
        'bgColor': const Color(0xFFE0F2F1),
      };
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    CustomSnackBar.show(context, message: message, isError: isError);
  }

  void _showDataManagementModal() {
    if (_user == null) return;
    _showStyledBottomSheet(
      title: "Edit Account",
      description: "Update your profile details and account settings here.",
      maxHeightMultiplier: 0.9,
      children: [
        DataManagementModal(user: _user!, onSuccess: _loadUser),
      ],
    );
  }

  void _showStyledBottomSheet({required String title, required List<Widget> children, String? description, double maxHeightMultiplier = 0.6}) {
    bool isModalLoading = true;
    
    if (Responsive.isDesktop(context)) {
      showDialog(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) {
            if (isModalLoading) {
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) setModalState(() => isModalLoading = false);
              });
            }

            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                ),
                constraints: BoxConstraints(
                  maxWidth: 550, 
                  maxHeight: isModalLoading ? 300 : 600
                ),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                        ],
                      ),
                      if (description != null && description.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(description, style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                      ],
                      const Divider(height: 32),
                      if (isModalLoading)
                        const Expanded(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(40),
                              child: CircularProgressIndicator(color: AppColors.tealText),
                            ),
                          ),
                        )
                      else
                        Flexible(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: children))),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          if (isModalLoading) {
            Future.delayed(const Duration(milliseconds: 800), () {
              if (mounted) setModalState(() => isModalLoading = false);
            });
          }

          return Container(
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              constraints: BoxConstraints(
                maxHeight: isModalLoading ? 300 : MediaQuery.of(context).size.height * maxHeightMultiplier
              ),
              padding: EdgeInsets.fromLTRB(0, 12, 0, MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10))),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                      ],
                    ),
                  ),
                  if (description != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          description,
                          textAlign: TextAlign.left,
                          style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  const Divider(height: 32),
                  if (isModalLoading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(color: AppColors.tealText),
                      ),
                    )
                  else
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 40), 
                          child: Column(mainAxisSize: MainAxisSize.min, children: children)
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRefreshSpinner() {
    return AnimatedBuilder(
      animation: _refreshRotationController,
      builder: (context, child) {
        bool shouldShow = _showRefreshSpinner || _manualPullDepth > 0;
        if (!shouldShow) return const SizedBox.shrink();

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
                    BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3)),
                  ],
                ),
                child: Transform.rotate(
                  angle: (_isRefreshing && _showRefreshSpinner)
                      ? 0
                      : (_manualPullDepth / 80) * 2 * math.pi,
                  child: RotationTransition(
                    turns: _refreshRotationController,
                    child: const Icon(Icons.refresh_rounded, color: Color(0xFF00796B), size: 24),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
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
