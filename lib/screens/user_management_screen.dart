import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../api/api_service.dart';
import '../utils/app_theme.dart';
import '../utils/responsive.dart';
import '../utils/custom_notification.dart';
import '../widgets/custom_snackbar.dart';

class UserManagementScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const UserManagementScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> with TickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showHeaderShadow = true;

  List<dynamic> _users = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _showRefreshSpinner = false;
  double _manualPullDepth = 0.0;
  late AnimationController _refreshRotationController;
  String _searchQuery = "";
  String _statusFilter = "All Status";
  int _archivedSubTab = 0; // 0 for Archived Residents, 1 for Archived Drivers
  String _sortOrder = "Pending First";

  final List<String> _statusOptions = ["All Status", "Active", "Pending Approval"];

  bool _isUserPending(dynamic user) {
    final String role = (user['role'] ?? '').toString().toLowerCase().trim();
    if (role == 'resident' || role == 'admin') return false;
    final String approvalStatus = (user['approval_status'] ?? '').toString().toLowerCase().trim();
    return approvalStatus == 'pending';
  }

  bool _isUserArchived(dynamic user) {
    if (_isUserPending(user)) return false;
    final String accountStatus = (user['account_status'] ?? '').toString().toLowerCase();
    final String isArchivedStr = (user['is_archived'] ?? '0').toString();
    return accountStatus == 'archived' || isArchivedStr == '1' || isArchivedStr == 'true';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _refreshRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _scrollController.addListener(() {
      if (_scrollController.offset <= 0 && !_showHeaderShadow) {
        setState(() => _showHeaderShadow = true);
      } else if (_scrollController.offset > 0 && _showHeaderShadow) {
        setState(() => _showHeaderShadow = false);
      }
    });
    _fetchUsers();
  }

  @override
  void dispose() {
    _refreshRotationController.dispose();
    _tabController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshAllStats({bool manual = false}) async {
    if (_isRefreshing) return;
    
    if (mounted) {
      setState(() {
        _isRefreshing = true;
        _showRefreshSpinner = manual;
        _manualPullDepth = manual ? 80.0 : 0.0;
      });
    }
    _refreshRotationController.repeat();

    await Future.wait([
      _fetchUsers(silent: true),
      Future.delayed(const Duration(milliseconds: 1500)),
    ]);

    if (manual) {
      await Future.delayed(const Duration(seconds: 2));
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
      }
      _refreshRotationController.stop();
    }
  }

  Future<void> _fetchUsers({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    try {
      final response = await _apiService.getUsers();
      if (response.data['success'] == true) {
        final List residents = response.data['residents'] ?? [];
        final List others = response.data['users'] ?? [];
        
        setState(() {
          _users = [...residents, ...others];
          _isLoading = false;
        });
      } else {
        throw response.data['message'] ?? "Failed to fetch users";
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        CustomNotification.showTopNotification(context, "Error fetching users: $e", true);
      }
    }
  }

  List<dynamic> _getFilteredUsers(String role, {bool showArchived = false}) {
    final List<dynamic> filtered = _users.where((user) {
      final String userRole = user['role'].toString().toLowerCase().trim();
      final bool matchesRole = userRole == role.toLowerCase().trim();
      
      final String name = (user['name'] ?? "").toString().toLowerCase();
      final String email = (user['email'] ?? "").toString().toLowerCase();
      final String username = (user['username'] ?? "").toString().toLowerCase();
      
      final bool matchesSearch = name.contains(_searchQuery.toLowerCase()) || 
                                email.contains(_searchQuery.toLowerCase()) ||
                                username.contains(_searchQuery.toLowerCase());

      final bool isArchived = _isUserArchived(user);
      final bool isPending = _isUserPending(user);

      if (showArchived) {
        if (!isArchived) return false;
      } else {
        if (isArchived) return false;
      }

      bool matchesStatus = true;
      if (!showArchived) {
        if (_statusFilter == "Pending Approval") {
          matchesStatus = isPending;
        } else if (_statusFilter == "Active") {
          matchesStatus = !isPending;
        }
      }
                                
      return matchesRole && matchesSearch && matchesStatus;
    }).toList();

    // Sort: Pending users first when not in archived view
    filtered.sort((a, b) {
      if (_sortOrder == "Pending First" && !showArchived) {
        final bool aPending = _isUserPending(a);
        final bool bPending = _isUserPending(b);
        if (aPending && !bPending) return -1;
        if (!aPending && bPending) return 1;
      }
      return 0;
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobile = constraints.maxWidth < 900;
        return Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          body: SafeArea(
            child: Stack(
              children: [
                Listener(
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
                  child: Column(
                    children: [
                      _buildHeader(isMobile),
                      const SizedBox(height: 16),
                      _buildTabBar(),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _isLoading
                            ? const Center(child: CircularProgressIndicator(color: Color(0xFF00897B)))
                            : TabBarView(
                                controller: _tabController,
                                children: [
                                  _buildUserList('resident', showArchived: false),
                                  _buildUserList('driver', showArchived: false),
                                  _buildUserList('admin', showArchived: false),
                                  _buildArchivedTab(),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                AnimatedBuilder(
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
                ),
              ],
            ),
          ),
        );
      }
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

  Widget _buildHeader(bool isMobile) {
    final double screenWidth = MediaQuery.of(context).size.width;
    if (!isMobile) {
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
              child: const Icon(Icons.people_outline_rounded, color: Color(0xFF00796B), size: 28),
            ),
            const SizedBox(width: 20),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("User Management",
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A1A),
                        letterSpacing: -0.5)),
                Text("Monitor and manage system access for all roles",
                    style: TextStyle(
                        color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
            const Spacer(),
          ],
        ),
      );
    }

    final double titleFontSize = (screenWidth * 0.055).clamp(18.0, 22.0);
    final double subtitleFontSize = (screenWidth * 0.03).clamp(10.0, 12.0);
    final double iconContainerSize = (screenWidth * 0.12).clamp(40.0, 48.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
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
      child: Row(
        children: [
          _buildCircularBackButton(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("User Management", style: TextStyle(fontSize: titleFontSize, fontWeight: FontWeight.w900, color: const Color(0xFF1A1A1A), letterSpacing: -0.5)),
                Text("Manage system access", style: TextStyle(fontSize: subtitleFontSize, color: const Color(0xFF757575), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Container(
            width: iconContainerSize,
            height: iconContainerSize,
            decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.people_outline_rounded, color: Color(0xFF00796B), size: 24),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final bool isDesktop = Responsive.isDesktop(context);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, 0, 24, isDesktop ? 16 : 8),
      color: Colors.transparent,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 1000),
          padding: isDesktop ? const EdgeInsets.all(16) : EdgeInsets.zero,
          decoration: isDesktop ? BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppTheme.balancedPulidongShadow,
            border: Border.all(color: Colors.grey.shade50),
          ) : null,
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F8FA),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300, width: 1.5),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() => _searchQuery = value),
                    cursorColor: Colors.black54,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: "Search name, email, or username...",
                      hintStyle: TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
                      prefixIcon: Icon(Icons.search_rounded, color: Color(0xFF00897B), size: 22),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildFilterChip(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip() {
    return PopupMenuButton<String>(
      onSelected: (val) {
        setState(() => _statusFilter = val);
      },
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
      color: Colors.white,
      tooltip: "Filter by Status",
      itemBuilder: (context) => _statusOptions.map((opt) {
        bool isSelected = opt == _statusFilter;
        return PopupMenuItem<String>(
          value: opt,
          child: Row(
            children: [
              Icon(
                isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 18,
                color: isSelected ? const Color(0xFF00897B) : Colors.grey.shade400,
              ),
              const SizedBox(width: 12),
              Text(
                opt,
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tune_rounded, size: 18, color: Color(0xFF00897B)),
            const SizedBox(width: 8),
            Text(
              _statusFilter == "All Status" ? "Status" : _statusFilter,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down_rounded, size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      color: Colors.transparent,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          height: 50,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F4F8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade100, width: 1),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00897B).withOpacity(0.15),
                blurRadius: 15,
                offset: const Offset(0, 6),
              )
            ],
          ),
          child: TabBar(
            controller: _tabController,
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.grey.shade600,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFF00897B),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00897B).withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            dividerColor: Colors.transparent,
            labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            tabs: const [
              Tab(text: "RESIDENTS"),
              Tab(text: "DRIVERS"),
              Tab(text: "ADMINS"),
              Tab(text: "ARCHIVED"),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArchivedTab() {
    final String role = _archivedSubTab == 0 ? 'resident' : 'driver';

    return Column(
      children: [
        _buildSearchBar(),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildSubTabChip("Archived Residents", 0),
              const SizedBox(width: 12),
              _buildSubTabChip("Archived Drivers", 1),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _buildUserList(role, showArchived: true),
        ),
      ],
    );
  }

  Widget _buildSubTabChip(String label, int index) {
    bool isSelected = _archivedSubTab == index;
    return InkWell(
      onTap: () {
        setState(() {
          _archivedSubTab = index;
        });
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00897B) : const Color(0xFFE0F2F1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFF00796B),
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildUserList(String role, {bool showArchived = false}) {
    final filteredUsers = _getFilteredUsers(role, showArchived: showArchived);

    return Column(
      children: [
        if (!showArchived) _buildSearchBar(),
        const SizedBox(height: 4),
        Expanded(
          child: AnimatedBuilder(
            animation: _scrollController,
            builder: (context, child) {
              final double offset = _scrollController.hasClients ? _scrollController.offset : 0;
              return Transform.translate(
                offset: Offset(0, offset < 0 ? offset : 0),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
                  child: filteredUsers.isEmpty
                      ? _buildEmptyState()
                      : LayoutBuilder(
                          builder: (context, boxConstraints) {
                            final bool isWeb = boxConstraints.maxWidth > 900;
                            return GridView.builder(
                              controller: _scrollController,
                              physics: (_manualPullDepth > 0 || _isRefreshing) 
                                  ? const NeverScrollableScrollPhysics() 
                                  : const ClampingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(24, 12, 24, 100),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: isWeb ? 2 : 1,
                                crossAxisSpacing: 24,
                                mainAxisSpacing: 20,
                                mainAxisExtent: isWeb ? (showArchived ? 190 : 210) : (showArchived ? 165 : 180),
                              ),
                              itemCount: filteredUsers.length,
                              itemBuilder: (context, index) {
                                final user = filteredUsers[index];
                                final String displayRole = user['role'].toString().toUpperCase();
                                final String approvalStatus = (user['approval_status'] ?? '').toString().toLowerCase().trim();
                                final bool isArchived = _isUserArchived(user);
                                final bool isPending = _isUserPending(user);

                                return Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: AppTheme.balancedPulidongShadow,
                                    border: isPending
                                        ? Border.all(color: const Color(0xFFFFB74D), width: 2.0)
                                        : (isArchived
                                            ? Border.all(color: const Color(0xFFFFCDD2), width: 1.5)
                                            : Border.all(color: Colors.grey.shade100, width: 1.5)),
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    borderRadius: BorderRadius.circular(24),
                                    child: InkWell(
                                      onTap: () => _showUserDetails(user),
                                      borderRadius: BorderRadius.circular(24),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Row(
                                              children: [
                                                // Two-digit number badge (01, 02, 03...)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                                  decoration: BoxDecoration(
                                                    color: isArchived ? const Color(0xFFFFEBEE) : const Color(0xFFE0F2F1),
                                                    borderRadius: BorderRadius.circular(10),
                                                  ),
                                                  child: Text(
                                                    (index + 1).toString().padLeft(2, '0'),
                                                    style: TextStyle(
                                                      color: isArchived ? const Color(0xFFC62828) : const Color(0xFF00796B),
                                                      fontWeight: FontWeight.w900,
                                                      fontSize: 13,
                                                      letterSpacing: -0.2,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Container(
                                                  width: 50,
                                                  height: 50,
                                                  decoration: BoxDecoration(
                                                    color: _getRoleBgColor(displayRole),
                                                    borderRadius: BorderRadius.circular(16),
                                                  ),
                                                  child: Icon(
                                                    Icons.person_rounded,
                                                    color: _getRoleColor(displayRole),
                                                    size: 26,
                                                  ),
                                                ),
                                                const SizedBox(width: 14),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      Row(
                                                        children: [
                                                          Expanded(
                                                            child: Text(
                                                              user['name'] ?? "No Name",
                                                              style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), fontSize: 16, letterSpacing: -0.3),
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ),
                                                          if (isArchived)
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                              decoration: BoxDecoration(
                                                                color: const Color(0xFFFFEBEE),
                                                                borderRadius: BorderRadius.circular(6),
                                                              ),
                                                              child: const Text(
                                                                "ARCHIVED",
                                                                style: TextStyle(color: Color(0xFFC62828), fontSize: 9, fontWeight: FontWeight.w900),
                                                              ),
                                                            )
                                                          else if (isPending)
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                              decoration: BoxDecoration(
                                                                color: const Color(0xFFFFF3E0),
                                                                borderRadius: BorderRadius.circular(6),
                                                                border: Border.all(color: const Color(0xFFFFB74D)),
                                                              ),
                                                              child: const Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  Icon(Icons.hourglass_top_rounded, size: 10, color: Color(0xFFE65100)),
                                                                  SizedBox(width: 3),
                                                                  Text(
                                                                    "PENDING APPROVAL",
                                                                    style: TextStyle(color: Color(0xFFE65100), fontSize: 8, fontWeight: FontWeight.w900),
                                                                  ),
                                                                ],
                                                              ),
                                                            )
                                                          else if (approvalStatus == 'approved')
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                              decoration: BoxDecoration(
                                                                color: const Color(0xFFE8F5E9),
                                                                borderRadius: BorderRadius.circular(6),
                                                              ),
                                                              child: const Text(
                                                                "APPROVED",
                                                                style: TextStyle(color: Color(0xFF2E7D32), fontSize: 8, fontWeight: FontWeight.w900),
                                                              ),
                                                            )
                                                          else
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                              decoration: BoxDecoration(
                                                                color: const Color(0xFFECEFF1),
                                                                borderRadius: BorderRadius.circular(6),
                                                              ),
                                                              child: const Text(
                                                                "Status not set",
                                                                style: TextStyle(color: Color(0xFF546E7A), fontSize: 8, fontWeight: FontWeight.w700),
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        user['email'] ?? 'No Email',
                                                        style: const TextStyle(fontSize: 12, color: Color(0xFF757575), fontWeight: FontWeight.w500),
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                      const SizedBox(height: 6),
                                                      UnconstrainedBox(
                                                        alignment: Alignment.centerLeft,
                                                        child: Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFFF1F4F8),
                                                            borderRadius: BorderRadius.circular(6),
                                                          ),
                                                          child: Text(
                                                            "@${user['username'] ?? ''}",
                                                            style: const TextStyle(fontSize: 11, color: Color(0xFF455A64), fontWeight: FontWeight.w800),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (isPending) ...[
                                              const SizedBox(height: 10),
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.end,
                                                children: [
                                                  OutlinedButton.icon(
                                                    onPressed: () => _showRejectConfirmation(user['user_id'], user['role'], user['name']),
                                                    style: OutlinedButton.styleFrom(
                                                      foregroundColor: const Color(0xFFD32F2F),
                                                      side: const BorderSide(color: Color(0xFFFFCDD2)),
                                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                      minimumSize: const Size(0, 32),
                                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                                    ),
                                                    icon: const Icon(Icons.close_rounded, size: 14),
                                                    label: const Text("Reject", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  ElevatedButton.icon(
                                                    onPressed: () => _showApproveConfirmation(user['user_id'], user['role'], user['name']),
                                                    style: ElevatedButton.styleFrom(
                                                      backgroundColor: const Color(0xFF00897B),
                                                      foregroundColor: Colors.white,
                                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                                      minimumSize: const Size(0, 32),
                                                      elevation: 0,
                                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                                    ),
                                                    icon: const Icon(Icons.check_circle_rounded, size: 14),
                                                    label: Text(
                                                      displayRole == 'DRIVER' ? "Approve Driver" : "Approve User",
                                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ] else if (isArchived) ...[
                                              const SizedBox(height: 10),
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.end,
                                                children: [
                                                  ElevatedButton.icon(
                                                    onPressed: () => _showRestoreConfirmation(user['user_id'], user['role'], user['name']),
                                                    style: ElevatedButton.styleFrom(
                                                      backgroundColor: const Color(0xFF00897B),
                                                      foregroundColor: Colors.white,
                                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                                      minimumSize: const Size(0, 32),
                                                      elevation: 0,
                                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                                    ),
                                                    icon: const Icon(Icons.unarchive_rounded, size: 14),
                                                    label: const Text("Restore Account", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          }
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_off_rounded, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isEmpty ? "No users in this category" : "No users found for '$_searchQuery'",
            style: const TextStyle(color: Color(0xFF757575), fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Color _getRoleColor(String role) {
    switch (role) {
      case 'ADMIN': return const Color(0xFFFF1744);
      case 'DRIVER': return const Color(0xFF2E7D32);
      default: return const Color(0xFF1976D2);
    }
  }

  Color _getRoleBgColor(String role) {
    switch (role) {
      case 'ADMIN': return const Color(0xFFFFF0F2);
      case 'DRIVER': return const Color(0xFFE8F5E9);
      default: return const Color(0xFFE3F2FD);
    }
  }

  void _showUserDetails(dynamic user) {
    final String role = user['role'].toString().toUpperCase();
    final bool isArchived = _isUserArchived(user);
    final bool isPending = _isUserPending(user);
    final bool isMobile = MediaQuery.of(context).size.width < 900;
    bool isModalLoading = true;

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

          Widget contentBody(ScrollController scrollController) => Container(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: isMobile 
                  ? const BorderRadius.vertical(top: Radius.circular(32)) 
                  : BorderRadius.circular(32),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isMobile) Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 24), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("User Profile", 
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                        SizedBox(height: 4),
                        Text("Review account information and access levels.", 
                          style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
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
                const Divider(height: 40),
                Flexible(
                  child: ListView(
                    controller: scrollController,
                    shrinkWrap: true,
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: [
                      if (isModalLoading)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 60),
                            child: Column(
                              children: [
                                const CircularProgressIndicator(color: Color(0xFF00897B), strokeWidth: 3),
                                const SizedBox(height: 16),
                                Text("Loading secure profile data...", style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w600, fontSize: 13)),
                              ],
                            ),
                          ),
                        )
                      else ...[
                        Row(
                          children: [
                            Container(
                              width: 72, height: 72,
                              decoration: BoxDecoration(
                                color: _getRoleBgColor(role),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Icon(Icons.person_rounded, color: _getRoleColor(role), size: 36),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(user['name'] ?? "User Details", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: -0.5)),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _getRoleBgColor(role),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      role,
                                      style: TextStyle(color: _getRoleColor(role), fontWeight: FontWeight.w900, fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        // Basic Information
                        const Text("BASIC INFORMATION", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
                        const SizedBox(height: 16),
                        _buildDetailItem(Icons.alternate_email_rounded, "Username", user['username'] ?? "N/A"),
                        _buildDetailItem(Icons.email_outlined, "Email Address", user['email'] ?? "N/A"),
                        _buildDetailItem(Icons.phone_android_rounded, "Phone Number", user['phone'] ?? "N/A"),
                        
                        const SizedBox(height: 24),
                        
                        // Role Specific Information
                        if (role == 'RESIDENT') ...[
                          const Text("RESIDENT DETAILS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
                          const SizedBox(height: 16),
                          _buildDetailItem(Icons.location_on_outlined, "Purok", user['purok'] ?? "N/A"),
                          _buildDetailItem(Icons.home_outlined, "Complete Address", user['complete_address'] ?? "N/A"),
                          const SizedBox(height: 8),
                        ] else if (role == 'DRIVER') ...[
                          const Text("DRIVER DETAILS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
                          const SizedBox(height: 16),
                          _buildDetailItem(Icons.badge_outlined, "License Number", user['license_number'] ?? "N/A"),
                          _buildDetailItem(Icons.local_shipping_outlined, "Preferred Truck", user['preferred_truck'] ?? "N/A"),
                          const SizedBox(height: 8),
                        ],
                        
                        const Text("ACCOUNT STATUS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
                        const SizedBox(height: 16),
                        _buildDetailItem(Icons.calendar_today_rounded, "Member Since", (user['created_at'] ?? "N/A").toString().split(' ')[0]),
                        _buildDetailItem(
                          Icons.verified_user_outlined,
                          "Approval Status",
                          isArchived
                              ? "Archived"
                              : (isPending
                                  ? "Pending Approval"
                                  : ((user['approval_status'] ?? '').toString().toLowerCase().trim() == 'approved' ? "Approved & Active" : "Status not set")),
                        ),
                        
                        if (isPending) ...[
                          const SizedBox(height: 32),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () => _showRejectConfirmation(user['user_id'], user['role'], user['name']),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFFEBEE),
                                    foregroundColor: const Color(0xFFD32F2F),
                                    minimumSize: const Size(0, 60),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    elevation: 0,
                                  ),
                                  child: const Text("REJECT", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: ElevatedButton(
                                  onPressed: () => _showApproveConfirmation(user['user_id'], user['role'], user['name']),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00897B),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(0, 60),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    elevation: 0,
                                  ),
                                  child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text("APPROVE USER", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ] else if (isArchived) ...[
                          const SizedBox(height: 32),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => _showRestoreConfirmation(user['user_id'], user['role'], user['name']),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00897B),
                                foregroundColor: Colors.white,
                                minimumSize: const Size(0, 60),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                elevation: 0,
                              ),
                              child: const Text("RESTORE ACCOUNT", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                            ),
                          ),
                        ] else if (role != 'ADMIN') ...[
                          const SizedBox(height: 32),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => _showArchiveConfirmation(user['user_id'], user['role'], user['name']),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFFECEC),
                                foregroundColor: const Color(0xFFC62828),
                                minimumSize: const Size(0, 60),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                elevation: 0,
                              ),
                              child: const Text("ARCHIVE ACCOUNT", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            ),
          );

          if (isMobile) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top - 20,
              ),
              child: Container(
                padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                child: contentBody(ScrollController()),
              ),
            );
          } else {
            return Center(
              child: Dialog(
                backgroundColor: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600, maxHeight: 750),
                  child: contentBody(ScrollController()),
                ),
              ),
            );
          }
        },
      ),
    );
  }

  Future<void> _approveUser(dynamic id, dynamic role) async {
    try {
      final response = await _apiService.approveUser(int.parse(id.toString()), role.toString());
      if (response.data['success'] == true) {
        if (mounted) {
          CustomNotification.showTopNotification(context, "Account approved successfully!", false);
          _fetchUsers(); // Refresh list
        }
      } else {
        throw response.data['message'] ?? "Failed to approve user";
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Error: $e", true);
      }
    }
  }

  void _showApproveConfirmation(dynamic id, dynamic role, String? name) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Approve User?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                Text(
                  "Are you sure you want to approve the registration for ${name ?? 'this user'}? This will grant them access to the system.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14, height: 1.5, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.grey.shade300, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text("CANCEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _approveUser(id, role);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00897B),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 56),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text("CONFIRM APPROVAL", style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showRejectConfirmation(dynamic id, dynamic role, String? name) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Reject Registration?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                Text(
                  "Are you sure you want to reject and delete the registration for ${name ?? 'this user'}? This action cannot be undone.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14, height: 1.5, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.grey.shade300, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text("CANCEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _rejectUser(id, role);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 56),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text("REJECT & DELETE", style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rejectUser(dynamic id, dynamic role) async {
    try {
      final response = await _apiService.rejectUser(int.parse(id.toString()), role.toString());
      if (response.data['success'] == true) {
        if (mounted) {
          CustomNotification.showTopNotification(context, "Registration rejected and deleted.", false);
          _fetchUsers(); // Refresh list
        }
      } else {
        throw response.data['message'] ?? "Failed to reject user";
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Error: $e", true);
      }
    }
  }

  void _showArchiveConfirmation(dynamic id, dynamic role, String? name) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Archive Account?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                Text(
                  "Are you sure you want to archive ${name ?? 'this user'}? The account will be moved to the Archived tab.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14, height: 1.5, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.grey.shade300, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text("CANCEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _archiveUser(id, role, true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 56),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text("CONFIRM ARCHIVE", style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showRestoreConfirmation(dynamic id, dynamic role, String? name) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Restore Account?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                Text(
                  "Are you sure you want to restore ${name ?? 'this user'}? The account will be moved back to the active list.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14, height: 1.5, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.grey.shade300, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text("CANCEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _archiveUser(id, role, false);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00897B),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 56),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text("CONFIRM RESTORE", style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _archiveUser(dynamic id, dynamic role, bool archive) async {
    try {
      final response = await _apiService.archiveUser(int.parse(id.toString()), role.toString(), archive);
      if (response.data['success'] == true) {
        final String uidStr = id.toString();

        // Synchronize with Firebase Realtime Database
        if (archive) {
          await FirebaseDatabase.instance.ref('users/$uidStr').update({
            'is_archived': 1,
            'account_status': 'archived',
            'isOnline': false,
            'status': 'OFFLINE',
          });

          // Also mark any location node registered to this driver as OFFLINE & archived
          final locsSnap = await FirebaseDatabase.instance.ref('truck_locations').get();
          if (locsSnap.exists && locsSnap.value is Map) {
            final Map locs = locsSnap.value as Map;
            locs.forEach((tKey, tVal) {
              if (tVal is Map) {
                final String dId = (tVal['driver_id'] ?? tVal['driverId'] ?? '').toString();
                if (dId == uidStr) {
                  FirebaseDatabase.instance.ref('truck_locations/$tKey').update({
                    'is_archived': 1,
                    'isOnline': false,
                    'status': 'OFFLINE',
                    'latitude': 0.0,
                    'longitude': 0.0,
                  });
                }
              }
            });
          }
        } else {
          await FirebaseDatabase.instance.ref('users/$uidStr').update({
            'is_archived': 0,
            'account_status': 'active',
          });
        }

        if (mounted) {
          final String msg = archive ? "Account archived successfully!" : "Account restored successfully!";
          CustomNotification.showTopNotification(context, msg, false);
          _fetchUsers(); // Refresh list
        }
      } else {
        throw response.data['message'] ?? "Failed to update account archive status";
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Error: $e", true);
      }
    }
  }

  Widget _buildDetailItem(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF00897B), size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF9E9E9E))),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
